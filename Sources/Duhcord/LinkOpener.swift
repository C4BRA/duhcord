import AppKit
import DuhcordCore

/// Opens links in the browser after LinkGuard has checked them.
enum LinkOpener {
    static func open(_ url: URL, shownText: String?, from window: NSWindow?) {
        switch LinkGuard.check(url, shownText: shownText) {
        case .open:
            NSWorkspace.shared.open(url)
        case .block(let reason):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Duhcord blocked this link"
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            present(alert, in: window) { _ in }
        case .warn(let reasons):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Be careful with this link"
            alert.informativeText = reasons.joined(separator: "\n\n") + "\n\n" + url.absoluteString
            // Cancel is the default, so pressing Return never opens a risky link.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open in Browser")
            present(alert, in: window) { response in
                if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
            }
        }
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
