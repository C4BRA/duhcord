import AppKit

/// Asks for a token. We never handle passwords, captchas or 2FA.
final class LoginWindowController: NSWindowController {
    private let onSubmit: (String) -> Void
    private let field = NSSecureTextField()
    private let button = NSButton(title: "Log In", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Duhcord"
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Log in with your Discord token")
        title.font = .boldSystemFont(ofSize: 15)

        let help = NSTextField(wrappingLabelWithString:
            "In the official Discord app or website, open Developer Tools, go to the Network tab, select any "
            + "request to discord.com/api and copy its Authorization header. It is stored only in your Keychain.\n\n"
            + "Third-party clients break Discord's Terms of Service. Use at your own risk.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor

        field.placeholderString = "Token"
        field.target = self
        field.action = #selector(submit)

        button.target = self
        button.action = #selector(submit)
        button.keyEquivalent = "\r"
        button.bezelStyle = .rounded

        status.textColor = .systemRed
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let buttonRow = NSStackView(views: [status, spinner, button])
        buttonRow.orientation = .horizontal
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, help, field, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func submit() {
        var token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count > 1 { token = String(token.dropFirst().dropLast()) }
        guard !token.isEmpty else { return }
        status.stringValue = ""
        onSubmit(token)
    }

    func setBusy(_ busy: Bool) {
        button.isEnabled = !busy
        field.isEnabled = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func show(error: String) {
        setBusy(false)
        status.stringValue = error
    }
}
