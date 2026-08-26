import ApplicationServices
import Foundation

/// The text visible in an app's focused window, read over the Accessibility API.
///
/// Ported from cetus (`src-tauri/src/ambient.rs`, MIT).
///
/// This is the expensive half of ambient context and the reason the caller polls in tiers.
/// Every attribute read is a synchronous IPC round-trip into the target process, so the
/// cost is not "one call" but one call per node, and an app with a deep tree can hand you
/// thousands. Four independent caps bound it — nodes, depth, characters, and wall clock —
/// because each one alone has a shape of tree that defeats it: a flat list defeats the
/// depth cap, a deep chrome hierarchy defeats the node cap, and a single app that answers
/// slowly defeats both.
///
/// Deliberately `nonisolated`: this runs off the main actor. AX elements are usable from
/// any thread, and a few hundred blocking round-trips on the main thread would stutter the
/// UI even inside the wall-clock budget.
enum AXVisibleText {
    private static let maxNodes = 600
    private static let maxDepth = 12
    private static let maxChars = 8000
    private static let maxChildrenPerNode = 60
    /// Hard stop regardless of how many nodes were visited. An app that answers slowly
    /// costs us this much and no more.
    private static let wallClockBudget: TimeInterval = 0.25
    private static let messagingTimeout: Float = 0.15

    /// Roles carrying no text of their own — skipping their *values* (not their children)
    /// keeps chrome out of the result.
    private static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXProgressIndicator", "AXImage",
    ]

    struct Result {
        let windowTitle: String
        let text: String
        /// True when a cap stopped the walk early — the text is a prefix, not the page.
        let truncated: Bool
    }

    /// The focused window's title and nothing else — two AX reads.
    ///
    /// This is the cheap probe the ambient loop runs every couple of seconds. It's separate
    /// from ``capture(pid:)`` precisely so the common case never pays for the walk: a title
    /// change is what tells you a tab switched or a document opened.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted(), pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        return copyString(window, kAXTitleAttribute)
    }

    static func capture(pid: pid_t) -> Result? {
        guard AXIsProcessTrusted(), pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)

        let title = copyString(window, kAXTitleAttribute) ?? ""
        let deadline = Date().addingTimeInterval(wallClockBudget)

        var collected: [String] = []
        var chars = 0
        var visited = 0
        var truncated = false
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]

        while !queue.isEmpty {
            guard visited < maxNodes, chars < maxChars, Date() < deadline else {
                truncated = true
                break
            }
            let (node, depth) = queue.removeFirst()
            visited += 1

            let role = copyString(node, kAXRoleAttribute) ?? ""
            if !skippedRoles.contains(role), depth > 0, let piece = textOf(node) {
                collected.append(piece)
                chars += piece.count + 1
            }

            guard depth < maxDepth else { continue }
            if let children = copyValue(node, kAXChildrenAttribute) as? [AXUIElement] {
                if children.count > maxChildrenPerNode { truncated = true }
                for child in children.prefix(maxChildrenPerNode) {
                    queue.append((child, depth + 1))
                }
            }
        }

        // Consecutive duplicates are constant in AX trees — a label and its container both
        // report the same string — and they're pure noise in a prompt.
        var deduped: [String] = []
        for piece in collected where deduped.last != piece {
            deduped.append(piece)
        }

        let text = String(deduped.joined(separator: "\n").prefix(maxChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !title.isEmpty else { return nil }
        return Result(windowTitle: title, text: text, truncated: truncated)
    }

    /// The one useful string on a node: its value, else its title, else its description.
    /// A secure field never contributes, whatever else it claims.
    private static func textOf(_ element: AXUIElement) -> String? {
        if copyString(element, kAXSubroleAttribute) == "AXSecureTextField" { return nil }
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let value = copyString(element, attribute) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // One-character values are separators, bullets and icon glyphs.
            if trimmed.count > 1 { return trimmed }
        }
        return nil
    }

    // MARK: - Raw AX accessors

    private static func copyValue(_ element: AXUIElement, _ attribute: String)
        -> CFTypeRef?
    {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String)
        -> String?
    {
        copyValue(element, attribute) as? String
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String)
        -> AXUIElement?
    {
        guard let value = copyValue(element, attribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swift-format-ignore: NeverForceUnwrap — type id checked immediately above.
        return (value as! AXUIElement)
    }
}
