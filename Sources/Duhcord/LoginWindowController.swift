import AppKit
import CoreImage.CIFilterBuiltins
import DuhcordCore

/// QR code login. There is deliberately no way to type or paste a token or password.
final class LoginWindowController: NSWindowController, NSWindowDelegate {
    private enum Mode { case idle, showingCode, busy, failed }

    private let onToken: (String) -> Void
    private let auth = RemoteAuth()
    private var mode: Mode = .idle
    private var retryAction: (() -> Void)?

    private let qrView = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retry = NSButton(title: "New Code", target: nil, action: nil)

    private static let qrSize: CGFloat = 220

    init(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Duhcord"
        super.init(window: window)
        window.delegate = self
        auth.onEvent = { [weak self] event in self?.handle(event) }
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if mode == .idle { beginQR() }
    }

    /// Fetches a fresh code. `message` is shown above it, for example after being logged out.
    func beginQR(message: String? = nil) {
        mode = .showingCode
        note.stringValue = message ?? ""
        note.isHidden = message == nil
        qrView.image = nil
        status.stringValue = "Getting a code…"
        retry.isHidden = true
        spinner.startAnimation(nil)
        auth.start()
    }

    /// Shown while the gateway connects after login, or at launch with a saved session.
    func setBusy() {
        mode = .busy
        auth.stop()
        qrView.image = nil
        note.isHidden = true
        status.stringValue = "Connecting to Discord…"
        retry.isHidden = true
        spinner.startAnimation(nil)
    }

    /// Shows an error with a Retry button. Without `retry`, Retry fetches a new QR code.
    func show(error: String, retry action: (() -> Void)? = nil) {
        mode = .failed
        auth.stop()
        retryAction = action
        qrView.image = nil
        status.stringValue = error
        retry.title = "Retry"
        retry.isHidden = false
        spinner.stopAnimation(nil)
    }

    // MARK: - Events

    private func handle(_ event: RemoteAuth.Event) {
        guard mode == .showingCode else { return }
        switch event {
        case .showCode(let url):
            spinner.stopAnimation(nil)
            qrView.image = Self.qrImage(for: url.absoluteString, size: Self.qrSize)
            qrView.setAccessibilityLabel("Login QR code. Scan it with the Discord app on your phone.")
            status.stringValue = "Scan with the Discord app on your phone:\nYou → Settings → Scan QR Code"
        case .scanned(let username):
            qrView.image = nil
            spinner.startAnimation(nil)
            status.stringValue = "Approve the login on your phone to continue as \(username)."
        case .loggedIn(let token):
            setBusy()
            onToken(token)
        case .expired:
            mode = .failed
            retryAction = nil
            qrView.image = nil
            spinner.stopAnimation(nil)
            status.stringValue = "The code expired."
            retry.title = "New Code"
            retry.isHidden = false
        case .unreachable:
            show(error: "Can't reach Discord. Check your connection and try again.")
        case .cancelled:
            show(error: "Login was cancelled on your phone.")
        case .failed(let message):
            show(error: message)
        }
    }

    @objc private func retryClicked() {
        if let action = retryAction {
            retryAction = nil
            setBusy()
            action()
        } else {
            beginQR()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Nobody is looking at the code, so drop the connection and the key.
        if mode == .showingCode || mode == .failed {
            auth.stop()
            mode = .idle
        }
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Log in to Duhcord")
        title.font = Theme.headingFont

        qrView.imageScaling = .scaleNone
        qrView.setAccessibilityElement(true)
        qrView.setAccessibilityRole(.image)
        qrView.wantsLayer = true
        qrView.layer?.cornerRadius = 8
        qrView.layer?.masksToBounds = true

        status.alignment = .center
        status.font = Theme.bodyFont

        note.alignment = .center
        note.font = Theme.smallFont
        note.textColor = .systemOrange
        note.isHidden = true

        let warning = NSTextField(wrappingLabelWithString:
            "Only scan a code from a Duhcord window you opened yourself. Anyone who gets you to scan their code gets your account.")
        warning.alignment = .center
        warning.font = Theme.captionFont
        warning.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        retry.target = self
        retry.action = #selector(retryClicked)
        retry.bezelStyle = .rounded
        retry.isHidden = true

        let stack = NSStackView(views: [title, note, qrView, spinner, status, retry, warning])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.Spacing.group
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.edge),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Spacing.edge),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Spacing.edge),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Theme.Spacing.edge),
            qrView.widthAnchor.constraint(equalToConstant: Self.qrSize),
            qrView.heightAnchor.constraint(equalToConstant: Self.qrSize),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// Black on white regardless of dark mode, so phone cameras read it reliably. Drawn at an integer scale
    /// with no smoothing so every module stays sharp.
    private static func qrImage(for string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }

        let pixels = size * 2
        let quietZone: CGFloat = 4
        let scale = floor(pixels / (code.extent.width + quietZone * 2))
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let side = (code.extent.width + quietZone * 2) * scale
        let background = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let composed = scaled.transformed(by: CGAffineTransform(translationX: quietZone * scale, y: quietZone * scale))
            .composited(over: background)

        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = context.createCGImage(composed, from: composed.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side / 2, height: side / 2))
    }
}
