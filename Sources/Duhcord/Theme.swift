import AppKit
import DuhcordCore

/// Duhcord's design tokens and message rendering. Every view takes its spacing, type, corner radii and icon sizes
/// from here, so the app follows one set of rules instead of each view picking its own numbers.
///
/// The rules come from Apple's Human Interface Guidelines: system text styles, system colours (so dark mode,
/// accent colours and Increase Contrast just work), and the macOS spacing rhythm.
enum Theme {
    /// The macOS spacing rhythm.
    enum Spacing {
        /// Inside one control or between an icon and its label.
        static let tight: CGFloat = 4
        /// Between related items.
        static let related: CGFloat = 8
        /// Between groups, and the inset of sidebar and list content.
        static let group: CGFloat = 12
        /// Window and sheet margins.
        static let edge: CGFloat = 20
    }

    enum Radius {
        static let small: CGFloat = 4
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let panel: CGFloat = 12
    }

    enum IconSize {
        /// Sidebar and list icons, and server icons in the sidebar.
        static let sidebar: CGFloat = 18
        /// Profile pictures in lists.
        static let listAvatar: CGFloat = 20
    }

    // Apple's text styles. macOS has no app-level text size, so these follow the system: the same sizes and
    // weights as Mail, Messages and Notes.
    static let bodyFont = NSFont.preferredFont(forTextStyle: .body)
    static let boldFont = NSFont.preferredFont(forTextStyle: .headline)
    static let smallFont = NSFont.preferredFont(forTextStyle: .subheadline)
    static let captionFont = NSFont.preferredFont(forTextStyle: .caption1)
    static let titleFont = NSFont.preferredFont(forTextStyle: .title3)

