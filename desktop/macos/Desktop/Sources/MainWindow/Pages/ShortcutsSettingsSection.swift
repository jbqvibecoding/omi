import SwiftUI

struct ShortcutsSettingsSection: View {
  @ObservedObject private var settings = ShortcutSettings.shared
  @Binding var highlightedSettingId: String?
  @State private var recordingTarget: ShortcutTarget?
  @State private var captureError: String?
  @State private var localShortcutCaptureMonitor: Any?
  /// Bumped when a hotkey registration result changes. `GlobalShortcutManager` is a plain
  /// class (it is driven from non-main contexts), so it cannot publish directly; reading
  /// this during body evaluation is what makes the warning rows refresh.
  @State private var registrationFailureTick: UInt8 = 0

  init(highlightedSettingId: Binding<String?> = .constant(nil)) {
    self._highlightedSettingId = highlightedSettingId
  }

  private enum ShortcutTarget {
    case askOmi
    case copilot
    case pushToTalk
  }

  var body: some View {
    VStack(spacing: 20) {
      askOmiKeyCard
      copilotKeyCard
      pttKeyCard
      doubleTapCard
      pttSoundsCard
      muteAudioCard
      referenceCard
    }
    // Redrawn when a hotkey fails to register, which happens asynchronously at launch
    // and whenever a shortcut changes.
    .onReceive(
      NotificationCenter.default.publisher(
        for: GlobalShortcutManager.registrationFailuresChanged)
    ) { _ in
      registrationFailureTick &+= 1
    }
    .onDisappear {
      stopShortcutCapture()
    }
  }

  private var askOmiKeyCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Ask omi Shortcut")
          .scaledFont(size: 16, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        Text("Global shortcut to open Ask omi from anywhere.")
          .scaledFont(size: 13)
          .foregroundColor(OmiColors.textSecondary)
      }

      HStack(spacing: 12) {
        ForEach(ShortcutSettings.askOmiPresets, id: \.self) { shortcut in
          askOmiKeyButton(shortcut)
        }
        customShortcutButton(
          for: .askOmi, isSelected: settings.askOmiEnabled && settings.askOmiUsesCustomShortcut)
        disableShortcutButton(isDisabled: !settings.askOmiEnabled) {
          stopShortcutCapture()
          settings.askOmiEnabled = false
        }
        Spacer()
      }

      if settings.askOmiEnabled
        && (recordingTarget == .askOmi || settings.askOmiUsesCustomShortcut
          || (captureError != nil && recordingTarget == .askOmi))
      {
        shortcutRecorderCard(
          title: recordingTarget == .askOmi
            ? "Press your custom Ask omi shortcut now" : "Custom Ask omi shortcut",
          shortcut: settings.askOmiShortcut,
          isRecording: recordingTarget == .askOmi,
          action: { startShortcutCapture(.askOmi) },
          helperText: "Use at least one non-modifier key."
        )
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
    .modifier(
      SettingHighlightModifier(
        settingId: "floatingbar.shortcut", highlightedSettingId: $highlightedSettingId))
  }

  private func askOmiKeyButton(_ shortcut: ShortcutSettings.KeyboardShortcut) -> some View {
    let isSelected =
      settings.askOmiEnabled && settings.askOmiShortcut == shortcut
      && !settings.askOmiUsesCustomShortcut
    return Button {
      stopShortcutCapture()
      settings.askOmiEnabled = true
      settings.askOmiShortcut = shortcut
    } label: {
      shortcutSelectionLabel(tokens: shortcut.displayTokens, isSelected: isSelected)
    }
    .buttonStyle(.plain)
  }

  private var copilotKeyCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Copilot Snap")
          .scaledFont(size: 16, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        Text("Snapshot your screen and get an instant AI answer — no question needed.")
          .scaledFont(size: 13)
          .foregroundColor(OmiColors.textSecondary)
      }

      HStack(spacing: 12) {
        ForEach(ShortcutSettings.copilotPresets, id: \.self) { shortcut in
          copilotKeyButton(shortcut)
        }
        customShortcutButton(
          for: .copilot, isSelected: settings.copilotEnabled && settings.copilotUsesCustomShortcut)
        disableShortcutButton(isDisabled: !settings.copilotEnabled) {
          stopShortcutCapture()
          settings.copilotEnabled = false
        }
        Spacer()
      }

