import SwiftUI

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — NotesContentView, TopicView,
// TimeLink, FishboneView, TermChips, Tag and FramedList in Sources/LiveSubs/NotesViews.swift.
// See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: omi's dark palette and fonts, with neutral white for what is live instead of
// Cicada's orange; every conclusion, to-do, point and branch shows the words it came from, and
// its time jumps the live transcript to that line (by segment id, not by time); English labels
// to match the rest of the app; a recording-page panel with a Minutes / Notes switch, status
// line and the "minute this session" button an in-person meeting needs.

// MARK: - Jumping to the transcript

/// A request from the minutes to scroll the live transcript to a line.
@MainActor
final class TranscriptJumpCenter: ObservableObject {
    static let shared = TranscriptJumpCenter()

    struct Request: Equatable {
        let lineId: String
        /// Seconds into the session, for when the exact line has left the in-memory transcript.
        let t: Double
        let nonce: Int
    }

    @Published private(set) var request: Request?
    private var nonce = 0

    private init() {}

    func jump(lineId: String, t: Double) {
        nonce += 1
        request = Request(lineId: lineId, t: t, nonce: nonce)
    }
}

// MARK: - Recording page side panel

/// The right side of the recording page: the meeting minutes, or the running notes.
struct RecordingSidePanel: View {
    enum Tab: String, CaseIterable {
        case minutes, notes
        var title: String { self == .minutes ? "Minutes" : "Notes" }
    }

