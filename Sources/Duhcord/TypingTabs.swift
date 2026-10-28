import AppKit
import DuhcordCore

/// The typing indicator: a small tab with someone's profile picture rises from behind the message box while
/// they type, sinks halfway when they stop or send, and slides away a minute later.
///
/// Every movement is a one-off Core Animation spring or ease drawn by the window server, so the app does no
/// per-frame work, and nothing moves (or costs anything) between changes. Reduce Motion swaps the movement
/// for a fade.
final class TypingTabsView: NSView {
    static let tabSize = NSSize(width: 30, height: 34)
    private static let spacing: CGFloat = 4
    private static let maxTabs = 5

    private var tabs: [Snowflake: TypingTab] = [:]
    private let overflow = TypingTab()

    /// True while any tab is showing, so the message list can keep its last message clear of them.
    private(set) var hasTabs = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Tabs below the bottom edge are hidden, so they appear to come out from behind the message box.
        layer?.masksToBounds = true
        overflow.isHidden = true
        addSubview(overflow)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ entries: [TypingTracker.Entry]) {
        let shown = Array(entries.prefix(Self.maxTabs))
        let shownIDs = Set(shown.map(\.userID))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Gone: sink out of sight, then remove.
        for (id, tab) in tabs where !shownIDs.contains(id) {
            tabs[id] = nil
            tab.move(to: hiddenFrame(for: tab.frame.minX), alpha: 0, spring: false, reduceMotion: reduceMotion) {
                tab.removeFromSuperview()
            }
        }

        for (index, entry) in shown.enumerated() {
            let x = CGFloat(index) * (Self.tabSize.width + Self.spacing)
            let tab: TypingTab
            if let existing = tabs[entry.userID] {
                tab = existing
            } else {
                // New: start hidden below the edge so it can rise into place.
                tab = TypingTab()
                tab.frame = hiddenFrame(for: x)
                tab.alphaValue = reduceMotion ? 0 : 1
                addSubview(tab, positioned: .below, relativeTo: overflow)
                tabs[entry.userID] = tab
            }
            tab.show(entry)
            let target = NSRect(origin: NSPoint(x: x, y: entry.raised ? 0 : -Self.tabSize.height / 2), size: Self.tabSize)
            // Rising gets a little spring; sinking eases down without bouncing.
            tab.move(to: target, alpha: entry.raised ? 1 : 0.85, spring: entry.raised, reduceMotion: reduceMotion)
        }

        let extra = entries.count - shown.count
        overflow.isHidden = extra <= 0
        if extra > 0 {
            overflow.showCount(extra)
            let x = CGFloat(shown.count) * (Self.tabSize.width + Self.spacing)
            overflow.frame = NSRect(origin: NSPoint(x: x, y: -Self.tabSize.height / 2), size: Self.tabSize)
        }
        hasTabs = !entries.isEmpty
    }

    private func hiddenFrame(for x: CGFloat) -> NSRect {
        NSRect(origin: NSPoint(x: x, y: -Self.tabSize.height), size: Self.tabSize)
    }
}

/// One tab: rounded top corners, a profile picture, and a tooltip with who it is.
private final class TypingTab: NSView {
    private let avatar = RemoteImageView()
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        avatar.cornerRadius = 11
        avatar.frame = NSRect(x: 4, y: TypingTabsView.tabSize.height - 26, width: 22, height: 22)
        countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        countLabel.alignment = .center
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: 0, y: TypingTabsView.tabSize.height - 22, width: TypingTabsView.tabSize.width, height: 14)
        countLabel.isHidden = true
        addSubview(avatar)
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ entry: TypingTracker.Entry) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        avatar.setImage(MediaRequest.avatarURL(for: entry.user, pixels: Int(22 * scale)), pointSize: avatar.frame.size)
        toolTip = entry.raised ? "\(entry.name) is typing…" : "\(entry.name) stopped typing"
        setAccessibilityLabel(toolTip)
    }

    func showCount(_ count: Int) {
        avatar.isHidden = true
        countLabel.isHidden = false
        countLabel.stringValue = "+\(count)"
        toolTip = "\(count) more"
    }

    /// One animation to the new position. The window server draws it; there's no per-frame app code.
    func move(to target: NSRect, alpha: CGFloat, spring: Bool, reduceMotion: Bool, completion: (() -> Void)? = nil) {
        if reduceMotion {
            frame = target
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                animator().alphaValue = alpha
            }, completionHandler: completion)
            return
        }
        guard frame != target || alphaValue != alpha else {
            completion?()
            return
        }
        if spring, let layer {
            // A gentle overshoot as it pops up.
            let animation = CASpringAnimation(keyPath: "position.y")
            animation.damping = 14
            animation.stiffness = 220
            animation.mass = 1
            animation.fromValue = layer.position.y
            animation.toValue = target.minY + layer.anchorPoint.y * target.height
            animation.duration = animation.settlingDuration
            frame = target
            alphaValue = alpha
            layer.add(animation, forKey: "rise")
            completion?()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().frame = target
                animator().alphaValue = alpha
            }, completionHandler: completion)
        }
    }

    /// Rounded top corners and a hairline border, drawn with dynamic colours for light and dark mode.
    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        let rect = bounds.insetBy(dx: 0.5, dy: 0)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY - 0.5))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
