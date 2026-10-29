import AppKit

/// The message box. Grows with its text up to `maxLines`, then scrolls.
/// Return sends; Shift-Return or Option-Return inserts a newline.
@MainActor
final class ComposerView: NSView, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    /// Called as the user types, with the current text (used to send typing notices).
    var onTextChange: ((String) -> Void)?
    /// Called when the height changes, so the parent can keep the message list pinned to the bottom.
    var onHeightChange: (() -> Void)?
    /// Images pasted or dropped into the box: returns true if they were taken (otherwise it's an ordinary paste).
    var onImages: ((NSPasteboard) -> Bool)? {
        didSet { textView.onImages = onImages }
    }
    /// Whether pasted and dropped images are wanted now (in Private).
    var acceptsImages: (() -> Bool)? {
        didSet { textView.acceptsImages = acceptsImages }
    }
    /// Whether Return sends with no text (images are attached).
    var canSendEmpty: (() -> Bool)?

    let textView = PlaceholderTextView()
    private let scrollView = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!

    private static let maxLines: CGFloat = 8
    private static let verticalInset: CGFloat = 6
    private static let horizontalInset: CGFloat = 8

    var placeholder: String {
        get { textView.placeholder }
        set {
            textView.placeholder = newValue
            textView.setAccessibilityPlaceholderValue(newValue)
            textView.needsDisplay = true
        }
    }

    /// While typing, the box shows the system's keyboard focus ring colour, as standard text fields do.
    private var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
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
        textView.setAccessibilityLabel("Message")
        textView.onFocusChange = { [weak self] focused in self?.isFocused = focused }

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
        if isFocused {
            // Drawn inside the box (the window would clip a ring outside it), at the standard ring's width.
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            ring.lineWidth = 3
            NSColor.keyboardFocusIndicatorColor.setStroke()
            ring.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
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
        onTextChange?(textView.string)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.option) {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty || canSendEmpty?() == true { onSend?(message) }
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
@MainActor
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    /// Called with true when typing starts in this view, false when focus moves elsewhere.
    var onFocusChange: ((Bool) -> Void)?
    /// See ComposerView.onImages and acceptsImages.
    var onImages: ((NSPasteboard) -> Bool)?
    var acceptsImages: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if acceptsImages?() == true, ImagePrep.canRead(.general), onImages?(.general) == true { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsImages?() == true, ImagePrep.canRead(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsImages?() == true, ImagePrep.canRead(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if acceptsImages?() == true, ImagePrep.canRead(sender.draggingPasteboard),
           onImages?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

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
