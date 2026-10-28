import AppKit

/// A sheet over the main window while Discord can't be reached, laid out like a standard alert (app icon, bold
/// title, detail, default button). Retry is the only way out.
final class ConnectionLock {
    private let sheet: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var onRetry: (() -> Void)?
    private weak var parent: NSWindow?

    var isShown: Bool { parent?.attachedSheet === sheet }

    init() {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled], backing: .buffered, defer: true)
        titleLabel.font = Theme.boldFont
        detail.font = Theme.smallFont
        detail.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        retryButton.bezelStyle = .rounded
        retryButton.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(retry)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [spinner, retryButton])
        let stack = NSStackView(views: [titleLabel, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.related
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = sheet.contentView!
        content.addSubview(icon)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.edge),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Spacing.edge),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.edge),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.edge),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Spacing.edge),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Theme.Spacing.edge),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    func show(over window: NSWindow, title: String, detail text: String, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        titleLabel.stringValue = title
        detail.stringValue = text
        retryButton.isEnabled = true
        spinner.stopAnimation(nil)
        guard !isShown else { return }
        // Anything else floating over the window (an alert, the quick switcher) goes first.
        window.attachedSheet.map { window.endSheet($0) }
        window.childWindows?.forEach { $0.orderOut(nil) }
        parent = window
        window.beginSheet(sheet)
    }

    func hide() {
        guard isShown, let parent else { return }
        parent.endSheet(sheet)
    }

    @objc private func retry() {
        retryButton.isEnabled = false
        spinner.startAnimation(nil)
        onRetry?()
    }
}
