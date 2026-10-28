import AppKit
import DuhcordVoiceKit

/// "Voice Connection": the call's server, ping, packet loss and encryption, opened from "Voice Connected" in the
/// voice bar. The helper only measures and sends these while this panel is open. Advanced details show
/// everything else about the connection, and can be copied for troubleshooting.
final class VoiceDetailsWindowController: NSWindowController, NSWindowDelegate {
    private static let advancedKey = "voiceDetailsAdvanced"

    var onClose: (() -> Void)?

    private let voice: VoiceController
    private let graph = PingGraphView()
    private let server = VoiceDetailsWindowController.value()
    private let ping = VoiceDetailsWindowController.value()
    private let loss = VoiceDetailsWindowController.value()
    private let encryptionIcon = NSImageView()
    private let encryption = VoiceDetailsWindowController.value()

    private let transport = VoiceDetailsWindowController.value()
    private let endToEnd = VoiceDetailsWindowController.value()
    private let privacyCode = VoiceDetailsWindowController.value()
    private let codec = VoiceDetailsWindowController.value("Opus, 48 kHz (64 kbit/s up)")
    private let received = VoiceDetailsWindowController.value()
    private let lost = VoiceDetailsWindowController.value()
    private let sent = VoiceDetailsWindowController.value()
    private let unreadable = VoiceDetailsWindowController.value()
    private let undecryptable = VoiceDetailsWindowController.value()
    private let microphone = VoiceDetailsWindowController.value()
    private let output = VoiceDetailsWindowController.value()

    private let advancedToggle = NSButton(checkboxWithTitle: "Show advanced details", target: nil, action: nil)
    private var advanced = NSStackView()
    private var stats: VoiceStats?