    static let messageFont = bodyFont
    static let messageBoldFont = boldFont
    static let messageSmallFont = smallFont
    static let monoFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)

    /// Sidebar and list text follows System Settings → Appearance → Sidebar icon size (or Duhcord's compact
    /// layout, which picks the small size).
    static func listFont(for size: NSTableView.RowSizeStyle, bold: Bool = false) -> NSFont {
        let pointSize: CGFloat
        switch size {
        case .small: pointSize = NSFont.smallSystemFontSize
        case .large: pointSize = 15
        default: pointSize = NSFont.systemFontSize
        }
        return bold ? .boldSystemFont(ofSize: pointSize) : .systemFont(ofSize: pointSize)
    }

    /// The row size lists use: the system's sidebar setting, or small in compact layout.
    static var listRowSize: NSTableView.RowSizeStyle { Settings.compactLayout ? .small : .default }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Name and timestamp line shown above a group of messages.
    static func header(for message: Message) -> NSAttributedString {
        let s = NSMutableAttributedString(string: message.author.displayName, attributes: [
            .font: messageBoldFont,
            .foregroundColor: NSColor.labelColor,
        ])
        // "Display Name (@username)", so people can't hide behind a borrowed display name.
        // Skipped when the two are identical, which would just repeat the name.
        if message.author.displayName != message.author.username {
            s.append(NSAttributedString(string: " (@\(message.author.username))", attributes: [
                .font: messageFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if let date = message.date {
            s.append(NSAttributedString(string: "  " + timeFormatter.string(from: date), attributes: [
                .font: messageSmallFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return s
    }

    /// Message body: reply line, markdown content, edited marker and attachment links.
    /// `inlineAttachments` are shown as images, so they're left out of the text. `hasVisuals` suppresses
    /// "(no text)" when the message is just an image or a link preview.
    static func body(for message: Message, resolver: Markdown.Resolver, inlineAttachments: Set<Snowflake> = [],
                     hasVisuals: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let secondary: [NSAttributedString.Key: Any] = [.font: messageSmallFont, .foregroundColor: NSColor.secondaryLabelColor]

        if let reply = message.referencedMessage {
            let preview = reply.content.replacingOccurrences(of: "\n", with: " ")
            let clipped = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
            out.append(NSAttributedString(string: "↪ \(reply.author.displayName): \(clipped)\n", attributes: secondary))
        }

        out.append(render(Markdown.parse(message.content, resolver: resolver)))

        if message.editedTimestamp != nil {
            out.append(NSAttributedString(string: " (edited)", attributes: secondary))
        }

        for attachment in message.attachments where !inlineAttachments.contains(attachment.id) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            // Attachments open in the browser rather than loading inline, so nothing downloads unless asked.
            var attrs: [NSAttributedString.Key: Any] = [.font: messageFont, .foregroundColor: NSColor.linkColor]
            if let url = URL(string: attachment.url) { attrs[.link] = url }
            let kind = (attachment.contentType ?? "").hasPrefix("image/") ? "image" : "file"
            out.append(NSAttributedString(string: "[\(kind): \(attachment.filename)]", attributes: attrs))
        }

        if out.length == 0, !hasVisuals {
            out.append(NSAttributedString(string: "(no text)", attributes: secondary))
        }
        return out
    }

    /// The text of a link preview or rich card: site, author, title, description, fields and footer.
    static func embedText(_ embed: Embed, resolver: Markdown.Resolver) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ text: NSAttributedString) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(text)
        }
        func plain(_ text: String, font: NSFont, color: NSColor, link: String? = nil) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let link, let url = URL(string: link), url.scheme == "https" || url.scheme == "http" {
                attrs[.link] = url
            }
            return NSAttributedString(string: text, attributes: attrs)
        }

        if let provider = embed.provider?.name, !provider.isEmpty {
            line(plain(provider, font: messageSmallFont, color: .secondaryLabelColor, link: embed.provider?.url))
        }
        if let author = embed.author?.name, !author.isEmpty {
            line(plain(author, font: NSFont.boldSystemFont(ofSize: messageSmallFont.pointSize), color: .labelColor, link: embed.author?.url))
        }
        if let title = embed.title, !title.isEmpty {
            line(plain(title, font: messageBoldFont, color: embed.url == nil ? .labelColor : .linkColor, link: embed.url))
        }
        if let description = embed.description, !description.isEmpty {
            line(render(Markdown.parse(description, resolver: resolver)))
        }
        for field in embed.fields ?? [] {
            line(plain(field.name, font: NSFont.boldSystemFont(ofSize: messageSmallFont.pointSize), color: .labelColor))
            line(render(Markdown.parse(field.value, resolver: resolver)))
        }
        if let footer = embed.footer?.text, !footer.isEmpty {
            line(plain(footer, font: messageSmallFont, color: .secondaryLabelColor))
        }
        return out
    }

    static func render(_ spans: [Markdown.Span]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
            let style = span.style

            var font = messageFont
            if style.contains(.code) || style.contains(.codeBlock) {
                font = monoFont
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if style.contains(.bold) { traits.insert(.bold) }
            if style.contains(.italic) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            attrs[.font] = font

            if style.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if style.contains(.quote) { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
            if style.contains(.mention) {
                attrs[.foregroundColor] = NSColor.controlAccentColor
                attrs[.font] = NSFont.boldSystemFont(ofSize: font.pointSize)
            }
            if style.contains(.spoiler) {
                // Hidden until hovered: same colour for text and background.
                attrs[.foregroundColor] = NSColor.tertiaryLabelColor
                attrs[.backgroundColor] = NSColor.tertiaryLabelColor
                attrs[.toolTip] = span.text
            }
            if style.contains(.linkHost) {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                attrs[.font] = messageSmallFont
            }
            if let urlString = span.url, let url = URL(string: urlString) {
                attrs[.link] = url
            }

            var text = span.text
            if style.contains(.quote), out.length == 0 || out.string.hasSuffix("\n") { text = "▎ " + text }
            if style.contains(.codeBlock) {
                if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n")) }
                text += "\n"
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        // Drop a trailing newline left by a code block.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// Up to two initials for a guild with no icon loaded.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

extension NSTableView {
    /// Makes the single column always exactly as wide as the visible table.
    ///
    /// A new NSTableColumn starts 100pt wide, and a table inside a scroll view never gets narrower than
    /// its columns. Autoresizing alone therefore can't shrink it: in the 64pt guild strip every row stayed
    /// 100pt wide, so cells were centred 18pt too far right and clipped by the column edge. Starting the
    /// column at zero width lets the table take the clip view's width, and autoresizing then grows the
    /// column to match (and keeps it matched as the view resizes).
    func fitColumnToWidth() {
        for column in tableColumns {
            column.minWidth = 0
            column.width = 0
            column.resizingMask = .autoresizingMask
        }
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sizeLastColumnToFit()
    }
}

extension NSFont {
    /// The same font at another weight.
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
