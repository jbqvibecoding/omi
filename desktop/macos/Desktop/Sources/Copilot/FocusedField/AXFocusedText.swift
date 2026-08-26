import AppKit
import ApplicationServices

/// What the user is currently typing into, read over the Accessibility API.
///
/// Ported from cetus (`src-tauri/src/focused_text.rs`, MIT) — the four-step ladder and
/// its ordering are the load-bearing part. macOS text surfaces expose several
/// incompatible shapes: native controls use `AXValue` + `AXSelectedTextRange`,
/// Chromium/Electron rich editors use opaque `AXTextMarkerRange`s, and some custom or
/// canvas UIs expose no editable text at all. Reading only the first shape works on
/// TextEdit and fails on Slack, which is where people actually write.
struct FocusedTextSnapshot: Equatable {
    let app: String
    let bundleId: String
    let pid: pid_t
    let role: String
    let subrole: String
    let identifier: String
    /// Coarse element geometry, the fallback identity for apps with no AXIdentifier.
    /// Rounded so tiny layout shifts don't read as a different field.
    let frameKey: String
    let before: String
    let selected: String
    let after: String
    /// Which rung of the ladder produced this: value-range / text-marker / value / subtree.
    let source: String

    var text: String { before + selected + after }

    /// Context nearest the insertion point, balanced around the caret rather than
    /// blindly taking the end of a potentially long document.
    func nearby(maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let selectedLen = min(selected.count, maxChars)
        let remaining = maxChars - selectedLen
        let beforeBudget = remaining / 2 + remaining % 2
        let afterBudget = remaining / 2
        let head = String(before.suffix(beforeBudget))
        let mid = String(selected.prefix(selectedLen))
        let tail = String(after.prefix(afterBudget))
        return (head + mid + tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a later re-read landed on the same field, so a diff between them is
    /// meaningful. Identity is the app plus whatever stable handle the app exposes.
    func isSameTarget(as other: FocusedTextSnapshot) -> Bool {
        guard pid == other.pid, role == other.role else { return false }
        if !identifier.isEmpty || !other.identifier.isEmpty {
            return identifier == other.identifier
        }
        return frameKey == other.frameKey
    }
}

@MainActor
enum AXFocusedText {
    /// Every AX read is a synchronous IPC round-trip into the target app, so a hung app
    /// would otherwise hang us too.
    private static let messagingTimeout: Float = 0.25

    /// Read the focused text field of `pid`, or of the frontmost app when nil.
    static func capture(pid: pid_t? = nil, maxChars: Int = 4000) -> FocusedTextSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = resolveApp(pid: pid), app.processIdentifier > 0 else { return nil }

        // Chromium apps don't build a tree until an assistive client announces itself.
        ElectronAXWaker.wakeIfNeeded(app: app)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = copyString(focused, kAXRoleAttribute) ?? ""
        let subrole = copyString(focused, kAXSubroleAttribute) ?? ""
        // Never read a password field — checked on both attributes because apps disagree
        // about which one carries it.
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return nil }

        let identifier =
            copyString(focused, kAXIdentifierAttribute)
            ?? copyString(focused, "AXDOMIdentifier") ?? ""
        let value = copyString(focused, kAXValueAttribute)

        var before = ""
        var selected = ""
        var after = ""
        var source = ""

        if let value, let range = selectedRange(focused) {
            (before, selected, after) = splitUTF16(value, location: range.location, length: range.length)
            source = "value-range"
        } else if let parts = textMarkerParts(focused) {
            // Chromium frequently exposes AXValue but omits the standard selected range.
            // A text marker beats guessing that the caret sits at the end.
            (before, selected, after) = parts
            source = "text-marker"
        } else if let value {
            // Some controls give the selected string but no range. Trust it only when it
            // appears exactly once; otherwise treat the caret as the end of the value.
            let selectedText = copyString(focused, kAXSelectedTextAttribute) ?? ""
            if !selectedText.isEmpty, occurrences(of: selectedText, in: value) == 1,
                let at = value.range(of: selectedText)
            {
                before = String(value[value.startIndex..<at.lowerBound])
                selected = selectedText
                after = String(value[at.upperBound...])
            } else {
                before = value
            }
            source = "value"
        } else {
            let walkable: Set<String> = [
                "AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXGroup",
                "AXGenericElement",
            ]
            guard walkable.contains(role),
                let text = gatherSubtree(focused, budget: max(maxChars * 2, 512))
            else { return nil }
            before = text
            source = "subtree"
        }

        var snapshot = FocusedTextSnapshot(
            app: app.localizedName ?? "", bundleId: app.bundleIdentifier ?? "",
            pid: app.processIdentifier, role: role, subrole: subrole, identifier: identifier,
            frameKey: frameKey(focused), before: before, selected: selected, after: after,
            source: source)
        snapshot = bound(snapshot, maxChars: max(maxChars, 1))
        return snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : snapshot
    }

