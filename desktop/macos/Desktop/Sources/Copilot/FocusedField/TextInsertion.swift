import AppKit
import CoreGraphics

/// Insert text into whatever app has keyboard focus.
///
/// Ported from cetus (`src-tauri/src/text_input.rs`, MIT). Two strategies, because no
/// single one works everywhere:
///
/// - ``InsertMode/type`` synthesizes key events carrying the Unicode string directly.
///   Never touches the clipboard, which is what you want by default.
/// - ``InsertMode/paste`` stashes the text on the pasteboard, synthesizes ⌘V, then
///   restores the previous clipboard. More robust in apps that ignore synthetic Unicode
///   keystrokes — terminals and some Electron builds — at the cost of briefly clobbering
///   the clipboard.
///
/// Both need Accessibility trust, which omi already requests.
enum TextInsertion {
    enum InsertMode: String, CaseIterable {
        case type
        case paste

        var displayName: String {
            switch self {
            case .type: return "Type it"
            case .paste: return "Paste it"
            }
        }

        var subtitle: String {
            switch self {
            case .type: return "Never touches your clipboard. Works in most apps."
            case .paste: return "Briefly uses the clipboard. Needed by terminals and some apps."
            }
        }
    }

    /// Post at the *session* level, not the HID level. A `hidutil` UserKeyMapping lives at
    /// the HID level, so keystrokes injected there run through the user's own remaps and
    /// can be silently dropped. The session tap sits above that layer.
    private static let sessionEventTap = CGEventTapLocation.cgSessionEventTap
    private static let keycodeV: CGKeyCode = 0x09
    /// A source whose modifier state is independent of the hardware, so a stuck modifier
    /// (notably Caps Lock left asserted by a remap) can't ride along on our keystrokes.
    private static let privateSourceState = CGEventSourceStateID.privateState

    /// The app to insert back into, captured while the user is still in it.
    ///
    /// Recorded when a suggestion is *generated* rather than when its card is presented:
    /// presentation can be queued behind another card, and by then the user may have
    /// moved on. Returns nil when omi itself is frontmost — there is no meaningful
    /// target then, and inserting into our own UI would be worse than doing nothing.
    @MainActor
    static func currentTargetPID() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return front.processIdentifier
    }

    /// Same as ``currentTargetPID()``, but nil unless that app actually has an editable
    /// field focused. This is what gates the "Insert" affordance: offering to type an
    /// answer into a PDF reader or a video call window is noise, and the only honest way
    /// to know the difference is to ask the accessibility tree.
    @MainActor
    static func insertableTargetPID() -> pid_t? {
        guard let pid = currentTargetPID() else { return nil }
        return AXFocusedText.hasEditableFocus(pid: pid) ? pid : nil
    }

    /// Bring `pid` to the front and give it a beat to take focus.
    ///
    /// omi's HUD can become key (`FloatingControlBarWindow.canBecomeKey` is true), so
    /// unlike cetus we can't assume focus stayed put. Callers capture the target pid when
    /// the card is *presented* and pass it here.
    @MainActor
    static func focusApp(pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard !app.isActive else { return }
        app.activate()
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    /// Focus `pid` (when one was captured) and insert `text` using the user's chosen mode.
    ///
    /// This is what the "Insert" buttons call. The event posting and the deliberate pacing
    /// between chunks run off the main actor so a long answer can't stutter the HUD, but the
    /// pasteboard hops back to the main actor — `NSPasteboard` is not documented as
    /// thread-safe, and this path clobbers the user's real clipboard.
    @MainActor
    @discardableResult
    static func insertIntoTarget(_ text: String, pid: pid_t?, mode: InsertMode? = nil) async -> Bool {
        guard !text.isEmpty else { return true }
        guard AXIsProcessTrusted() else {
            log("TextInsertion: no accessibility permission")
            return false
        }
        let mode = mode ?? CopilotSettings.shared.insertMode
        if let pid { await focusApp(pid: pid) }
        switch mode {
        case .type:
            await Task.detached(priority: .userInitiated) { typeUnicode(text) }.value
        case .paste:
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            await Task.detached(priority: .userInitiated) { postPasteAndSettle() }.value
            if let saved {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        // What the user does to this text in the next few seconds is the only unambiguous
        // signal we get about what omi got wrong.
        if let pid { InsertCorrectionWatcher.observe(inserted: text, pid: pid) }
        return true
    }

    // MARK: - Type

    /// Type a Unicode string by posting key events that carry it directly. Chunked
    /// because a single event's Unicode payload is only reliable for short strings.
    private static func typeUnicode(_ text: String) {
        let units = Array(text.utf16)
        let source = CGEventSource(stateID: privateSourceState)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            post(chunk: chunk, source: source)
            // A hair of pacing so fast apps don't drop events.
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private static func post(chunk: [UInt16], source: CGEventSource?) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
            else { continue }
            // Force flags to zero so an ambient or stuck modifier can't turn this into a
            // modified keycode-0 chord, which apps drop instead of inserting.
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.post(tap: sessionEventTap)
        }
    }

    // MARK: - Paste

    /// Synthesize ⌘V and wait for the target app to actually perform the paste. The caller
    /// must not restore the clipboard before this returns, or the app pastes the old value.
    private static func postPasteAndSettle() {
        synthesizeCommandV()
        Thread.sleep(forTimeInterval: 0.12)
    }

    private static func synthesizeCommandV() {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycodeV, keyDown: isDown)
            else { continue }
            event.flags = .maskCommand
            event.post(tap: sessionEventTap)
        }
    }
}