      if settings.copilotEnabled
        && (recordingTarget == .copilot || settings.copilotUsesCustomShortcut
          || (captureError != nil && recordingTarget == .copilot))
      {
        shortcutRecorderCard(
          title: recordingTarget == .copilot
            ? "Press your custom Copilot Snap shortcut now" : "Custom Copilot Snap shortcut",
          shortcut: settings.copilotShortcut,
          isRecording: recordingTarget == .copilot,
          action: { startShortcutCapture(.copilot) },
          helperText: "Use at least one non-modifier key."
        )
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
    .modifier(
      SettingHighlightModifier(
        settingId: "floatingbar.copilot", highlightedSettingId: $highlightedSettingId))
  }

  private func copilotKeyButton(_ shortcut: ShortcutSettings.KeyboardShortcut) -> some View {
    let isSelected =
      settings.copilotEnabled && settings.copilotShortcut == shortcut
      && !settings.copilotUsesCustomShortcut
    return Button {
      stopShortcutCapture()
      settings.copilotEnabled = true
      settings.copilotShortcut = shortcut
    } label: {
      shortcutSelectionLabel(tokens: shortcut.displayTokens, isSelected: isSelected)
    }
    .buttonStyle(.plain)
  }

  private var pttKeyCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Push to Talk")
          .scaledFont(size: 16, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        Text("Hold the key to speak, release to send your question to AI.")
          .scaledFont(size: 13)
          .foregroundColor(OmiColors.textSecondary)
      }

      HStack(spacing: 12) {
        ForEach(ShortcutSettings.pttPresets, id: \.self) { shortcut in
          pttKeyButton(shortcut)
        }
        customShortcutButton(
          for: .pushToTalk, isSelected: settings.pttEnabled && settings.pttUsesCustomShortcut)
        disableShortcutButton(isDisabled: !settings.pttEnabled) {
          stopShortcutCapture()
          settings.pttEnabled = false
        }
        Spacer()
      }

      if settings.pttEnabled
        && (recordingTarget == .pushToTalk || settings.pttUsesCustomShortcut
          || (captureError != nil && recordingTarget == .pushToTalk))
      {
        shortcutRecorderCard(
          title: recordingTarget == .pushToTalk
            ? "Press your custom push-to-talk shortcut now" : "Custom push-to-talk shortcut",
          shortcut: settings.pttShortcut,
          isRecording: recordingTarget == .pushToTalk,
          action: { startShortcutCapture(.pushToTalk) },
          helperText: "One key or a key combination both work."
        )
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
    .modifier(
      SettingHighlightModifier(
        settingId: "floatingbar.ptt", highlightedSettingId: $highlightedSettingId))
  }

  private func pttKeyButton(_ shortcut: ShortcutSettings.KeyboardShortcut) -> some View {
    let isSelected =
      settings.pttEnabled && settings.pttShortcut == shortcut && !settings.pttUsesCustomShortcut
    return Button {
      stopShortcutCapture()
      settings.pttEnabled = true
      settings.pttShortcut = shortcut
    } label: {
      shortcutSelectionLabel(tokens: shortcut.displayTokens, isSelected: isSelected)
    }
    .buttonStyle(.plain)
  }