    /// Roles that accept typed text. `AXWebArea` is deliberately absent: a plain web page
    /// has one, and it isn't somewhere to insert.
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Whether `pid` has an editable text field focused right now.
    ///
    /// Cheaper than ``capture(pid:maxChars:)`` — a handful of AX reads, no value copy —
    /// and, unlike it, true for an *empty* compose box. That case is the whole point: an
    /// empty field is the most likely place for an answer to go, but it has no text for
    /// `capture` to return.
    static func hasEditableFocus(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), pid > 0 else { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            ElectronAXWaker.wakeIfNeeded(app: app)
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else {
            return false
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = copyString(focused, kAXRoleAttribute) ?? ""
        let subrole = copyString(focused, kAXSubroleAttribute) ?? ""
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return false }
        if editableRoles.contains(role) { return true }

        // Rich editors (Chromium contenteditable, some native ones) report a generic role
        // but still let the value be written, which is the property we actually care about.
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
                == .success
        else { return false }
        return settable.boolValue
    }

    // MARK: - Ladder helpers

    private static func resolveApp(pid: pid_t?) -> NSRunningApplication? {
        guard let pid else { return NSWorkspace.shared.frontmostApplication }
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = copyValue(element, kAXSelectedTextRangeAttribute) else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swift-format-ignore: NeverForceUnwrap — type id checked immediately above.
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The Chromium/Electron path: walk opaque text markers to recover before/selected/after.
    private static func textMarkerParts(_ element: AXUIElement) -> (String, String, String)? {
        guard
            let full = copyParameterized(element, "AXTextMarkerRangeForUIElement", element),
            let selectedRange = copyValue(element, "AXSelectedTextMarkerRange"),
            let fullStart = copyParameterized(element, "AXStartTextMarkerForTextMarkerRange", full),
            let fullEnd = copyParameterized(element, "AXEndTextMarkerForTextMarkerRange", full),
            let selStart = copyParameterized(
                element, "AXStartTextMarkerForTextMarkerRange", selectedRange),
            let selEnd = copyParameterized(
                element, "AXEndTextMarkerForTextMarkerRange", selectedRange)
        else { return nil }

        func range(_ a: CFTypeRef, _ b: CFTypeRef) -> CFTypeRef? {
            let markers = [a, b] as CFArray
            return copyParameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", markers)
        }
        func text(_ markerRange: CFTypeRef) -> String? {
            copyParameterized(element, "AXStringForTextMarkerRange", markerRange) as? String
        }

        guard let beforeRange = range(fullStart, selStart),
            let afterRange = range(selEnd, fullEnd),
            let before = text(beforeRange), let after = text(afterRange)
        else { return nil }
        return (before, text(selectedRange) ?? "", after)
    }

    /// Last resort for canvas-ish UIs: concatenate descendant text under a char budget.
    private static func gatherSubtree(_ element: AXUIElement, budget: Int) -> String? {
        var collected = ""
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var visited = 0
        while !queue.isEmpty, collected.count < budget, visited < 400 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if depth > 0, let value = copyString(node, kAXValueAttribute), !value.isEmpty {
                collected += value + "\n"
            } else if depth > 0, let title = copyString(node, kAXTitleAttribute), !title.isEmpty {
                collected += title + "\n"
            }
            guard depth < 6 else { continue }
            if let children = copyValue(node, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children.prefix(40) { queue.append((child, depth + 1)) }
            }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(budget))
    }

    /// Geometry-derived identity, used only when the app exposes no AXIdentifier.
    private static func frameKey(_ element: AXUIElement) -> String {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let raw = copyValue(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            // swift-format-ignore: NeverForceUnwrap — type id checked above.
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        if let raw = copyValue(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            // swift-format-ignore: NeverForceUnwrap — type id checked above.
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        // Rounded to 10pt so a scroll or a one-pixel relayout doesn't look like a new field.
        func round10(_ value: CGFloat) -> Int { Int((value / 10).rounded()) * 10 }
        return "\(round10(origin.x)),\(round10(origin.y)),\(round10(size.width)),\(round10(size.height))"
    }

    // MARK: - Bounds and text utilities

    /// Keep the snapshot near the caret rather than truncating the tail of a long document.
    private static func bound(_ snapshot: FocusedTextSnapshot, maxChars: Int)
        -> FocusedTextSnapshot
    {
        guard snapshot.text.count > maxChars else { return snapshot }
        let selected = String(snapshot.selected.prefix(maxChars))
        let remaining = max(0, maxChars - selected.count)
        let beforeBudget = remaining / 2 + remaining % 2
        return FocusedTextSnapshot(
            app: snapshot.app, bundleId: snapshot.bundleId, pid: snapshot.pid,
            role: snapshot.role, subrole: snapshot.subrole, identifier: snapshot.identifier,
            frameKey: snapshot.frameKey,
            before: String(snapshot.before.suffix(beforeBudget)), selected: selected,
            after: String(snapshot.after.prefix(remaining / 2)), source: snapshot.source)
    }

    /// AX ranges are in UTF-16 units; Swift strings are not.
    static func splitUTF16(_ value: String, location: Int, length: Int) -> (String, String, String) {
        let units = Array(value.utf16)
        guard location >= 0, location <= units.count else { return (value, "", "") }
        let end = min(units.count, location + max(0, length))
        let before = String(decoding: units[0..<location], as: UTF16.self)
        let selected = String(decoding: units[location..<end], as: UTF16.self)
        let after = String(decoding: units[end...], as: UTF16.self)
        return (before, selected, after)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            if count > 1 { return count }
            searchStart = found.upperBound
        }
        return count
    }

    // MARK: - Raw AX accessors

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swift-format-ignore: NeverForceUnwrap — type id checked immediately above.
        return (value as! AXUIElement)
    }

    private static func copyParameterized(
        _ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }
}
