import AppKit
import DuhcordCore
import DuhcordUpdateKit

/// Schedules update checks and drives the banner: check → "available" → download → install → relaunch.
/// Nothing is installed without the user clicking.
@MainActor
final class UpdateController {
    private let checker = UpdateChecker(currentVersion: Updates.currentVersion)
    private var timer: Timer?
    /// Failures and "you're up to date" are only shown for checks the user asked for, never for background ones.
    private var userInitiated = false

    /// Where the banner goes; set once the main window exists.
    weak var window: MainWindowController? {
        didSet { refreshBanner() }
    }

    init() {
        checker.onChange = { [weak self] state in self?.stateChanged(state) }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        schedule()
    }

    /// Duhcord → Check for Updates…
    func checkNow() {
        guard checker.isEnabled else {
            alert("Updates aren't set up", "This build of Duhcord has no update key, so it can't check for updates.")
            return
        }
        userInitiated = true
        checker.check()
    }

    // MARK: - Scheduling

    @objc private func settingsChanged() { schedule() }

    /// One check shortly after launch, then once a day. Off entirely when the setting is off.
    private func schedule() {
        guard checker.isEnabled, Settings.checkForUpdates else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let first = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkInBackground() }
        }
        RunLoop.main.add(first, forMode: .common)
        let daily = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInBackground() }
        }
        daily.tolerance = 60 * 60
        RunLoop.main.add(daily, forMode: .common)
        timer = daily
    }

    private func checkInBackground() {
        guard Settings.checkForUpdates else { return }
        userInitiated = false
        checker.check()
    }

    // MARK: - State

    private func stateChanged(_ state: UpdateChecker.State) {
        switch state {
        case .upToDate where userInitiated:
            alert("You're up to date", "Duhcord \(checker.currentVersion) is the latest version.")
            userInitiated = false
        case .failed(let message) where userInitiated:
            alert("Couldn't update", message)
            userInitiated = false
        case .ready(let manifest, let archive):
            install(manifest, archive: archive)
        default:
            break
        }
        refreshBanner()
    }

    private func refreshBanner() {
        guard let window else { return }
        // Only a real app bundle can be in the wrong place; `swift run` builds have no bundle.
        if Bundle.main.bundleIdentifier != nil, !Updates.isInApplicationsFolder {
            window.showBanner("Duhcord can't update itself from here. Move it to your Applications folder.",
                              tone: .warning, action: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            return
        }
        if case .available(let manifest) = checker.state {
            window.setUpdateAvailable { [weak self] in self?.confirm(manifest) }
        } else {
            window.setUpdateAvailable(nil)
        }
        switch checker.state {
        case .available:
            window.showBanner(nil)
        case .downloading(let manifest):
            window.showBanner("Downloading Duhcord \(manifest.version)…")
        case .ready(let manifest, _):
            window.showBanner("Installing Duhcord \(manifest.version)…")
        default:
            window.showBanner(nil)
        }
    }

    private func confirm(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Update to Duhcord \(manifest.version)?"
        let notes = manifest.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alert.informativeText = (notes.isEmpty ? "" : notes + "\n\n") + "Duhcord will restart once the update is installed."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.userInitiated = true
            self.checker.download()
        }
        if let sheetWindow = window?.window { alert.beginSheetModal(for: sheetWindow, completionHandler: proceed) } else { proceed(alert.runModal()) }
    }

    private func install(_ manifest: UpdateManifest, archive: URL) {
        Updates.install(archive: archive, manifest: checker.manifestData, signature: checker.signatureData) { [weak self] error in
            guard let self else { return }
            if let error {
                self.checker.reset()
                self.alert("Couldn't install the update", error)
                self.refreshBanner()
            } else {
                Updates.relaunch()
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let sheetWindow = window?.window, sheetWindow.attachedSheet == nil {
            alert.beginSheetModal(for: sheetWindow)
        } else {
            alert.runModal()
        }
    }
}
