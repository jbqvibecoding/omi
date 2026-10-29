import AppKit
import Foundation

/// One slide the user had up during a session, and what was said while it was.
struct SlideRecord: Identifiable {
    let id = UUID()
    let at: Date
    let appName: String
    let windowTitle: String?
    /// Perceptual hash of the frame this slide was recognized from.
    let hash: UInt64
    /// What the model saw on the slide. Empty while the caption is still in flight.
    var caption: String
    /// The transcript spoken while the *previous* slide was up, attached to the boundary
    /// that ended it.
    var spokenText: String
}

/// A deck timeline for a recorded session: which slide was up, when, and what was said
/// over it.
///
/// The structure of a presentation is not time, it is pages. A transcript alone cannot
/// tell you that the pricing objection landed on the slide *before* the pricing slide, and
/// a screen history alone cannot tell you what was said while a page was up. Binding the
/// two is the whole feature.
///
/// Built entirely on frames Rewind has already captured. Rewind runs a capture loop at a
/// 3-second default interval and stores every frame, so a second capture loop would be
/// pure duplicated battery for a stream that already exists — this only reads it, finds
/// the page boundaries in it, and captions those.
///
/// No images are stored. A slide is a hash, a caption and a slice of transcript; the
/// frames themselves stay Rewind's problem and age out under Rewind's retention.
@MainActor
final class SlideTimeline: ObservableObject {
    static let shared = SlideTimeline()

    /// Hamming distance, out of 64, above which two frames are different pages. Measured
    /// against what the two regimes actually look like: cursor movement and antialiasing
    /// move a handful of bits, a page turn moves tens of them.
    static let changeThreshold = 12
    /// Consecutive differing frames before a change is believed. One is a flash — a
    /// notification banner, a video frame, a window dragged across the deck.
    static let requiredStableFrames = 2

    /// How often Rewind's new frames are drained. Deliberately slower than Rewind's own
    /// 3s capture: this is a reader, and a page that turned 5 seconds ago is still the
    /// page that is up.
    private let pollInterval: TimeInterval = 6
    /// Frames pulled per poll. Two polls' worth of headroom so a stall catches up.
    private let framesPerPoll = 20
    private let maxSlides = 50
    /// Transcript attached to a boundary. Enough for a few minutes of talking over one
    /// page, bounded so a slide nobody advanced doesn't carry the whole meeting.
    private let maxSpokenCharacters = 1500

    @Published private(set) var slides: [SlideRecord] = []
    @Published private(set) var isRunning = false

    private var loop: Task<Void, Never>?
    private var geminiClient: GeminiClient?

    // Debounce state. `anchor` is the page believed to be up; `candidate` is a frame that
    // differed from it and is waiting for a second frame to agree.
    private var anchorHash: UInt64?
    private var candidateHash: UInt64?
    private var stableCount = 0
    /// Timestamp of the last confirmed boundary, kept for display.
    private var currentSlideStartedAt: Date?
    private var lastSeenFrameAt: Date?
    /// How many transcript segments existed at the last boundary.
    ///
    /// Sliced by index rather than by time on purpose: `SpeakerSegment.start` is an offset
    /// into the session, not a wall-clock date, and the two clocks are not the same one —
    /// aligning them would mean trusting that the session began exactly when this did.
    /// What was said since the last page turn is simply what was appended since then.
    private var segmentCountAtBoundary = 0

    private init() {}

    // MARK: - Lifecycle