    init(voice: VoiceController) {
        self.voice = voice
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Voice Connection"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildContent()
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the panel and asks the helper for live details until it closes.
    func show() {
        voice.onStats = { [weak self] stats in self?.update(stats) }
        voice.statsWanted = true
        if let latest = voice.latestStats { update(latest) }
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        voice.statsWanted = false
        voice.onStats = nil
        onClose?()
    }

    // MARK: - Layout

    private func buildContent() {
        encryptionIcon.symbolConfiguration = .init(pointSize: NSFont.systemFontSize, weight: .medium)
        let encryptionRow = NSStackView(views: [encryptionIcon, encryption])
        encryptionRow.spacing = Theme.Spacing.tight
        privacyCode.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        privacyCode.lineBreakMode = .byWordWrapping
        privacyCode.maximumNumberOfLines = 2

        let basic = Self.grid([
            ("Server", server),
            ("Ping", ping),
            ("Packet loss", loss),
            ("Encryption", encryptionRow),
        ])
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 96).isActive = true

        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.state = UserDefaults.standard.bool(forKey: Self.advancedKey) ? .on : .off

        let copyButton = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        let details = Self.grid([
            ("Transport", transport),
            ("End-to-end", endToEnd),
            ("Privacy code", privacyCode),
            ("Codec", codec),
            ("Received", received),
            ("Lost", lost),
            ("Sent", sent),
            ("Unreadable", unreadable),
            ("Undecryptable", undecryptable),
            ("Microphone", microphone),
            ("Output", output),
        ])
        advanced = NSStackView(views: [NSBox.separator(), details, copyButton])
        advanced.orientation = .vertical
        advanced.alignment = .leading
        advanced.spacing = Theme.Spacing.group
        advanced.isHidden = advancedToggle.state == .off

        let stack = NSStackView(views: [basic, graph, advancedToggle, advanced])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.group
        stack.setCustomSpacing(Theme.Spacing.related, after: basic)
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.edge, left: Theme.Spacing.edge,
                                        bottom: Theme.Spacing.edge, right: Theme.Spacing.edge)
        // Hidden advanced details take no space, so the panel shrinks to fit.
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 360),
            graph.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.edge),
            advanced.widthAnchor.constraint(equalTo: graph.widthAnchor),
        ])
        window?.contentView = content
        clear()
    }

    private static func value(_ text: String = "—") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Two columns, labels right-aligned against their values, as in Get Info windows.
    private static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { title, view -> [NSView] in
            let label = NSTextField(labelWithString: title + ":")
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return [label, view]
        })
        grid.rowSpacing = Theme.Spacing.tight + 2
        grid.columnSpacing = Theme.Spacing.related
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 104
        grid.rowAlignment = .firstBaseline
        return grid
    }

    // MARK: - Content

    private func clear() {
        encryptionIcon.image = nil
        graph.samples = []
    }

    private func update(_ stats: VoiceStats) {
        self.stats = stats
        server.stringValue = stats.server
        if let average = stats.averagePing, let last = stats.pings.last {
            ping.stringValue = "\(Int(average.rounded())) ms average, \(Int(last.milliseconds.rounded())) ms last"
        } else {
            ping.stringValue = "Measuring…"
        }
        loss.stringValue = String(format: "%.1f%%", stats.lossPercent)
        if stats.endToEndEncrypted {
            encryptionIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            encryptionIcon.contentTintColor = .systemGreen
            encryption.stringValue = "End-to-end encrypted"
            encryption.toolTip = "Only the people in this call can hear it. Discord relays the audio but can't decrypt it."
        } else {
            encryptionIcon.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: nil)
            encryptionIcon.contentTintColor = .systemOrange
            encryption.stringValue = "Not end-to-end encrypted yet"
            encryption.toolTip = "Nothing you say is sent until end-to-end encryption is set up."
        }
        graph.samples = stats.pings

        transport.stringValue = stats.transport
        endToEnd.stringValue = stats.daveProtocolVersion > 0 ? "DAVE, protocol version \(stats.daveProtocolVersion)" : "Off"
        privacyCode.stringValue = Self.privacyCodeLines(stats.privacyCode) ?? "—"
        received.stringValue = stats.packetsReceived.formatted()
        lost.stringValue = stats.packetsLost.formatted()
        sent.stringValue = stats.packetsSent.formatted()
        unreadable.stringValue = stats.unreadable.formatted()
        undecryptable.stringValue = stats.undecryptable.formatted()
        microphone.stringValue = stats.microphone ?? "—"
        output.stringValue = stats.output ?? "—"
    }

    /// Three groups of five digits per line, as the official app shows it.
    private static func privacyCodeLines(_ code: String?) -> String? {
        guard let groups = code?.split(separator: " "), groups.count == 6 else { return code }
        return groups[0..<3].joined(separator: " ") + "\n" + groups[3...].joined(separator: " ")
    }

    @objc private func toggleAdvanced() {
        let on = advancedToggle.state == .on
        UserDefaults.standard.set(on, forKey: Self.advancedKey)
        advanced.isHidden = !on
    }

    @objc private func copyDiagnostics() {
        guard let stats else { return }
        let lines = [
            "Server: \(stats.server)",
            "Ping: " + (stats.averagePing.map { "\(Int($0.rounded())) ms average" } ?? "not measured yet")
                + ", samples (seconds ago: ms): "
                + stats.pings.map { "\(Int($0.age)): \(Int($0.milliseconds.rounded()))" }.joined(separator: ", "),
            "Packet loss: " + String(format: "%.2f%%", stats.lossPercent),
            "End-to-end encrypted: \(stats.endToEndEncrypted ? "yes" : "no")",
            "Transport: \(stats.transport)",
            "DAVE protocol version: \(stats.daveProtocolVersion)",
            "Privacy code: \(stats.privacyCode ?? "none")",
            "Codec: Opus, 48 kHz, 64 kbit/s up",
            "Packets received: \(stats.packetsReceived), lost: \(stats.packetsLost), sent: \(stats.packetsSent)",
            "Unreadable: \(stats.unreadable), undecryptable: \(stats.undecryptable)",
            "Microphone: \(stats.microphone ?? "unknown")",
            "Output: \(stats.output ?? "unknown")",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// Ping over the last five minutes, newest on the right, with guide lines every 100 ms (at least up to 200).
private final class PingGraphView: NSView {
    private static let span: Double = 300

    var samples: [VoiceStats.PingSample] = [] {
        didSet {
            needsDisplay = true
            if let average = samples.isEmpty ? nil : samples.map(\.milliseconds).reduce(0, +) / Double(samples.count) {
                setAccessibilityValue("Average \(Int(average.rounded())) milliseconds")
            } else {
                setAccessibilityValue("No measurements yet")
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Ping over the last 5 minutes")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let labelWidth: CGFloat = 44
        let font = Theme.captionFont
        let top = ceil(max(200, samples.map(\.milliseconds).max() ?? 0) / 100) * 100
        let plot = NSRect(x: labelWidth, y: font.pointSize / 2 + 1, width: bounds.width - labelWidth,
                          height: bounds.height - font.pointSize - 2)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]

        // Guide lines, labelled every 100 ms (or fewer when the scale is tall).
        let step = top > 400 ? ceil(top / 400) * 100 : 100
        var level = 0.0
        while level <= top {
            let y = plot.minY + plot.height * level / top
            NSColor.separatorColor.setFill()
            NSRect(x: plot.minX, y: y.rounded(.down), width: plot.width, height: 1).fill()
            let text = NSAttributedString(string: "\(Int(level)) ms", attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: labelWidth - size.width - Theme.Spacing.related, y: y - size.height / 2))
            level += step
        }

        let points = samples.filter { $0.age <= Self.span }.sorted { $0.age > $1.age }.map { sample in
            NSPoint(x: plot.minX + plot.width * (1 - sample.age / Self.span),
                    y: plot.minY + plot.height * min(sample.milliseconds, top) / top)
        }
        guard let first = points.first else { return }
        NSColor.controlAccentColor.set()
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.move(to: first)
        points.dropFirst().forEach { line.line(to: $0) }
        line.stroke()
        for point in points {
            NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        }
    }
}