  private var doubleTapCard: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Double-tap for Locked Mode")
          .scaledFont(size: 16, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        Text("Double-tap the push-to-talk key to keep listening hands-free. Tap again to send.")
          .scaledFont(size: 13)
          .foregroundColor(OmiColors.textSecondary)
      }
      Spacer()
      Toggle("", isOn: $settings.doubleTapForLock)
        .toggleStyle(.switch)
        .tint(OmiColors.purplePrimary)
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
    .opacity(settings.pttEnabled ? 1 : 0.55)
    .disabled(!settings.pttEnabled)
    .modifier(
      SettingHighlightModifier(
        settingId: "floatingbar.doubletap", highlightedSettingId: $highlightedSettingId))
  }

  private var pttSoundsCard: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Push-to-Talk Sounds")
          .scaledFont(size: 16, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        Text("Play audio feedback when starting and ending voice input.")
          .scaledFont(size: 13)
          .foregroundColor(OmiColors.textSecondary)
      }
      Spacer()
      Toggle("", isOn: $settings.pttSoundsEnabled)
        .toggleStyle(.switch)
        .tint(OmiColors.purplePrimary)
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
    .opacity(settings.pttEnabled ? 1 : 0.55)
    .disabled(!settings.pttEnabled)
    .modifier(
      SettingHighlightModifier(
        settingId: "floatingbar.pttsounds", highlightedSettingId: $highlightedSettingId))
  }

  private var muteAudioCard: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Mute Audio While Talking")
          .scaledFont(size: 16, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        Text("Silence music and other playback while holding push-to-talk, then restore it on release.")
          .scaledFont(size: 13)
          .foregroundColor(OmiColors.textSecondary)
      }
      Spacer()
      Toggle("", isOn: $settings.pttMuteSystemAudio)
        .toggleStyle(.switch)
        .tint(OmiColors.purplePrimary)
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
    .opacity(settings.pttEnabled ? 1 : 0.55)
    .disabled(!settings.pttEnabled)
    .modifier(
      SettingHighlightModifier(
        settingId: "floatingbar.muteaudio", highlightedSettingId: $highlightedSettingId))
  }

  /// Every shortcut in one place, plus anything wrong with the set as a whole.
  ///
  /// Driven off `settings.allBindings` rather than a hand-written list: this view was
  /// written once and then silently went stale, because nothing fails when a list of
  /// labels forgets a shortcut that was added later.
  private var referenceCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keyboard Shortcuts")
        .scaledFont(size: 16, weight: .semibold)
        .foregroundColor(OmiColors.textPrimary)

      ForEach(settings.allBindings) { binding in
        shortcutRow(
          label: binding.label,
          keys: binding.enabled
            ? binding.shortcut.displayLabel + (binding.shortcut.modifierOnly ? " hold" : "")
            : "Disabled")
      }
      shortcutRow(label: "Toggle floating bar", keys: "\u{2318}\\")
      if settings.pttEnabled && settings.doubleTapForLock {
        shortcutRow(
          label: "Locked listening", keys: settings.pttShortcut.displayLabel + " \u{00D7}2")
      }

      problemRows
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundTertiary.opacity(0.5))
    )
  }

  /// Two things that otherwise fail in silence: two shortcuts set to the same keys, where
  /// macOS gives the combination to whichever registered first; and a combination another
  /// app already holds, which Carbon reports as a return code and nothing more.
  @ViewBuilder
  private var problemRows: some View {
    let clashes = settings.conflicts()
    _ = registrationFailureTick  // read so this block re-evaluates when registration changes
    let blocked = settings.allBindings.filter {
      $0.enabled && GlobalShortcutManager.shared.registrationFailures.contains($0.id)
    }
    if !clashes.isEmpty || !blocked.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Divider().padding(.vertical, 2)
        ForEach(clashes) { clash in
          problemRow(
            icon: clash.isHardCollision ? "exclamationmark.triangle.fill" : "info.circle",
            text: clash.message,
            isError: clash.isHardCollision)
        }
        ForEach(blocked) { binding in
          problemRow(
            icon: "exclamationmark.triangle.fill",
            text:
              "\(binding.label) (\(binding.shortcut.displayLabel)) could not be registered — "
              + "another app is probably using it.",
            isError: true)
        }
      }
    }
  }

  private func problemRow(icon: String, text: String, isError: Bool) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: icon)
        .scaledFont(size: 11)
        .foregroundColor(isError ? OmiColors.error : OmiColors.textTertiary)
        .padding(.top, 1)
      Text(text)
        .scaledFont(size: 11)
        .foregroundColor(isError ? OmiColors.error : OmiColors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private func shortcutRow(label: String, keys: String) -> some View {
    HStack {
      Text(label)
        .scaledFont(size: 14)
        .foregroundColor(OmiColors.textSecondary)
      Spacer()
      Text(keys)
        .scaledMonospacedFont(size: 14, weight: .medium)
        .foregroundColor(OmiColors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(OmiColors.backgroundTertiary.opacity(0.8))
        .cornerRadius(6)
    }
  }

  private func customShortcutButton(for target: ShortcutTarget, isSelected: Bool) -> some View {
    Button {
      switch target {
      case .askOmi:
        settings.askOmiEnabled = true
      case .copilot:
        settings.copilotEnabled = true
      case .pushToTalk:
        settings.pttEnabled = true
      }
      startShortcutCapture(target)
    } label: {
      Text("Custom")
        .scaledFont(size: 13, weight: .medium)
        .foregroundColor(OmiColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(
              (isSelected || recordingTarget == target)
                ? OmiColors.purplePrimary.opacity(0.3)
                : OmiColors.backgroundTertiary.opacity(0.5))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(
              isSelected || recordingTarget == target ? OmiColors.purplePrimary : Color.clear,
              lineWidth: 1.5)
        )
    }
    .buttonStyle(.plain)
  }

  private func disableShortcutButton(isDisabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text("Disable")
        .scaledFont(size: 13, weight: .medium)
        .foregroundColor(OmiColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(
              isDisabled
                ? OmiColors.purplePrimary.opacity(0.3)
                : OmiColors.backgroundTertiary.opacity(0.5))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(isDisabled ? OmiColors.purplePrimary : Color.clear, lineWidth: 1.5)
        )
    }
    .buttonStyle(.plain)
  }

  private func shortcutSelectionLabel(tokens: [String], isSelected: Bool) -> some View {
    HStack(spacing: 6) {
      ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
        Text(token)
          .scaledFont(size: 13, weight: .medium)
      }
    }
    .foregroundColor(OmiColors.textPrimary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(
          isSelected
            ? OmiColors.purplePrimary.opacity(0.3)
            : OmiColors.backgroundTertiary.opacity(0.5))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(isSelected ? OmiColors.purplePrimary : Color.clear, lineWidth: 1.5)
    )
  }

  private func shortcutRecorderCard(
    title: String,
    shortcut: ShortcutSettings.KeyboardShortcut,
    isRecording: Bool,
    action: @escaping () -> Void,
    helperText: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .scaledFont(size: 13, weight: .semibold)
        .foregroundColor(OmiColors.textPrimary)

      HStack(spacing: 10) {
        HStack(spacing: 6) {
          ForEach(Array(shortcut.displayTokens.enumerated()), id: \.offset) { _, token in
            Text(token)
              .scaledFont(size: 13, weight: .semibold)
              .foregroundColor(OmiColors.textPrimary)
              .padding(.horizontal, token.count > 2 ? 10 : 8)
              .padding(.vertical, 7)
              .background(
                RoundedRectangle(cornerRadius: 8)
                  .fill(OmiColors.backgroundPrimary)
              )
          }
        }

        Spacer()

        Button(action: action) {
          Text(isRecording ? "Listening..." : "Save")
            .scaledFont(size: 12, weight: .semibold)
            .foregroundColor(OmiColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.backgroundPrimary)
            )
        }
        .buttonStyle(.plain)
      }

      Text(helperText)
        .scaledFont(size: 12)
        .foregroundColor(OmiColors.textSecondary)

      if let captureError, isRecording {
        Text(captureError)
          .scaledFont(size: 12, weight: .medium)
          .foregroundColor(.red.opacity(0.9))
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(OmiColors.backgroundSecondary.opacity(0.85))
    )
  }

  private func startShortcutCapture(_ target: ShortcutTarget) {
    stopShortcutCapture()
    recordingTarget = target
    captureError = nil

    localShortcutCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .flagsChanged, .keyDown,
    ]) { event in
      handleShortcutCapture(event) ? nil : event
    }
  }

  private func stopShortcutCapture() {
    if let monitor = localShortcutCaptureMonitor {
      NSEvent.removeMonitor(monitor)
      localShortcutCaptureMonitor = nil
    }
    recordingTarget = nil
    captureError = nil
  }

  private func handleShortcutCapture(_ event: NSEvent) -> Bool {
    guard let target = recordingTarget else { return false }

    switch target {
    case .askOmi:
      if event.type == .flagsChanged {
        captureError = "Ask omi needs a non-modifier key."
        return true
      }
      guard
        let shortcut = ShortcutSettings.KeyboardShortcut.fromRecordingEvent(
          event, allowModifierOnly: false)
      else {
        return false
      }
      settings.askOmiEnabled = true
      settings.askOmiShortcut = shortcut
    case .copilot:
      if event.type == .flagsChanged {
        captureError = "Copilot Snap needs a non-modifier key."
        return true
      }
      guard
        let shortcut = ShortcutSettings.KeyboardShortcut.fromRecordingEvent(
          event, allowModifierOnly: false)
      else {
        return false
      }
      settings.copilotEnabled = true
      settings.copilotShortcut = shortcut
    case .pushToTalk:
      guard
        let shortcut = ShortcutSettings.KeyboardShortcut.fromRecordingEvent(
          event, allowModifierOnly: true)
      else {
        return false
      }
      settings.pttEnabled = true
      settings.pttShortcut = shortcut
    }

    stopShortcutCapture()
    return true
  }
}
