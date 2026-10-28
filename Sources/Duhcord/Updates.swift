import AppKit
import DuhcordUpdateKit

/// App-side helpers for updating: where Duhcord runs from, and talking to the installer helper.
enum Updates {
    /// The version in this build's Info.plist ("0.0.0" when run outside an app bundle).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Updates can only replace Duhcord in /Applications or ~/Applications. Run from anywhere else (Downloads,
    /// a disk image, or the hidden read-only copy macOS makes of quarantined apps) the swap can't happen.
    static var isInApplicationsFolder: Bool {
        let folder = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
        // The sandbox redirects the home folder APIs into the container, so ask the user database instead.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
        return folder == "/Applications" || (home.map { folder == $0 + "/Applications" } ?? false)
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

/// A thin bar across the top of the window. Orange for problems, the accent colour for good news.
final class BannerView: NSView {
    enum Tone { case warning, info }

    var onAction: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var tone: Tone = .warning

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(clicked)
        [label, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, tone: Tone, action: String?) {
        self.tone = tone
        label.stringValue = text
        button.title = action ?? ""
        button.isHidden = action == nil
        needsDisplay = true
    }

    func setActionEnabled(_ enabled: Bool) { button.isEnabled = enabled }

    /// Drawn with dynamic colours so it follows light and dark mode.
    override func draw(_ dirtyRect: NSRect) {
        let base: NSColor = tone == .warning ? .systemOrange : .controlAccentColor
        base.withAlphaComponent(0.18).setFill()
        bounds.fill()
        base.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func clicked() { onAction?() }
}

/// Puts an optional banner above the window's content.
final class BannerContainerViewController: NSViewController {
    let banner = BannerView()
    private let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        addChild(content)
        banner.isHidden = true
        let stack = NSStackView(views: [banner, content.view])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.detachesHiddenViews = true
        banner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        content.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
    }
}
