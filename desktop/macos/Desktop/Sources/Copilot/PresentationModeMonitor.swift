import AppKit
import Combine

/// Detects when the user is presenting (Keynote / PowerPoint in the foreground) so the
/// live copilot can go quiet while they speak and only surface answers when the audience
/// asks something. Complements stealth mode (which keeps the HUD off the shared screen).
@MainActor
final class PresentationModeMonitor: ObservableObject {
    static let shared = PresentationModeMonitor()

    @Published private(set) var isPresenting = false

    /// Bundle ids of native presentation apps. Google Slides / web decks aren't reliably
    /// distinguishable from normal browsing, so we stick to native apps for a confident signal.
    private static let presentationBundleIds: Set<String> = [
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint",
    ]

    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let presenting = Self.presentationBundleIds.contains(bundleId)
        if presenting != isPresenting {
            isPresenting = presenting
            log("PresentationModeMonitor: isPresenting=\(presenting) (front=\(bundleId))")
        }
    }

    /// During a presentation, only audience-driven suggestion types should surface as cards;
    /// the presenter's own narration must not trigger interruptions.
    func shouldDeliver(gateType: String) -> Bool {
        guard isPresenting else { return true }
        return gateType == "question" || gateType == "term_definition"
    }
}
