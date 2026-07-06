import AppKit
import Foundation

// MARK: - Models

/// A screen-op suggestion: a specific way to unblock what the user is doing right now.
struct ScreenOpSuggestion: Codable {
    let suggestion: String
    let headline: String?
    let reasoning: String?
    let category: String
    let sourceApp: String
    let confidence: Double
    /// Imperative instruction an agent could execute to apply the fix (Execute button).
    let actionPrompt: String?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "suggestion": suggestion,
            "category": category,
            "sourceApp": sourceApp,
            "confidence": confidence,
        ]
        if let headline { dict["headline"] = headline }
        if let reasoning { dict["reasoning"] = reasoning }
        if let actionPrompt { dict["actionPrompt"] = actionPrompt }
        return dict
    }
}

struct ScreenOpExtractionResult: AssistantResult {
    let hasSuggestion: Bool
    let suggestion: ScreenOpSuggestion?
    let contextSummary: String
    let currentActivity: String

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "hasSuggestion": hasSuggestion,
            "contextSummary": contextSummary,
            "currentActivity": currentActivity,
        ]
        if let suggestion {
            dict["suggestion"] = suggestion.toDictionary()
        }
        return dict
    }
}

// MARK: - Assistant

/// Passive "are you stuck?" assistant. Watches the current app's recent OCR history
/// for stuck signals (repeating errors, static content, docs oscillation) via the same
/// two-phase pipeline as InsightAssistant — Phase 1 text-only SQL investigation, then
/// Phase 2 vision confirmation — but scoped to the current app and the last 10 minutes,
/// and producing actionable suggestions the Execute button can hand to an agent.
actor ScreenOpAssistant: ProactiveAssistant {
    // MARK: - ProactiveAssistant Protocol

    nonisolated let identifier = "screen_op"
    nonisolated let displayName = "Screen-Op Assist"

    var isEnabled: Bool {
        get async {
            await MainActor.run {
                ScreenOpAssistantSettings.shared.isEnabled
                    && ScreenOpAssistantSettings.shared.notificationsEnabled
            }
        }
    }

    // MARK: - Properties

    private let geminiClient: GeminiClient
    private var isRunning = false
    private var lastAnalysisTime: Date = .distantPast
    private var previousSuggestions: [String] = []
    private let maxPreviousSuggestions = 50
    private let maxSuggestionsInPrompt = 30
    private var pendingFrame: CapturedFrame?
    private var processingTask: Task<Void, Never>?
    private let frameSignal: AsyncStream<Void>
    private let frameSignalContinuation: AsyncStream<Void>.Continuation
    /// Set by the context-switch fast path so the process loop skips the remaining interval wait.
    private var fastPathRequested = false

    /// How far back the investigation looks (current-app OCR window).
    private let investigationLookback: TimeInterval = 10 * 60
    /// Minimum spacing the fast path still respects.
    private let fastPathMinSpacing: TimeInterval = 45

    /// Apps where "stuck" is common and a context switch warrants a prompt look.
    private static let fastPathApps: Set<String> = [
        "Terminal", "iTerm2", "Xcode", "Code", "Visual Studio Code", "Cursor", "Warp",
    ]

    private var systemPrompt: String {
        get async {
            await MainActor.run { ScreenOpAssistantSettings.shared.analysisPrompt }
        }
    }

    private var extractionInterval: TimeInterval {
        get async {
            await MainActor.run { ScreenOpAssistantSettings.shared.extractionInterval }
        }
    }

    private var minConfidence: Double {
        get async {
            await MainActor.run { ScreenOpAssistantSettings.shared.minConfidence }
        }
    }

    // MARK: - Initialization

    init(apiKey: String? = nil) throws {
        self.geminiClient = try GeminiClient(
            apiKey: apiKey, model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.frameSignal = stream
        self.frameSignalContinuation = continuation

        Task {
            await self.startProcessing()
        }
    }

    // MARK: - Processing

    private func startProcessing() {
        isRunning = true
        Task {
            await loadPreviousSuggestionsFromDB()
        }
        processingTask = Task {
            await processLoop()
        }
    }

    /// Load previous suggestions (ours + insight tips) so we never repeat another
    /// assistant's advice — the "single voice" rule across the proactive family.
    private func loadPreviousSuggestionsFromDB() async {
        do {
            let ownMemories = try await MemoryStorage.shared.getLocalMemories(
                limit: maxPreviousSuggestions, category: "system", tags: ["screen_op"])
            let tipMemories = try await MemoryStorage.shared.getLocalMemories(
                limit: maxPreviousSuggestions, category: "system", tags: ["tips"])
            previousSuggestions = (ownMemories + tipMemories)
                .map { $0.content }
                .prefix(maxPreviousSuggestions)
                .map { $0 }
            if !previousSuggestions.isEmpty {
                log("ScreenOp: Loaded \(previousSuggestions.count) previous suggestions/tips for dedup")
            }
        } catch {
            logError("ScreenOp: Failed to load previous suggestions from DB", error: error)
        }
    }

    private func processLoop() async {
        log("ScreenOp assistant started")

        for await _ in frameSignal {
            guard isRunning else { break }
            guard pendingFrame != nil else { continue }

            // Wait out the extraction interval in short slices so a fast-path
            // request (context switch into a dev app) can cut the wait short.
            let interval = await extractionInterval
            while !fastPathRequested {
                let elapsed = Date().timeIntervalSince(lastAnalysisTime)
                let remaining = interval - elapsed
                guard remaining > 0 else { break }
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, 5) * 1_000_000_000))
            }
            if fastPathRequested {
                // Fast path still keeps a minimum spacing between analyses.
                let sinceLast = Date().timeIntervalSince(lastAnalysisTime)
                if sinceLast < fastPathMinSpacing {
                    try? await Task.sleep(
                        nanoseconds: UInt64((fastPathMinSpacing - sinceLast) * 1_000_000_000))
                }
                fastPathRequested = false
            }

            guard let frame = pendingFrame else { continue }
            pendingFrame = nil
            lastAnalysisTime = Date()
            await processFrame(frame)
        }

        log("ScreenOp assistant stopped")
    }

    // MARK: - ProactiveAssistant Protocol Methods

    func shouldAnalyze(frameNumber: Int, timeSinceLastAnalysis: TimeInterval) -> Bool {
        // Interval is enforced in the processing loop; here we just accept the latest frame.
        return true
    }

    func analyze(frame: CapturedFrame) async -> AssistantResult? {
        let excluded = await MainActor.run { ScreenOpAssistantSettings.shared.isAppExcluded(frame.appName) }
        if excluded {
            return nil
        }
        pendingFrame = frame
        frameSignalContinuation.yield()
        return nil
    }

    func handleResult(_ result: AssistantResult, sendEvent: @escaping (String, [String: Any]) -> Void) async {
        guard let opResult = result as? ScreenOpExtractionResult else { return }
        await handleExtractionResult(opResult, screenshotId: nil, windowTitle: nil, sendEvent: sendEvent)
    }

    /// Context-switch fast path: landing in a dev/terminal app is the moment stuck
    /// signals matter most — allow one prompt evaluation instead of waiting the full interval.
    func onContextSwitch(departingFrame: CapturedFrame?, newApp: String, newWindowTitle: String?) async {
        guard Self.fastPathApps.contains(newApp) else { return }
        guard Date().timeIntervalSince(lastAnalysisTime) >= fastPathMinSpacing else { return }
        guard await isEnabled else { return }
        log("ScreenOp: fast path — context switch into \(newApp)")
        fastPathRequested = true
        frameSignalContinuation.yield()
    }

    func clearPendingWork() async {
        pendingFrame = nil
    }

    func stop() async {
        isRunning = false
        processingTask?.cancel()
        pendingFrame = nil
    }

    // MARK: - Analysis

    private func processFrame(_ frame: CapturedFrame) async {
        guard await isEnabled else { return }
        do {
            let (result, _) = try await runSuggestionExtraction(
                appName: frame.appName,
                windowTitle: frame.windowTitle,
                referenceTime: Date()
            )
            guard let result else { return }
            await handleExtractionResult(
                result, screenshotId: frame.screenshotId, windowTitle: frame.windowTitle
            ) { type, data in
                Task { @MainActor in
                    AssistantCoordinator.shared.sendEvent(type: type, data: data)
                }
            }
        } catch {
            logError("ScreenOp extraction error", error: error)
        }
    }

    /// Run the extraction pipeline without side effects, for the omi-ctl test action.
    func testAnalyze(appName: String, windowTitle: String?) async throws -> (ScreenOpExtractionResult?, Int) {
        try await runSuggestionExtraction(
            appName: appName, windowTitle: windowTitle, referenceTime: Date())
    }

    // MARK: - Core Extraction (two-phase, cloned from InsightAssistant)

    private func runSuggestionExtraction(
        appName: String,
        windowTitle: String?,
        referenceTime: Date
    ) async throws -> (ScreenOpExtractionResult?, Int) {
        var sqlCount = 0

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a, EEEE"
        let lookbackStart = referenceTime.addingTimeInterval(-investigationLookback)
        let isoFormatter = ISO8601DateFormatter()

        var prompt = "CURRENT APP: \(appName)."
        if let windowTitle, !windowTitle.isEmpty {
            prompt += " Window: \"\(windowTitle)\"."
        }
        prompt += " Time: \(timeFormatter.string(from: referenceTime))."
        prompt += "\nInvestigation window: screenshots with timestamp >= '\(isoFormatter.string(from: lookbackStart))' AND appName = '\(appName.replacingOccurrences(of: "'", with: "''"))'."

        if let profile = await AIUserProfileService.shared.getLatestProfile() {
            prompt += "\n\nUSER PROFILE (who this user is):\n" + profile.profileText + "\n"
        }

        if !previousSuggestions.isEmpty {
            prompt += "\n\nPREVIOUSLY PROVIDED SUGGESTIONS (do not repeat these or semantically similar):\n"
            for (index, prev) in previousSuggestions.prefix(maxSuggestionsInPrompt).enumerated() {
                prompt += "\(index + 1). \(prev)\n"
            }
        }

        prompt += "\n\nInvestigate the current app's recent OCR for stuck signals. Query ONLY the current app within the investigation window. When you find a stuck signal, call request_screenshot with the ID and your findings. Otherwise call no_suggestion."

        var currentSystemPrompt = await systemPrompt
        currentSystemPrompt +=
            "\n\nDATABASE SCHEMA for execute_sql:\nscreenshots table columns: id INTEGER, timestamp TEXT, appName TEXT, windowTitle TEXT, ocrText TEXT, focusStatus TEXT"

        // =============================================
        // PHASE 1: Text-only investigation loop
        // =============================================

        let phase1Tools = buildPhase1Tools()
        var contents: [GeminiImageToolRequest.Content] = [
            GeminiImageToolRequest.Content(
                role: "user",
                parts: [GeminiImageToolRequest.Part(text: prompt)]
            )
        ]

        let client = self.geminiClient
        var chosenScreenshotId: Int64?
        var investigationFindings: String?

        for iteration in 0..<6 {
            let iterContents = contents
            let iterSystemPrompt = currentSystemPrompt
            let iterTools = [phase1Tools]
            let iterForce = iteration == 0
            let result: ToolChatResult = try await withThrowingTimeoutScreenOp(seconds: 120) {
                try await client.sendImageToolLoop(
                    contents: iterContents,
                    systemPrompt: iterSystemPrompt,
                    tools: iterTools,
                    forceToolCall: iterForce,
                    thinkingBudget: 1024
                )
            }

            guard let toolCall = result.toolCalls.first else {
                log("ScreenOp: Phase 1 — no tool call on iteration \(iteration), breaking")
                break
            }

            switch toolCall.name {
            case "execute_sql":
                let query = toolCall.arguments["query"] as? String ?? ""
                sqlCount += 1
                let sqlToolCall = ToolCall(name: "execute_sql", arguments: ["query": query], thoughtSignature: nil)
                let resultStr = await ChatToolExecutor.execute(sqlToolCall)
                contents.append(GeminiImageToolRequest.Content(
                    role: "model",
                    parts: [GeminiImageToolRequest.Part(
                        functionCall: .init(name: toolCall.name, args: ["query": query]),
                        thoughtSignature: toolCall.thoughtSignature
                    )]
                ))
                contents.append(GeminiImageToolRequest.Content(
                    role: "user",
                    parts: [GeminiImageToolRequest.Part(functionResponse: .init(
                        name: toolCall.name,
                        response: .init(result: resultStr)
                    ))]
                ))
                continue

            case "request_screenshot":
                investigationFindings = toolCall.arguments["findings"] as? String ?? ""
                if let idInt = toolCall.arguments["screenshot_id"] as? Int {
                    chosenScreenshotId = Int64(idInt)
                } else if let idInt64 = toolCall.arguments["screenshot_id"] as? Int64 {
                    chosenScreenshotId = idInt64
                } else if let idStr = toolCall.arguments["screenshot_id"] as? String, let parsed = Int64(idStr) {
                    chosenScreenshotId = parsed
                } else if let idDouble = toolCall.arguments["screenshot_id"] as? Double {
                    chosenScreenshotId = Int64(idDouble)
                }

            case "no_suggestion":
                let contextSummary = toolCall.arguments["context_summary"] as? String ?? "No context"
                let currentActivity = toolCall.arguments["current_activity"] as? String ?? "Unknown"
                return (ScreenOpExtractionResult(
                    hasSuggestion: false,
                    suggestion: nil,
                    contextSummary: contextSummary,
                    currentActivity: currentActivity
                ), sqlCount)

            default:
                log("ScreenOp: P1 unknown tool: \(toolCall.name), breaking")
            }

            if chosenScreenshotId != nil { break }
        }

        guard let screenshotId = chosenScreenshotId, let findings = investigationFindings else {
            return (nil, sqlCount)
        }

        // =============================================
        // PHASE 2: Vision confirmation with the chosen screenshot
        // =============================================

        let imageData: Data
        do {
            guard let screenshot = try await RewindDatabase.shared.getScreenshot(id: screenshotId) else {
                return (nil, sqlCount)
            }
            if screenshot.usesVideoStorage, let chunk = screenshot.videoChunkPath {
                let activeChunk = await VideoChunkEncoder.shared.currentChunkPath
                if chunk == activeChunk {
                    log("ScreenOp: P2 screenshot is in active chunk, skipping")
                    return (nil, sqlCount)
                }
            }
            let rawData = try await RewindStorage.shared.loadScreenshotData(for: screenshot)
            imageData = GeminiImageCompression.compress(rawData) ?? rawData
        } catch {
            log("ScreenOp: P2 screenshot load failed: \(error.localizedDescription)")
            return (nil, sqlCount)
        }

        let phase2Prompt = """
            INVESTIGATION FINDINGS:
            \(findings)

            The screenshot below is from the current app, identified during investigation.

            Before suggesting, CROSS-REFERENCE with execute_sql:
            - Was the error/blocker resolved in later screenshots?
            - Did the user move past it already?

            Then call provide_suggestion if the user is still stuck and you have a specific fix, or no_suggestion otherwise.
            """

        let phase2Tools = buildPhase2Tools()
        let base64 = imageData.base64EncodedString()
        var phase2Contents: [GeminiImageToolRequest.Content] = [
            GeminiImageToolRequest.Content(
                role: "user",
                parts: [
                    GeminiImageToolRequest.Part(text: phase2Prompt),
                    GeminiImageToolRequest.Part(mimeType: "image/jpeg", data: base64),
                ]
            )
        ]

        for _ in 0..<4 {
            let p2Contents = phase2Contents
            let p2SystemPrompt = currentSystemPrompt
            let p2Tools = [phase2Tools]
            let phase2Result: ToolChatResult = try await withThrowingTimeoutScreenOp(seconds: 120) {
                try await client.sendImageToolLoop(
                    contents: p2Contents,
                    systemPrompt: p2SystemPrompt,
                    tools: p2Tools,
                    forceToolCall: true,
                    thinkingBudget: 1024
                )
            }

            guard let toolCall = phase2Result.toolCalls.first else { break }

            switch toolCall.name {
            case "execute_sql":
                let query = toolCall.arguments["query"] as? String ?? ""
                sqlCount += 1
                let sqlToolCall = ToolCall(name: "execute_sql", arguments: ["query": query], thoughtSignature: nil)
                let resultStr = await ChatToolExecutor.execute(sqlToolCall)
                phase2Contents.append(GeminiImageToolRequest.Content(
                    role: "model",
                    parts: [GeminiImageToolRequest.Part(
                        functionCall: .init(name: toolCall.name, args: ["query": query]),
                        thoughtSignature: toolCall.thoughtSignature
                    )]
                ))
                phase2Contents.append(GeminiImageToolRequest.Content(
                    role: "user",
                    parts: [GeminiImageToolRequest.Part(functionResponse: .init(
                        name: toolCall.name,
                        response: .init(result: resultStr)
                    ))]
                ))
                continue

            case "provide_suggestion":
                return (parseProvideSuggestion(toolCall), sqlCount)

            case "no_suggestion":
                let contextSummary = toolCall.arguments["context_summary"] as? String ?? "No context"
                let currentActivity = toolCall.arguments["current_activity"] as? String ?? "Unknown"
                return (ScreenOpExtractionResult(
                    hasSuggestion: false,
                    suggestion: nil,
                    contextSummary: contextSummary,
                    currentActivity: currentActivity
                ), sqlCount)

            default:
                break
            }
            break
        }
        return (nil, sqlCount)
    }

    // MARK: - Result Handling

    private func handleExtractionResult(
        _ result: ScreenOpExtractionResult,
        screenshotId: Int64?,
        windowTitle: String?,
        sendEvent: @escaping (String, [String: Any]) -> Void
    ) async {
        guard result.hasSuggestion, let suggestion = result.suggestion else { return }

        let threshold = await minConfidence
        guard suggestion.confidence >= threshold else {
            log("ScreenOp: [\(Int(suggestion.confidence * 100))% < \(Int(threshold * 100))%] Filtered: \"\(suggestion.suggestion)\"")
            return
        }

        log("ScreenOp: [\(Int(suggestion.confidence * 100))% conf.] \"\(suggestion.suggestion)\"")

        previousSuggestions.insert(suggestion.suggestion, at: 0)
        if previousSuggestions.count > maxPreviousSuggestions {
            previousSuggestions.removeLast()
        }

        // Local persistence (tags ["screen_op", <cat>], same MemoryStorage lane as insight tips)
        let tags = ["screen_op", suggestion.category.lowercased()]
        let tagsJson = (try? JSONEncoder().encode(tags)).flatMap { String(data: $0, encoding: .utf8) }
        let record = MemoryRecord(
            backendSynced: false,
            content: suggestion.suggestion,
            category: "system",
            tagsJson: tagsJson,
            source: "screenshot",
            screenshotId: screenshotId,
            confidence: suggestion.confidence,
            reasoning: suggestion.reasoning,
            sourceApp: suggestion.sourceApp,
            windowTitle: windowTitle,
            contextSummary: result.contextSummary,
            currentActivity: result.currentActivity,
            headline: suggestion.headline
        )
        var localRecordId: Int64?
        do {
            let inserted = try await MemoryStorage.shared.insertLocalMemory(record)
            localRecordId = inserted.id
        } catch {
            logError("ScreenOp: Failed to save to SQLite", error: error)
        }

        // Backend sync (same path as insight)
        do {
            let response = try await APIClient.shared.createMemory(
                content: suggestion.suggestion,
                visibility: "private",
                category: .interesting,
                confidence: suggestion.confidence,
                sourceApp: suggestion.sourceApp,
                contextSummary: result.contextSummary,
                tags: tags,
                reasoning: suggestion.reasoning,
                currentActivity: result.currentActivity,
                source: "screenshot",
                windowTitle: windowTitle,
                headline: suggestion.headline
            )
            if let localRecordId {
                try? await MemoryStorage.shared.markSynced(id: localRecordId, backendId: response.id)
            }
        } catch {
            logError("ScreenOp: Failed to sync to backend", error: error)
        }

        // Notification card (reuses the copilot card: Copy / Execute / Dismiss;
        // detail carries the agent-executable instruction for the Execute button)
        let notificationsEnabled = await MainActor.run {
            ScreenOpAssistantSettings.shared.notificationsEnabled
        }
        if notificationsEnabled {
            let headline = suggestion.headline ?? "Screen-Op suggestion"
            let context = FloatingBarNotificationContext(
                sourceTitle: "Screen-Op",
                assistantId: identifier,
                sourceApp: suggestion.sourceApp,
                windowTitle: windowTitle,
                contextSummary: result.contextSummary,
                currentActivity: result.currentActivity,
                reasoning: suggestion.reasoning,
                detail: suggestion.actionPrompt
            )
            let message = suggestion.suggestion
            await MainActor.run {
                NotificationService.shared.sendNotification(
                    title: headline,
                    message: message,
                    assistantId: "copilot",
                    context: context
                )
                PostHogManager.shared.track(
                    "screen_op_suggestion",
                    properties: [
                        "category": suggestion.category,
                        "confidence": suggestion.confidence,
                        "has_action": suggestion.actionPrompt?.isEmpty == false,
                    ]
                )
            }
        }

        sendEvent("screenOpSuggestionProvided", [
            "assistant": identifier,
            "suggestion": suggestion.toDictionary(),
            "contextSummary": result.contextSummary,
        ])
    }

    // MARK: - Tool Definitions

    private func buildPhase1Tools() -> GeminiTool {
        GeminiTool(functionDeclarations: [
            GeminiTool.FunctionDeclaration(
                name: "execute_sql",
                description: "Execute a SQL query on the local database to investigate the CURRENT app's recent screen activity. The screenshots table has: id INTEGER, timestamp TEXT, appName TEXT, windowTitle TEXT, ocrText TEXT, focusStatus TEXT. Only query the current app within the investigation window. SELECT queries only. Auto-limited to 200 rows.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "SQL SELECT query to execute on the screenshots table")
                    ],
                    required: ["query"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "request_screenshot",
                description: "Request to view a specific screenshot after finding a stuck signal via SQL. Provide the screenshot ID and a summary of the stuck signal you found.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "screenshot_id": .init(type: "integer", description: "The screenshot ID from the screenshots table"),
                        "findings": .init(type: "string", description: "The stuck signal you found — what error/blocker, how long, what evidence"),
                    ],
                    required: ["screenshot_id", "findings"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "no_suggestion",
                description: "Call this when the user is not stuck, is making progress, or you have no specific non-obvious fix. This ends the analysis. Silence is the default.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "context_summary": .init(type: "string", description: "Brief summary of what user is doing"),
                        "current_activity": .init(type: "string", description: "High-level description of user's activity"),
                    ],
                    required: ["context_summary", "current_activity"]
                )
            ),
        ])
    }

    private func buildPhase2Tools() -> GeminiTool {
        GeminiTool(functionDeclarations: [
            GeminiTool.FunctionDeclaration(
                name: "execute_sql",
                description: "Cross-reference: check whether the blocker was resolved in later screenshots before suggesting. SELECT queries only.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "SQL SELECT query to execute on the screenshots table")
                    ],
                    required: ["query"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "provide_suggestion",
                description: "Call this when the user is stuck on something visible and you have a specific, non-obvious, actionable fix. Cross-reference first with execute_sql to verify the blocker is still current.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "suggestion": .init(type: "string", description: "The fix (1-2 sentences, max 100 chars). Start with the actionable part."),
                        "headline": .init(type: "string", description: "Ultra-short label (max 5 words), e.g. 'Port already in use'"),
                        "reasoning": .init(type: "string", description: "Brief explanation of the stuck signal and why this fix applies"),
                        "category": .init(type: "string", description: "Category of suggestion", enumValues: ["fix", "shortcut", "unblock", "other"]),
                        "source_app": .init(type: "string", description: "App where the blocker was observed"),
                        "confidence": .init(type: "number", description: "Confidence 0.0-1.0. 0.90+: visible error with known fix. 0.80-0.89: strong stuck signal + concrete way forward."),
                        "context_summary": .init(type: "string", description: "Brief summary of what user is doing"),
                        "current_activity": .init(type: "string", description: "High-level description of user's activity"),
                        "action_prompt": .init(type: "string", description: "A single imperative instruction a desktop agent could execute to apply the fix, e.g. 'Kill the process listening on port 8080 and rerun npm start'"),
                    ],
                    required: ["suggestion", "headline", "category", "source_app", "confidence", "context_summary", "current_activity"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "no_suggestion",
                description: "Call this when the screenshot shows the user is fine, the blocker was already resolved, or your fix would be generic.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "context_summary": .init(type: "string", description: "Brief summary of what user is doing"),
                        "current_activity": .init(type: "string", description: "High-level description of user's activity"),
                    ],
                    required: ["context_summary", "current_activity"]
                )
            ),
        ])
    }

    // MARK: - Parse Tool Results

    private func parseProvideSuggestion(_ toolCall: ToolCall) -> ScreenOpExtractionResult {
        let suggestionText = toolCall.arguments["suggestion"] as? String ?? ""
        let headline = toolCall.arguments["headline"] as? String
        let reasoning = toolCall.arguments["reasoning"] as? String
        let category = toolCall.arguments["category"] as? String ?? "other"
        let sourceApp = toolCall.arguments["source_app"] as? String ?? ""
        let contextSummary = toolCall.arguments["context_summary"] as? String ?? ""
        let currentActivity = toolCall.arguments["current_activity"] as? String ?? ""
        let actionPrompt = toolCall.arguments["action_prompt"] as? String

        let confidence: Double
        if let confValue = toolCall.arguments["confidence"] as? Double {
            confidence = confValue
        } else if let confInt = toolCall.arguments["confidence"] as? Int {
            confidence = Double(confInt)
        } else if let confStr = toolCall.arguments["confidence"] as? String, let parsed = Double(confStr) {
            confidence = parsed
        } else {
            confidence = 0.5
        }

        let suggestion = ScreenOpSuggestion(
            suggestion: suggestionText,
            headline: headline,
            reasoning: reasoning,
            category: category,
            sourceApp: sourceApp,
            confidence: confidence,
            actionPrompt: actionPrompt
        )
        return ScreenOpExtractionResult(
            hasSuggestion: true,
            suggestion: suggestion,
            contextSummary: contextSummary,
            currentActivity: currentActivity
        )
    }
}

// MARK: - Timeout Helper

private func withThrowingTimeoutScreenOp<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
