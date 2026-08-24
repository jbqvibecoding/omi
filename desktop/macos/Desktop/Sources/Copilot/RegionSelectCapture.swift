import AppKit

/// Drag out a region of the screen and capture just that.
///
/// The capture happens in here rather than being handed back as a rect, because the
/// conversion it needs is exactly where this feature usually breaks: AppKit hands you
/// **points** with the origin at the bottom-left of the primary screen, while
/// `CGDisplayCreateImage` hands back **physical pixels** with the origin at the top-left
/// of one display. Keeping both halves in one file means the flip and the backing-scale
/// multiply can't drift apart.
@MainActor
final class RegionSelectCapture {
    static let shared = RegionSelectCapture()

    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<Data?, Never>?
    /// Guards against resuming twice — Esc and mouse-up can both land.
    private var isFinished = false

    private init() {}

    /// Show the picker and return JPEG data for the chosen region, or nil if cancelled.
    func selectAndCapture(quality: CGFloat = 0.7) async -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            log("RegionSelectCapture: no screen recording permission")
            return nil
        }
        guard continuation == nil else {
            log("RegionSelectCapture: a selection is already in progress")
            return nil
        }
        let region = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            self.isFinished = false
            self.continuation = cont
            self.presentOverlays(quality: quality)
        }
        return region
    }

    // MARK: - Overlay windows

    private func presentOverlays(quality: CGFloat) {
        // One window per screen so the picker works wherever the pointer is.
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                defer: false, screen: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hasShadow = false
            // Without this the selection overlay itself lands in the user's recording,
            // which defeats the point of stealth mode.
            StealthWindowController.applyCurrentStealthPreference(to: window)

            let view = RegionSelectView(screen: screen)
            view.onComplete = { [weak self] rect, sourceScreen in
                self?.finish(rect: rect, screen: sourceScreen, quality: quality)
            }
            view.onCancel = { [weak self] in
                self?.finish(rect: nil, screen: nil, quality: quality)
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            // The view has to be first responder to receive Esc.
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func teardown() {
        NSCursor.pop()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func finish(rect: NSRect?, screen: NSScreen?, quality: CGFloat) {
        guard !isFinished else { return }
        isFinished = true
        teardown()

        var data: Data?
        if let rect, let screen, rect.width >= 4, rect.height >= 4 {
            data = Self.capture(globalRect: rect, on: screen, quality: quality)
        }
        let cont = continuation
        continuation = nil
        cont?.resume(returning: data)
    }

    // MARK: - The conversion that matters

    /// Capture `globalRect` (AppKit points, bottom-left origin, global space) from `screen`.
    static func capture(globalRect: NSRect, on screen: NSScreen, quality: CGFloat) -> Data? {
        guard
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
            let full = CGDisplayCreateImage(displayID)
        else {
            log("RegionSelectCapture: could not capture the display")
            return nil
        }

        let scale = screen.backingScaleFactor
        let frame = screen.frame
        // X: distance from this screen's left edge. Y: AppKit measures up from the screen's
        // bottom, CGImage measures down from its top — so the top of the selection is
        // `frame.maxY - rect.maxY` below the top of the screen.
        let localX = (globalRect.minX - frame.minX) * scale
        let localY = (frame.maxY - globalRect.maxY) * scale
        var pixelRect = CGRect(
            x: localX.rounded(.down), y: localY.rounded(.down),
            width: (globalRect.width * scale).rounded(.up),
            height: (globalRect.height * scale).rounded(.up))

        // A drag that ran off the edge of the screen would otherwise fail the crop.
        pixelRect = pixelRect.intersection(
            CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
            let cropped = full.cropping(to: pixelRect)
        else {
            log("RegionSelectCapture: crop rect fell outside the display")
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: cropped)
        guard
            let data = rep.representation(
                using: .jpeg, properties: [.compressionFactor: quality])
        else {
            log("RegionSelectCapture: JPEG encoding failed")
            return nil
        }
        log(
            "RegionSelectCapture: captured \(cropped.width)x\(cropped.height) px, "
                + "JPEG \(data.count / 1024) KB")
        return data
    }
}

/// The dimmed overlay the user drags on. Reports its rect in global AppKit coordinates.
private final class RegionSelectView: NSView {
    var onComplete: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private var anchor: NSPoint?
    private var current: NSPoint?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let selection = localSelection() else { return }
        // Punch the selection back out to full brightness so the user sees what they'll get.
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1
        border.stroke()
    }

    private func localSelection() -> NSRect? {
        guard let anchor, let current else { return nil }
        return NSRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection = localSelection() else {
            onCancel?()
            return
        }
        // View coordinates are screen-local; the capture works in the global space.
        let global = NSRect(
            x: selection.minX + screen.frame.minX, y: selection.minY + screen.frame.minY,
            width: selection.width, height: selection.height)
        onComplete?(global, screen)
    }

    override func keyDown(with event: NSEvent) {
        // 53 = Esc.
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
