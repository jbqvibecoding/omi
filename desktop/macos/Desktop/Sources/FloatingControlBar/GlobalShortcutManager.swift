import Carbon.HIToolbox.Events
import Cocoa

// MARK: - Global Shortcut Manager

/// Manages global keyboard shortcuts using Carbon APIs for the floating control bar.
class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    static let askAINotification = Notification.Name("com.omi.desktop.askAI")

    private var hotKeyRefs: [HotKeyID: EventHotKeyRef] = [:]
    private var isRegistrationSuspended = false

    private enum HotKeyID: UInt32 {
        case askOmi = 2
        case copilot = 3
        case clickThrough = 4
        case suggestNow = 5
    }

    private var shortcutObserver: NSObjectProtocol?
    private var copilotShortcutObserver: NSObjectProtocol?
    private var clickThroughShortcutObserver: NSObjectProtocol?
    private var suggestNowShortcutObserver: NSObjectProtocol?

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                return GlobalShortcutManager.shared.handleHotKeyEvent(event!)
            },
            1, &eventType, nil, nil
        )

        // Re-register Ask Omi shortcut when user changes it in settings
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.askOmiShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerAskOmi()
        }

        // Re-register Copilot Snap shortcut when user changes it in settings
        copilotShortcutObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.copilotShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerCopilot()
        }

        // Re-register the suggest-now shortcut when user changes it in settings
        suggestNowShortcutObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.suggestNowShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerSuggestNow()
        }

        // Re-register click-through shortcut when user changes it in settings
        clickThroughShortcutObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.clickThroughShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerClickThrough()
        }
    }

    func registerShortcuts() {
        unregisterShortcuts()
        guard !isRegistrationSuspended else { return }
        // Register Ask Omi shortcut from user settings
        registerAskOmi()
        // Register Copilot Snap shortcut from user settings
        registerCopilot()
        // Register click-through toggle shortcut from user settings
        registerClickThrough()
        // Register the "ask for a suggestion now" shortcut from user settings
        registerSuggestNow()
    }

    func setRegistrationSuspended(_ suspended: Bool) {
        isRegistrationSuspended = suspended
        if suspended {
            unregisterShortcuts()
        } else {
            registerShortcuts()
        }
    }

    private func registerAskOmi() {
        guard !isRegistrationSuspended else { return }
        // Unregister previous Ask Omi hotkey if any
        if let ref = hotKeyRefs.removeValue(forKey: .askOmi) {
            UnregisterEventHotKey(ref)
        }
        let (askOmiEnabled, askOmiShortcut) = MainActor.assumeIsolated {
            (ShortcutSettings.shared.askOmiEnabled, ShortcutSettings.shared.askOmiShortcut)
        }
        guard askOmiEnabled else {
            NSLog("GlobalShortcutManager: Ask Omi shortcut is disabled")
            return
        }
        guard askOmiShortcut.supportsGlobalHotKey, let keyCode = askOmiShortcut.keyCode else {
            NSLog("GlobalShortcutManager: Ask Omi shortcut is not a registerable hotkey")
            return
        }
        registerHotKey(keyCode: Int(keyCode), modifiers: askOmiShortcut.carbonModifiers, id: .askOmi)
        NSLog("GlobalShortcutManager: Registered Ask Omi shortcut: \(askOmiShortcut.displayLabel)")
    }

    private func registerCopilot() {
        guard !isRegistrationSuspended else { return }
        // Unregister previous Copilot hotkey if any
        if let ref = hotKeyRefs.removeValue(forKey: .copilot) {
            UnregisterEventHotKey(ref)
        }
        let (copilotEnabled, copilotShortcut) = MainActor.assumeIsolated {
            (ShortcutSettings.shared.copilotEnabled, ShortcutSettings.shared.copilotShortcut)
        }
        guard copilotEnabled else {
            NSLog("GlobalShortcutManager: Copilot Snap shortcut is disabled")
            return
        }
        guard copilotShortcut.supportsGlobalHotKey, let keyCode = copilotShortcut.keyCode else {
            NSLog("GlobalShortcutManager: Copilot Snap shortcut is not a registerable hotkey")
            return
        }
        registerHotKey(keyCode: Int(keyCode), modifiers: copilotShortcut.carbonModifiers, id: .copilot)
        NSLog("GlobalShortcutManager: Registered Copilot Snap shortcut: \(copilotShortcut.displayLabel)")
    }

    private func registerSuggestNow() {
        guard !isRegistrationSuspended else { return }
        if let ref = hotKeyRefs.removeValue(forKey: .suggestNow) {
            UnregisterEventHotKey(ref)
        }
        let (enabled, shortcut) = MainActor.assumeIsolated {
            (ShortcutSettings.shared.suggestNowEnabled, ShortcutSettings.shared.suggestNowShortcut)
        }
        guard enabled else {
            NSLog("GlobalShortcutManager: Suggest-now shortcut is disabled")
            return
        }
        guard shortcut.supportsGlobalHotKey, let keyCode = shortcut.keyCode else {
            NSLog("GlobalShortcutManager: Suggest-now shortcut is not a registerable hotkey")
            return
        }
        registerHotKey(keyCode: Int(keyCode), modifiers: shortcut.carbonModifiers, id: .suggestNow)
        NSLog("GlobalShortcutManager: Registered suggest-now shortcut: \(shortcut.displayLabel)")
    }

    private func registerClickThrough() {
        guard !isRegistrationSuspended else { return }
        if let ref = hotKeyRefs.removeValue(forKey: .clickThrough) {
            UnregisterEventHotKey(ref)
        }
        let (enabled, shortcut) = MainActor.assumeIsolated {
            (ShortcutSettings.shared.clickThroughEnabled, ShortcutSettings.shared.clickThroughShortcut)
        }
        guard enabled else {
            NSLog("GlobalShortcutManager: Click-through shortcut is disabled")
            return
        }
        guard shortcut.supportsGlobalHotKey, let keyCode = shortcut.keyCode else {
            NSLog("GlobalShortcutManager: Click-through shortcut is not a registerable hotkey")
            return
        }
        registerHotKey(keyCode: Int(keyCode), modifiers: shortcut.carbonModifiers, id: .clickThrough)
        NSLog("GlobalShortcutManager: Registered click-through shortcut: \(shortcut.displayLabel)")
    }

    private func registerHotKey(keyCode: Int, modifiers: Int, id: HotKeyID) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: FourCharCode(0x4F4D4921), id: id.rawValue) // "OMI!"

        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs[id] = ref
        } else {
            NSLog("GlobalShortcutManager: Failed to register hotkey (keycode \(keyCode)), error: \(status)")
        }
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            OSType(kEventParamDirectObject),
            OSType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, let id = HotKeyID(rawValue: hotKeyID.id) else {
            return status
        }

        switch id {
        case .askOmi:
            NSLog("GlobalShortcutManager: Ask Omi shortcut detected")
            DispatchQueue.main.async {
                FloatingControlBarManager.shared.toggleAIInput()
            }
        case .copilot:
            NSLog("GlobalShortcutManager: Copilot Snap shortcut detected")
            DispatchQueue.main.async {
                Task { @MainActor in
                    await CopilotOrchestrator.shared.triggerSnap(source: "hotkey")
                }
            }
        case .clickThrough:
            NSLog("GlobalShortcutManager: Click-through shortcut detected")
            DispatchQueue.main.async {
                FloatingControlBarManager.shared.toggleClickThrough()
            }
        case .suggestNow:
            NSLog("GlobalShortcutManager: Suggest-now shortcut detected")
            DispatchQueue.main.async {
                Task { @MainActor in
                    await LiveSuggestionsMonitor.shared.suggestNow()
                }
            }
        }

        return noErr
    }

    func unregisterShortcuts() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}
