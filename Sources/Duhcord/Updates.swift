import AppKit
import DuhcordUpdateKit

/// App-side helpers for updating: where Duhcord runs from, and talking to the installer helper.
enum Updates {
    /// The version in this build's Info.plist ("0.0.0" when run outside an app bundle).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Run from anywhere else (Downloads, a disk image, or the hidden read-only copy macOS makes of quarantined
    /// apps) the swap can't happen.
    static var isInApplicationsFolder: Bool {
        UpdateKit.isApplicationsFolder(Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent())
    }

    /// Hands a downloaded, verified archive to the installer helper. The reply is nil on success.
    static func install(archive: URL, manifest: Data, signature: Data, completion: @escaping (String?) -> Void) {
        let connection = NSXPCConnection(serviceName: UpdateKit.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DuhcordUpdaterProtocol.self)
        connection.resume()

        // The error handler and the reply can both fire; only the first one counts.
        var finished = false
        let finish: (String?) -> Void = { message in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                connection.invalidate()
                completion(message)
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: archive),
              let helper = connection.remoteObjectProxyWithErrorHandler({ error in
                  let nsError = error as NSError
                  finish("The installer couldn't be started: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
              }) as? DuhcordUpdaterProtocol else {
            finish("The installer couldn't be started.")
            return
        }
        helper.install(archive: handle, manifest: manifest, signature: signature) { message in
            try? handle.close()
            try? FileManager.default.removeItem(at: archive)
            finish(message)
        }
    }

    /// Starts the freshly installed copy and quits this one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The info bar under the toolbar (a titlebar accessory), like Safari's and Mail's: a symbol carries the tone
/// (orange for problems, the accent colour for news), the text says what's going on, and a button acts on it.
final class BannerView: NSView {
    enum Tone { case warning, info, secure }

    var onAction: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        label.font = Theme.smallFont
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(clicked)
        [icon, label, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.group),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.related),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: Theme.Spacing.related),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.group),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, tone: Tone, action: String?) {
        switch tone {
        case .warning:
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            icon.contentTintColor = .systemOrange
        case .info:
            icon.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Information")
            icon.contentTintColor = .controlAccentColor
        case .secure:
            icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Private")
            icon.contentTintColor = .systemGreen
        }
        label.stringValue = text
        button.title = action ?? ""
        button.isHidden = action == nil
        setAccessibilityLabel(text)
    }

    @objc private func clicked() { onAction?() }
}
