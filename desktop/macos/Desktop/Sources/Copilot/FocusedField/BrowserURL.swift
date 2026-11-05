import AppKit

/// The URL of the page the user is actually looking at.
///
/// Ported from cetus (`src-tauri/src/ambient.rs`, MIT).
///
/// OCR and accessibility text can both tell you a page says "Sign in" — neither can tell
/// you whether that's your bank or a phishing page, and neither survives a redirect. The
/// address bar is the one piece of structured truth on screen, and the only way to read it
/// is to ask the browser over AppleScript.
///
/// Two costs shape everything here. Each call spawns `osascript` and blocks on a browser
/// that may be busy, so callers must only ask when something changed. And the first call
/// to each browser raises a macOS Automation consent prompt — a denial is permanent until
/// the user revisits System Settings, so a failure has to be silent and cheap, never an
/// error the user sees.
@MainActor
enum BrowserURL {
    /// How the browser exposes the front tab. Safari and the Chromium family disagree on
    /// the noun, and nothing else about the script differs.
    private enum Dialect {
        case safari
        case chromium

        func script(app: String) -> String {
            switch self {
            case .safari:
                return "tell application \"\(app)\" to get URL of current tab of front window"
            case .chromium:
                return "tell application \"\(app)\" to get URL of active tab of front window"
            }
        }
    }

    private struct Browser {
        let appName: String
        let dialect: Dialect
    }

    /// Deliberately a fixed list rather than a heuristic: asking a non-browser for its
    /// "front tab" still costs a consent prompt, which is a terrible thing to spend on a
    /// guess.
    private static let byBundleId: [String: Browser] = [
        "com.apple.Safari": Browser(appName: "Safari", dialect: .safari),
        "com.apple.SafariTechnologyPreview": Browser(
            appName: "Safari Technology Preview", dialect: .safari),
        "com.google.Chrome": Browser(appName: "Google Chrome", dialect: .chromium),
        "com.google.Chrome.beta": Browser(appName: "Google Chrome Beta", dialect: .chromium),
        "com.google.Chrome.canary": Browser(appName: "Google Chrome Canary", dialect: .chromium),
        "com.brave.Browser": Browser(appName: "Brave Browser", dialect: .chromium),
        "com.microsoft.edgemac": Browser(appName: "Microsoft Edge", dialect: .chromium),
        "company.thebrowser.Browser": Browser(appName: "Arc", dialect: .chromium),
        "company.thebrowser.dia": Browser(appName: "Dia", dialect: .chromium),
        "com.vivaldi.Vivaldi": Browser(appName: "Vivaldi", dialect: .chromium),
        "com.operasoftware.Opera": Browser(appName: "Opera", dialect: .chromium),
        "org.chromium.Chromium": Browser(appName: "Chromium", dialect: .chromium),
    ]

    /// Bundles that denied Automation, so a refusal costs one prompt and not one per call.
    /// Deliberately not persisted — the user can grant permission in System Settings at any
    /// time, and a relaunch is a fair moment to notice.
    private static var deniedBundles: Set<String> = []

    static func isBrowser(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return byBundleId[bundleId] != nil
    }

    /// The front tab's URL, or nil for anything that isn't a known browser, a browser with
    /// no window open, or a denied/slow Automation request.
    static func current(bundleId: String?) async -> String? {
        guard let bundleId, let browser = byBundleId[bundleId],
            !deniedBundles.contains(bundleId)
        else { return nil }

        let script = browser.dialect.script(app: browser.appName)
        let outcome = await Task.detached(priority: .utility) {
            run(script: script)
        }.value

        switch outcome {
        case .denied:
            deniedBundles.insert(bundleId)
            log("BrowserURL: automation denied for \(browser.appName); not asking again this run")
            return nil
        case .failed:
            return nil
        case .url(let url):
            return url
        }
    }

    // MARK: - osascript

    private enum Outcome {
        case url(String)
        /// The user said no (or hasn't been asked and the prompt was dismissed).
        case denied
        /// No window, a timeout, a browser mid-launch — all retryable, none worth reporting.
        case failed
    }

    /// Runs `osascript` with a hard wall-clock cap.
    ///
    /// `NSAppleScript` has no timeout, and a browser stuck on a page load will hold the
    /// call for as long as it likes. A separate process is the only version of this that
    /// can be killed.
    private nonisolated static func run(script: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failed
        }

        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: watchdog)

        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard !timedOut else { return .failed }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
            // -1743 is "Not authorized to send Apple events"; the text form appears when
            // osascript reports it as a plain error rather than an OSStatus.
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                return .denied
            }
            return .failed
        }

        let url = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url != "missing value", url.contains(":") else { return .failed }
        return .url(url)
    }
}
