import AppKit

/// The message box. Grows with its text up to `maxLines`, then scrolls.
/// Return sends; Shift-Return or Option-Return inserts a newline.
final class ComposerView: NSView, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    /// Called when the height changes, so the parent can keep the message list pinned to the bottom.
    var onHeightChange: (() -> Void)?

    let textView = PlaceholderTextView()
    private let scrollView = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!

    private static let maxLines: CGFloat = 8
    private static let verticalInset: CGFloat = 6
    private static let horizontalInset: CGFloat = 8

    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue; textView.needsDisplay = true }
    }

    var isEnabled: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue; textView.isSelectable = newValue }
    }

    var text: String {
        get { textView.string }
        set { textView.string = newValue; updateHeight() }
    }

    var font: NSFont {
        get { textView.font ?? Theme.messageFont }
        set {
            textView.font = newValue
            textView.typingAttributes[.font] = newValue
            updateHeight()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        // Typing code shouldn't get "smart" quotes or dashes.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: Self.horizontalInset - 5, height: Self.verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = Theme.messageFont

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            heightConstraint,
        ])
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rounded field drawn with dynamic colours, so it follows light and dark mode without extra work.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    override func layout() {
        super.layout()
        updateHeight()
    }

    func focus() { window?.makeFirstResponder(textView) }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateHeight()
        textView.needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.option) {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { onSend?(message) }
        }
        return true
    }

    // MARK: - Sizing

    private func updateHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let used = max(layoutManager.usedRect(for: container).height, lineHeight)
        let maxContent = lineHeight * Self.maxLines
        let content = min(used, maxContent)
        let height = ceil(content + Self.verticalInset * 2) + 2
        scrollView.hasVerticalScroller = used > maxContent
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        onHeightChange?()
    }
}

/// NSTextView has no placeholder, so draw one while the text is empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? Theme.messageFont,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}
