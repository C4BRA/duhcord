import AppKit
import DuhcordCore

/// Fonts, colours and message rendering. Everything uses system colours so dark mode just works.
enum Theme {
    /// Sidebar fonts stay at the system size; message fonts follow the text size setting.
    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    static let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    static var messageFont: NSFont { NSFont.systemFont(ofSize: Settings.textSize.pointSize) }
    static var messageBoldFont: NSFont { NSFont.boldSystemFont(ofSize: Settings.textSize.pointSize) }
    static var messageSmallFont: NSFont { NSFont.systemFont(ofSize: Settings.textSize.pointSize - 2) }
    static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: Settings.textSize.pointSize - 1, weight: .regular) }

    /// Darker strip behind the guild column so it reads as separate from the channel list.
    static let guildColumnBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.08, alpha: 1)
            : NSColor(white: 0.84, alpha: 1)
    }

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
    static func body(for message: Message, resolver: Markdown.Resolver) -> NSAttributedString {
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

        for attachment in message.attachments {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            // Attachments open in the browser rather than loading inline, so nothing downloads unless asked.
            var attrs: [NSAttributedString.Key: Any] = [.font: messageFont, .foregroundColor: NSColor.linkColor]
            if let url = URL(string: attachment.url) { attrs[.link] = url }
            let kind = (attachment.contentType ?? "").hasPrefix("image/") ? "image" : "file"
            out.append(NSAttributedString(string: "[\(kind): \(attachment.filename)]", attributes: attrs))
        }

        if out.length == 0 {
            out.append(NSAttributedString(string: "(no text)", attributes: secondary))
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
