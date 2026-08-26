import AppKit
import SwiftUI

/// State of one Quick Reply session, shared between the orchestrator and the panel.
@MainActor
final class QuickReplyModel: ObservableObject {
    /// The draft, editable in place. This is the text that gets inserted.
    @Published var draft: String = ""
    /// What the reply claims to have answered, one line each.
    ///
    /// Shown because it's the only visible check on the failure this feature exists to
    /// avoid: three questions in the original, one "sounds good" in the reply. If the list
    /// is shorter than what was asked, the user can see that before they send it.
    @Published var addressed: [String] = []
    @Published var isLoading: Bool = true
    @Published var errorText: String?
    /// Name of the app the reply goes back into, so the footer can say where ⏎ sends it.
    @Published var targetAppName: String = ""
}

/// A small editable panel holding a drafted reply.
///
/// Deliberately its own window rather than the floating bar: the bar is a notification
/// surface with its own queue and dismissal rules, and this needs to hold keyboard focus
/// and stay put until the user decides.
@MainActor
final class QuickReplyPanel {
    static let shared = QuickReplyPanel()

    private var window: QuickReplyWindow?
    private(set) var model = QuickReplyModel()
    private var onInsert: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    private init() {}

    var isPresented: Bool { window != nil }

    /// Show the panel immediately in its loading state, so the keypress has a response
    /// before the model does.
    func present(
        targetAppName: String,
        onInsert: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        let model = QuickReplyModel()
        model.targetAppName = targetAppName
        self.model = model
        self.onInsert = onInsert
        self.onCancel = onCancel

        let width: CGFloat = 560
        let height: CGFloat = 300
        let screen = NSScreen.main ?? NSScreen.screens.first
        let origin = screen.map { screen -> NSPoint in
            NSPoint(
                x: screen.frame.midX - width / 2,
                y: screen.frame.midY - height / 2)
        } ?? NSPoint(x: 200, y: 200)

        let window = QuickReplyWindow(
            contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A drafted reply is exactly the kind of thing that must not land in a screen share.
        StealthWindowController.applyCurrentStealthPreference(to: window)

        let view = QuickReplyView(
            model: model,
            onInsert: { [weak self] text in self?.finish(insert: text) },
            onCancel: { [weak self] in self?.finish(insert: nil) }
        )
        window.contentView = NSHostingView(rootView: view)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
        onInsert = nil
        onCancel = nil
    }

    private func finish(insert text: String?) {
        let insertHandler = onInsert
        let cancelHandler = onCancel
        dismiss()
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertHandler?(text)
        } else {
            cancelHandler?()
        }
    }
}

/// Borderless panels don't take key focus by default, and this one is a text editor.
private final class QuickReplyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private struct QuickReplyView: View {
    @ObservedObject var model: QuickReplyModel
    let onInsert: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorText = model.errorText {
                Text(errorText)
                    .scaledFont(size: 12)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DraftEditor(
                    text: $model.draft,
                    isEditable: !model.isLoading,
                    onSubmit: { onInsert(model.draft) },
                    onCancel: onCancel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !model.addressed.isEmpty {
                addressedList
            }

            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        // The editor handles Esc itself while it has focus; this covers the error state,
        // where there is no editor to be first responder.
        .onExitCommand { onCancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
            Text("Quick Reply")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(.white)
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Spacer()
            if !model.targetAppName.isEmpty {
                Text(model.targetAppName)
                    .scaledFont(size: 11)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private var addressedList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.addressed.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 3)
                    Text(point)
                        .scaledFont(size: 11)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⏎ insert · ⇧⏎ new line · esc discard")
                .scaledFont(size: 10)
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            Button("Discard") { onCancel() }
                .buttonStyle(.plain)
                .scaledFont(size: 11)
                .foregroundColor(.white.opacity(0.6))
            Button("Insert") { onInsert(model.draft) }
                .buttonStyle(.plain)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
                .disabled(model.isLoading)
        }
    }
}

// MARK: - Editor

/// An `NSTextView` rather than SwiftUI's `TextEditor`, because the whole interaction turns
/// on intercepting Return before the editor inserts a newline — `doCommandBy` is the
/// reliable way to do that, and it also gives us Esc for free.
private struct DraftEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 8, height: 8)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            // A freshly arrived draft should be ready to edit from the end, not selected.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftEditor

        init(parent: DraftEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⇧⏎ — the chat-input convention, and the escape hatch that makes ⏎-to-send
                // safe to offer on a multi-line editor.
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