    /// Called when a recording session starts.
    func start() {
        guard CopilotSettings.shared.slideTimelineEnabled else { return }
        guard AssistantSettings.shared.screenAnalysisEnabled else {
            log("SlideTimeline: screen capture is off, nothing to read")
            return
        }
        guard loop == nil else { return }
        reset()
        isRunning = true
        currentSlideStartedAt = Date()
        lastSeenFrameAt = Date()
        log("SlideTimeline: started")
        let interval = UInt64(pollInterval * 1_000_000_000)
        loop = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await SlideTimeline.shared.drain()
            }
        }
    }

    /// Called when the session ends. Slides stay readable until the summary has taken
    /// them; `reset()` is what actually drops them.
    func stop() {
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        isRunning = false
        log("SlideTimeline: stopped with \(slides.count) slides")
    }

    func reset() {
        slides.removeAll()
        anchorHash = nil
        candidateHash = nil
        stableCount = 0
        currentSlideStartedAt = nil
        lastSeenFrameAt = nil
        segmentCountAtBoundary = LiveTranscriptMonitor.shared.segments.count
    }

    // MARK: - Reading Rewind's frames

    private func drain() async {
        guard CopilotSettings.shared.slideTimelineEnabled else {
            stop()
            return
        }
        let since = lastSeenFrameAt ?? Date().addingTimeInterval(-pollInterval * 2)
        let now = Date()
        let frames: [Screenshot]
        do {
            frames = try await RewindDatabase.shared.getScreenshots(
                from: since, to: now, limit: framesPerPoll)
        } catch {
            // Rewind being busy or mid-rotation is not an error worth reporting; the next
            // poll picks up the same window.
            return
        }
        guard !frames.isEmpty else { return }
        lastSeenFrameAt = frames.map(\.timestamp).max() ?? now

        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            // The same exclusion list that governs screen recording. An app the user told
            // omi not to record is not a deck to caption.
            guard !RewindSettings.shared.isAppExcluded(frame.appName) else { continue }
            await consider(frame)
        }
    }

    private func consider(_ frame: Screenshot) async {
        guard let image = try? await RewindStorage.shared.loadScreenshotImage(for: frame),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let hash = PerceptualChangeDetector.dHash(cgImage)
        guard hash != 0 else { return }
        guard confirmBoundary(hash) else { return }

        let boundaryAt = frame.timestamp
        let spoken = spokenSinceLastBoundary()
        currentSlideStartedAt = boundaryAt

        let record = SlideRecord(
            at: boundaryAt, appName: frame.appName, windowTitle: frame.windowTitle,
            hash: hash, caption: "", spokenText: spoken)
        slides.append(record)
        if slides.count > maxSlides { slides.removeFirst(slides.count - maxSlides) }

        // Caption out of band: a slow model call must not stall the next frame.
        let index = slides.count - 1
        Task { @MainActor in
            guard let caption = await self.caption(frame: frame, spoken: spoken) else { return }
            guard index < self.slides.count, self.slides[index].id == record.id else { return }
            self.slides[index].caption = caption
        }
    }

    /// The debounce. Returns true when `hash` confirms a new page.
    private func confirmBoundary(_ hash: UInt64) -> Bool {
        guard let anchor = anchorHash else {
            anchorHash = hash
            return true  // the first frame of a session is slide one
        }
        if PerceptualChangeDetector.hammingDistance(anchor, hash) <= Self.changeThreshold {
            // Still (or back) on the page we believe is up: whatever we were counting was
            // a blip, not a turn.
            candidateHash = nil
            stableCount = 0
            return false
        }
        if let candidate = candidateHash,
            PerceptualChangeDetector.hammingDistance(candidate, hash) <= Self.changeThreshold
        {
            stableCount += 1
        } else {
            candidateHash = hash
            stableCount = 1
        }
        guard stableCount >= Self.requiredStableFrames else { return false }
        anchorHash = hash
        candidateHash = nil
        stableCount = 0
        return true
    }

    /// What was said since the previous page turn, and advance the marker.
    private func spokenSinceLastBoundary() -> String {
        let segments = LiveTranscriptMonitor.shared.segments
        defer { segmentCountAtBoundary = segments.count }
        // The backend can re-emit a corrected list, so the array is not strictly
        // append-only; clamping means a shrink costs one slide's context, not a crash.
        let start = min(segmentCountAtBoundary, segments.count)
        guard start < segments.count else { return "" }
        let lines = segments[start...]
            .map {
                ($0.isUser ? "You: " : "Them: ")
                    + $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { $0.count > 5 }
        guard !lines.isEmpty else { return "" }
        return String(lines.joined(separator: "\n").suffix(maxSpokenCharacters))
    }

    // MARK: - Captioning

    private static let captionSystemPrompt = """
        You are captioning one slide from a presentation the user is in. Write the title on \
        the first line, then at most four short bullets: the claims it makes, the numbers or \
        chart it shows, and any visible slide number. Plain text, no preamble, no markdown \
        fences. If the screenshot is not a slide — an IDE, a browser, a spreadsheet — say \
        what is on screen in one line instead of inventing a deck.
        """

    /// The image-capable request needs structured output, so the caption comes back as a
    /// single field rather than as prose.
    private static let captionSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "caption": .init(
                type: "string", enum: nil,
                description: "Title line, then at most four short bullets describing the slide"),
        ],
        required: ["caption"]
    )

    private struct CaptionResult: Decodable {
        let caption: String
    }

    private func caption(frame: Screenshot, spoken: String) async -> String? {
        guard let data = try? await RewindStorage.shared.loadScreenshotData(for: frame) else {
            return nil
        }
        guard let imageData = GeminiImageCompression.compress(data, preset: .background) else {
            return nil
        }
        var prompt = "Caption the slide in this screenshot."
        if !spoken.isEmpty {
            prompt += """


                What was being said while the previous slide was up — context only, the \
                caption describes the image:
                \(spoken)
                """
        }
        do {
            let client = try cachedClient()
            let text = try await client.sendRequest(
                prompt: prompt, imageData: imageData,
                systemPrompt: Self.captionSystemPrompt,
                responseSchema: Self.captionSchema, thinkingBudget: 0)
            let result = try JSONDecoder().decode(CaptionResult.self, from: Data(text.utf8))
            let trimmed = result.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            log("SlideTimeline: caption failed — \(error.localizedDescription)")
            return nil
        }
    }

    private func cachedClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(
            model: ModelQoS.Gemini.utility, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }

    // MARK: - Consumption

    /// The timeline as a prompt block, oldest first. Empty when nothing was captioned.
    func promptBlock(maxChars: Int = 2000) -> String {
        let captioned = slides.filter { !$0.caption.isEmpty }
        guard !captioned.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var blocks: [String] = []
        var used = 0
        for (offset, slide) in captioned.enumerated().reversed() {
            var block = "Slide \(offset + 1) (\(formatter.string(from: slide.at)))\n\(slide.caption)"
            if !slide.spokenText.isEmpty {
                block += "\nSaid while the previous slide was up:\n\(slide.spokenText)"
            }
            guard used + block.count <= maxChars else { break }
            used += block.count + 2
            blocks.append(block)
        }
        return blocks.reversed().joined(separator: "\n\n")
    }

    /// Markdown for the session export, or nil when there is no deck to report.
    func markdownSection() -> String? {
        let captioned = slides.filter { !$0.caption.isEmpty }
        guard captioned.count >= 2 else { return nil }  // one "slide" is just a screen
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var out = "## Deck walkthrough\n"
        for (offset, slide) in captioned.enumerated() {
            out += "\n### \(offset + 1). \(formatter.string(from: slide.at))\n\n\(slide.caption)\n"
        }
        return out
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        [
            "enabled": CopilotSettings.shared.slideTimelineEnabled ? "true" : "false",
            "running": isRunning ? "true" : "false",
            "screen_capture_on": AssistantSettings.shared.screenAnalysisEnabled ? "true" : "false",
            "slides": String(slides.count),
            "captioned": String(slides.filter { !$0.caption.isEmpty }.count),
            "latest": slides.last?.caption.split(separator: "\n").first.map(String.init) ?? "-",
        ]
    }
}