    @AppStorage("recordingSidePanelTab") private var tab: Tab = .minutes

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { option in
                    Button {
                        tab = option
                    } label: {
                        Text(option.title)
                            .scaledFont(size: 12, weight: tab == option ? .semibold : .regular)
                            .foregroundColor(tab == option ? OmiColors.textPrimary : OmiColors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(tab == option ? OmiColors.backgroundQuaternary : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(OmiColors.backgroundSecondary)

            Divider().background(OmiColors.border)

            switch tab {
            case .minutes: MeetingMinutesPanel()
            case .notes: LiveNotesView()
            }
        }
        .background(OmiColors.backgroundSecondary)
    }
}

// MARK: - Minutes panel

/// Live meeting minutes: summary, topics with fishbone diagrams, conclusions and to-dos that
/// each show the words they came from. Updated every 45 seconds while a meeting is going on;
/// rewritten once from the whole transcript when it ends.
struct MeetingMinutesPanel: View {
    @ObservedObject private var engine = MeetingMinutesEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            if engine.minutes.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        MinutesContentView(
                            minutes: engine.minutes,
                            fresh: engine.fresh,
                            live: engine.isLive,
                            updating: engine.state == .updating,
                            summaryJustChanged: engine.summaryChangedAt.map { Date().timeIntervalSince($0) < 60 } ?? false,
                            coveredUntil: engine.coveredUntil)
                            .padding(14)
                    }
                    .onChange(of: engine.minutes.topics.last?.id) { _, id in
                        // Keep the topic being discussed in view as the meeting moves on.
                        guard engine.isLive, let id else { return }
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(MinutesContentView.topicAnchor(id), anchor: .top)
                        }
                    }
                }
            }
        }
        .background(OmiColors.backgroundSecondary)
    }

    @ViewBuilder
    private var statusLine: some View {
        let text = statusText
        if !text.isEmpty {
            HStack(spacing: 6) {
                if engine.state == .updating || engine.finalizing {
                    ProgressView().controlSize(.mini)
                } else if engine.isLive && engine.trigger != nil {
                    Circle().fill(OmiColors.success).frame(width: 6, height: 6)
                }
                Text(text)
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if engine.isLive, engine.trigger != nil, engine.state != .updating {
                    Button {
                        engine.updateNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundColor(OmiColors.textTertiary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Update the minutes now")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private var statusText: String {
        if engine.finalizing { return "Writing the full minutes…" }
        if !CopilotSettings.shared.minutesEnabled { return "Minutes are off in Settings › Copilot" }
        switch engine.state {
        case .updating: return engine.minutes.isEmpty ? "Writing the first minutes…" : "Updating…"
        case .rateLimited: return "Busy — trying again in a moment"
        case .unavailable: return "Minutes need an active plan right now"
        case .failed: return "Last update didn't work — will try again"
        case .idle, .waiting, .ready: break
        }
        guard engine.isLive else { return engine.minutes.final ? "Final minutes" : "" }
        guard let trigger = engine.trigger else { return "" }
        let why: String
        switch trigger {
        case .call: why = "call"
        case .systemAudio: why = "audio playing"
        case .manual: why = "started by you"
        }
        if let until = engine.coveredUntil {
            return "Live · up to \(MinutesLogic.clock(until)) · \(why)"
        }
        return "Live · \(why)"
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .scaledFont(size: 30)
                .foregroundColor(OmiColors.textQuaternary)
            if engine.isLive && engine.trigger != nil {
                Text("The first minutes appear about half a minute after people start talking")
                    .scaledFont(size: 13)
                    .foregroundColor(OmiColors.textTertiary)
                    .multilineTextAlignment(.center)
            } else if engine.isLive && CopilotSettings.shared.minutesEnabled {
                Text("Minutes start on their own in a call, or when your Mac plays people talking — a webinar, a livestream, a video.")
                    .scaledFont(size: 13)
                    .foregroundColor(OmiColors.textTertiary)
                    .multilineTextAlignment(.center)
                Button {
                    engine.startManually()
                } label: {
                    Text("Take minutes of this conversation")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundColor(OmiColors.backgroundPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(OmiColors.textPrimary))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("Meeting minutes — a summary, topics, and conclusions and to-dos that show who said them and when.")
                    .scaledFont(size: 13)
                    .foregroundColor(OmiColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Content

struct MinutesContentView: View {
    let minutes: MeetingMinutes
    var fresh: Set<String> = []
    /// The meeting is still going: the last topic is the one being discussed.
    var live = false
    var updating = false
    var summaryJustChanged = false
    var coveredUntil: Double?

    static func topicAnchor(_ id: String) -> String { "minutes-topic-\(id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title = minutes.title, !title.isEmpty {
                Text(title)
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundColor(OmiColors.textPrimary)
                    .textSelection(.enabled)
            }
            if !minutes.summary.isEmpty { summaryCard }
            if !minutes.topics.isEmpty { topicsSection }
            if !minutes.conclusions.isEmpty || !minutes.todos.isEmpty { itemsSection }
            if !minutes.terms.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MinutesSectionTitle("Names & terms")
                    MinutesTermChips(terms: minutes.terms)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Summary")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundColor(OmiColors.textPrimary)
                if summaryJustChanged { MinutesTag("Just updated", live: true) }
                Spacer()
                if minutes.final {
                    MinutesTag("Final")
                } else if live {
                    MinutesTag(coveredUntil.map { "Live · to \(MinutesLogic.clock($0))" } ?? "Live")
                }
            }
            Text(minutes.summary)
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textSecondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(OmiColors.backgroundTertiary))
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MinutesSectionTitle("Topics")
            ForEach(Array(minutes.topics.enumerated()), id: \.element.id) { i, topic in
                MinutesTopicView(
                    topic: topic,
                    end: i + 1 < minutes.topics.count ? minutes.topics[i + 1].start : nil,
                    current: live && i == minutes.topics.count - 1,
                    updating: updating && i == minutes.topics.count - 1,
                    fresh: fresh)
                    .id(Self.topicAnchor(topic.id))
            }
        }
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MinutesSectionTitle(minutes.todos.isEmpty ? "Conclusions" : "Conclusions & to-dos")
            MinutesFramedList {
                let all = minutes.conclusions.map { ($0, false) } + minutes.todos.map { ($0, true) }
                ForEach(Array(all.enumerated()), id: \.offset) { i, pair in
                    MinutesItemRow(item: pair.0, todo: pair.1)
                    if i < all.count - 1 { Divider().background(OmiColors.border) }
                }
            }
        }
    }
}

/// A conclusion or a to-do, with the words it rests on under it.
private struct MinutesItemRow: View {
    let item: MinutesItem
    let todo: Bool
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if todo {
                    Image(systemName: "circle")
                        .scaledFont(size: 10)
                        .foregroundColor(OmiColors.textTertiary)
                }
                Text(item.text + (item.owner.map { " (\($0))" } ?? ""))
                    .scaledFont(size: 13)
                    .foregroundColor(item.support == 0 ? OmiColors.textQuaternary : OmiColors.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.support == 0 {
                    MinutesTag("Little support")
                        .help("No line of the transcript backs this up — treat it as a guess")
                } else if let first = item.evidence.first {
                    MinutesTimeLink(
                        text: "\(MinutesLogic.clock(first.t)) · \(item.support) \(item.support == 1 ? "line" : "lines")",
                        evidence: first)
                }
            }
            let shown = showAll ? item.evidence : Array(item.evidence.prefix(1))
            ForEach(shown, id: \.line) { ref in
                EvidenceQuote(evidence: ref)
            }
            if item.evidence.count > 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
                } label: {
                    Text(showAll ? "Show less" : "+\(item.evidence.count - 1) more")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textQuaternary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// "Speaker 1 · 03:52 — the words", clickable to the line in the transcript.
private struct EvidenceQuote: View {
    let evidence: EvidenceRef
    @State private var hover = false

    var body: some View {
        Button {
            TranscriptJumpCenter.shared.jump(lineId: evidence.lineId, t: evidence.t)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Rectangle()
                    .fill(OmiColors.border)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(evidence.speaker) · \(MinutesLogic.clock(evidence.t))")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundColor(OmiColors.textQuaternary)
                    Text("“\(evidence.quote)”")
                        .scaledFont(size: 12)
                        .italic()
                        .foregroundColor(hover ? OmiColors.textSecondary : OmiColors.textTertiary)
                        .lineLimit(hover ? 6 : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Go to this line in the transcript")
    }
}

private struct MinutesTopicView: View {
    let topic: MinutesTopic
    /// The next topic's start; nil for the last one.
    let end: Double?
    let current: Bool
    let updating: Bool
    let fresh: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(range)
                    .scaledFont(size: 11, weight: current ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundColor(current ? OmiColors.textPrimary : OmiColors.textQuaternary)
                Text(topic.title)
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundColor(OmiColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if current { MinutesTag("Now", live: true) }
                if fresh.contains(topic.title) && !current { MinutesTag("New", live: true) }
            }
            if !topic.summary.isEmpty {
                Text(topic.summary)
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                MinutesPointRow(point: point, isNew: fresh.contains(point.text))
            }
            if let fish = topic.fishbone {
                MinutesFishboneView(fishbone: fish).padding(.top, 4)
            }
            if updating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Adding what was just said…")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textQuaternary)
                }
                .padding(.top, 2)
            }
        }
        .padding(current ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(current ? Color.white.opacity(0.05) : Color.clear))
    }

    /// "01:04–02:02", or "02:03 –" for the topic being discussed.
    private var range: String {
        let from = MinutesLogic.clock(topic.start)
        guard let end, end > topic.start + 1 else { return current ? "\(from) –" : from }
        return "\(from)–\(MinutesLogic.clock(end))"
    }
}

private struct MinutesPointRow: View {
    let point: MinutesPoint
    let isNew: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isNew ? OmiColors.textPrimary : OmiColors.textQuaternary)
                .frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Text(point.text)
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textSecondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isNew { MinutesTag("New", live: true) }
            Spacer(minLength: 4)
            if let first = point.evidence.first {
                MinutesTimeLink(text: MinutesLogic.clock(first.t), evidence: first)
            }
        }
        .help(point.evidence.first.map { "\($0.speaker): “\($0.quote)”" } ?? "")
    }
}

/// A small time that jumps the transcript to the line it names.
struct MinutesTimeLink: View {
    let text: String
    let evidence: EvidenceRef
    @State private var hover = false

    var body: some View {
        Button {
            TranscriptJumpCenter.shared.jump(lineId: evidence.lineId, t: evidence.t)
        } label: {
            Text(text)
                .scaledFont(size: 11, weight: .medium)
                .monospacedDigit()
                .foregroundColor(hover ? OmiColors.textPrimary : OmiColors.textTertiary)
                .underline(hover)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Go to what was said")
    }
}

/// A fishbone drawn upright for a narrow panel: the question on top, branches alternating on
/// either side of a spine. A branch no transcript line backs is dashed.
private struct MinutesFishboneView: View {
    let fishbone: MinutesFishbone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)
                Text(fishbone.question.isEmpty ? "Why" : fishbone.question)
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundColor(OmiColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("Fishbone")
                    .scaledFont(size: 10)
                    .foregroundColor(OmiColors.textQuaternary)
            }
            VStack(spacing: 6) {
                ForEach(Array(stride(from: 0, to: fishbone.branches.count, by: 2)), id: \.self) { i in
                    HStack(alignment: .center, spacing: 0) {
                        branch(fishbone.branches[i])
                        spine
                        if i + 1 < fishbone.branches.count {
                            branch(fishbone.branches[i + 1])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Click a branch to go to what was said")
                .scaledFont(size: 10)
                .foregroundColor(OmiColors.textQuaternary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).stroke(OmiColors.border, lineWidth: 1))
    }

    private var spine: some View {
        VStack(spacing: 0) {
            Rectangle().fill(OmiColors.border).frame(width: 2)
            Circle().fill(OmiColors.textTertiary).frame(width: 6, height: 6)
            Rectangle().fill(OmiColors.border).frame(width: 2)
        }
        .frame(width: 16)
    }

    private func branch(_ b: MinutesBranch) -> some View {
        let weak = b.support == 0
        return Button {
            if let first = b.evidence.first {
                TranscriptJumpCenter.shared.jump(lineId: first.lineId, t: first.t)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(b.label)
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundColor(weak ? OmiColors.textQuaternary : OmiColors.textPrimary)
                if !b.detail.isEmpty {
                    Text(b.detail)
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(weak ? Color.clear : OmiColors.backgroundTertiary))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(weak ? OmiColors.border : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(weak ? "Little support — treat it as a guess" : (b.evidence.first.map { "\($0.speaker): “\($0.quote)”" } ?? ""))
    }
}

// MARK: - Small parts

private struct MinutesSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .scaledFont(size: 12, weight: .semibold)
            .foregroundColor(OmiColors.textTertiary)
    }
}

struct MinutesTag: View {
    let text: String
    var live = false
    init(_ text: String, live: Bool = false) {
        self.text = text
        self.live = live
    }
    var body: some View {
        Text(text)
            .scaledFont(size: 10, weight: .semibold)
            .foregroundColor(live ? OmiColors.backgroundPrimary : OmiColors.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(live ? OmiColors.textPrimary : OmiColors.backgroundQuaternary))
            .fixedSize()
    }
}

/// Names and terms: the corrected spellings first (what a reader can't work out alone), at
/// most `shown` until asked for the rest.
private struct MinutesTermChips: View {
    static let shown = 8
    let terms: [MinutesTerm]
    @State private var all = false

    var body: some View {
        let list = MinutesTerm.ordered(terms)
        let extra = list.count - Self.shown
        FlowLayout(spacing: 6) {
            ForEach(all || extra <= 0 ? list : Array(list.prefix(Self.shown))) { t in
                (Text(t.name).bold().foregroundColor(OmiColors.textPrimary)
                    + Text(t.note.isEmpty ? "" : " \(t.note)").foregroundColor(OmiColors.textSecondary)
                    + Text(t.heard.isEmpty ? "" : " · heard as \(t.heard.prefix(2).joined(separator: ", "))")
                    .foregroundColor(OmiColors.textQuaternary))
                    .scaledFont(size: 11)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(OmiColors.backgroundTertiary))
            }
            if extra > 0 {
                Button {
                    all.toggle()
                } label: {
                    Text(all ? "Show less" : "All \(list.count)")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MinutesFramedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(OmiColors.backgroundTertiary.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OmiColors.border, lineWidth: 1))
    }
}
