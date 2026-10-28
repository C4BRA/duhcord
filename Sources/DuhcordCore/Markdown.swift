import Foundation

/// Parses the subset of Discord markdown we render into flat styled spans.
/// The UI turns spans into an attributed string; keeping parsing here lets us test it without AppKit.
public enum Markdown {
    public struct Style: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let underline = Style(rawValue: 1 << 2)
        public static let strikethrough = Style(rawValue: 1 << 3)
        public static let code = Style(rawValue: 1 << 4)
        public static let codeBlock = Style(rawValue: 1 << 5)
        public static let quote = Style(rawValue: 1 << 6)
        public static let spoiler = Style(rawValue: 1 << 7)
        public static let mention = Style(rawValue: 1 << 8)
        public static let link = Style(rawValue: 1 << 9)
        /// The real destination shown after a masked link's text, e.g. "(example.com)".
        public static let linkHost = Style(rawValue: 1 << 10)
    }

    public struct Span: Equatable {
        public var text: String
        public var style: Style
        public var url: String?

        public init(_ text: String, _ style: Style = [], url: String? = nil) {
            self.text = text
            self.style = style
            self.url = url
        }
    }

    /// Looks up display names for `<@id>`, `<#id>` and `<@&id>` tokens.
    public struct Resolver {
        public var user: (Snowflake) -> String?
        public var channel: (Snowflake) -> String?

        public init(user: @escaping (Snowflake) -> String? = { _ in nil },
                    channel: @escaping (Snowflake) -> String? = { _ in nil }) {
            self.user = user
            self.channel = channel
        }
    }

    /// One shared formatter: creating a DateFormatter per timestamp is expensive.
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static func parse(_ source: String, resolver: Resolver = Resolver()) -> [Span] {
        var parser = Parser(chars: Array(source), resolver: resolver)
        parser.parseBlocks()
        return merge(parser.spans)
    }

    /// Joins neighbouring spans with identical styling.
    static func merge(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for span in spans where !span.text.isEmpty {
            if var last = out.last, last.style == span.style, last.url == span.url {
                last.text += span.text
                out[out.count - 1] = last
            } else {
                out.append(span)
            }
        }
        return out
    }

    private struct Parser {
        let chars: [Character]
        let resolver: Resolver
        var spans: [Span] = []

        init(chars: [Character], resolver: Resolver) {
            self.chars = chars
            self.resolver = resolver
        }

        /// Splits out code blocks and quote lines, then parses inline markup in what's left.
        mutating func parseBlocks() {
            var i = 0
            var lineStart = true
            var textStart = 0

            func flushInline(_ end: Int, into parser: inout Parser) {
                guard end > textStart else { return }
                parser.parseInline(textStart, end, base: [])
            }

            var fenceAbsent: Set<String> = []
            while i < chars.count {
                if matches("```", at: i), let close = find("```", from: i + 3, before: chars.count, absent: &fenceAbsent) {
                    flushInline(i, into: &self)
                    var bodyStart = i + 3
                    // A language tag runs to the first newline; we drop it.
                    if let nl = chars[bodyStart..<close].firstIndex(of: "\n"),
                       chars[bodyStart..<nl].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) {
                        bodyStart = nl + 1
                    }
                    var body = String(chars[bodyStart..<close])
                    if body.hasSuffix("\n") { body.removeLast() }
                    spans.append(Span(body, .codeBlock))
                    i = close + 3
                    textStart = i
                    lineStart = false
                    continue
                }

                if lineStart, matches("> ", at: i) {
                    flushInline(i, into: &self)
                    let end = chars[i...].firstIndex(of: "\n") ?? chars.count
                    parseInline(i + 2, end, base: .quote)
                    if end < chars.count { spans.append(Span("\n")) }
                    i = end + 1
                    textStart = i
                    lineStart = true
                    continue
                }

                lineStart = chars[i] == "\n"
                i += 1
            }
            flushInline(chars.count, into: &self)
        }

        /// Formatting nested deeper than this is shown literally, so a crafted message can't make parsing slow.
        static let maxNesting = 6

        mutating func parseInline(_ start: Int, _ end: Int, base: Style, depth: Int = 0) {
            var i = start
            var buffer = ""
            // Closing delimiters already known to be missing between here and `end`. If one isn't found from
            // position i it can't be found from any later position either, so each is searched for at most once.
            // Without this, text full of unmatched `[`, `<`, `*` or backticks made parsing quadratic.
            var absent: Set<String> = []

            func flush(_ parser: inout Parser) {
                if !buffer.isEmpty {
                    parser.spans.append(Span(buffer, base))
                    buffer = ""
                }
            }

            while i < end {
                let c = chars[i]

                if c == "\\", i + 1 < end, !chars[i + 1].isLetter, !chars[i + 1].isNumber, !chars[i + 1].isWhitespace {
                    buffer.append(chars[i + 1])
                    i += 2
                    continue
                }

                if c == "`" {
                    let ticks = matches("``", at: i) ? 2 : 1
                    let delim = String(repeating: "`", count: ticks)
                    if let close = find(delim, from: i + ticks, before: end, absent: &absent), close > i + ticks {
                        flush(&self)
                        let inner = String(chars[(i + ticks)..<close]).trimmingCharacters(in: .whitespaces)
                        spans.append(Span(inner, base.union(.code)))
                        i = close + ticks
                        continue
                    }
                }

                if depth < Self.maxNesting, let d = delimiter(at: i, end: end),
                   let close = find(d.delim, from: i + d.delim.count, before: end, absent: &absent), close > i + d.delim.count {
                    flush(&self)
                    parseInline(i + d.delim.count, close, base: base.union(d.style), depth: depth + 1)
                    i = close + d.delim.count
                    continue
                }

                // Masked link: [text](https://…). The real host is always shown after the text.
                if c == "[", let link = maskedLink(at: i, end: end, absent: &absent) {
                    flush(&self)
                    spans.append(Span(link.text, base.union(.link), url: link.url.absoluteString))
                    spans.append(Span(" (\(link.url.host ?? "?"))", base.union(.linkHost)))
                    i += link.length
                    continue
                }

                if c == "<", let close = find(">", from: i + 1, before: end, absent: &absent), let span = token(String(chars[(i + 1)..<close]), base: base) {
                    flush(&self)
                    spans.append(span)
                    i = close + 1
                    continue
                }

                if c == "h", let link = url(at: i, end: end) {
                    flush(&self)
                    spans.append(Span(link.url, base.union(.link), url: link.url))
                    i += link.length
                    continue
                }

                buffer.append(c)
                i += 1
            }
            flush(&self)
        }

        /// Paired delimiters, longest first so `**` wins over `*`.
        private func delimiter(at i: Int, end: Int) -> (delim: String, style: Style)? {
            let candidates: [(String, Style)] = [
                ("***", [.bold, .italic]),
                ("**", .bold),
                ("__", .underline),
                ("~~", .strikethrough),
                ("||", .spoiler),
                ("*", .italic),
                ("_", .italic),
            ]
            for (delim, style) in candidates where matches(delim, at: i) {
                let after = i + delim.count
                // "* " is a list bullet, not emphasis.
                guard after < end, !chars[after].isWhitespace else { continue }
                // Underscores inside words (snake_case) aren't emphasis.
                if delim == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { continue }
                return (delim, style)
            }
            return nil
        }

        /// Mentions and custom emoji, written as `<...>`.
        private func token(_ inner: String, base: Style) -> Span? {
            func digits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }

            if inner.hasPrefix("@&"), digits(inner.dropFirst(2)) {
                return Span("@role", base.union(.mention))
            }
            if inner.hasPrefix("@") {
                let id = inner.dropFirst(inner.hasPrefix("@!") ? 2 : 1)
                guard digits(id) else { return nil }
                return Span("@" + (resolver.user(String(id)) ?? "unknown-user"), base.union(.mention))
            }
            if inner.hasPrefix("#"), digits(inner.dropFirst()) {
                let id = String(inner.dropFirst())
                return Span("#" + (resolver.channel(id) ?? "unknown-channel"), base.union(.mention))
            }
            // Custom emoji: <:name:id> or <a:name:id>. Shown as text to avoid fetching images.
            let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0].isEmpty || parts[0] == "a", !parts[1].isEmpty, digits(parts[2]) {
                return Span(":\(parts[1]):", base)
            }
            // Timestamps: <t:1700000000> or <t:1700000000:R>.
            if parts.count >= 2, parts[0] == "t", let seconds = TimeInterval(parts[1]) {
                guard seconds.isFinite, abs(seconds) < 1e11 else { return nil }
                return Span(Markdown.timestampFormatter.string(from: Date(timeIntervalSince1970: seconds)), base.union(.code))
            }
            // Links wrapped in <> to suppress embeds.
            if inner.hasPrefix("http://") || inner.hasPrefix("https://"), !inner.contains(" ") {
                return Span(inner, base.union(.link), url: inner)
            }
            return nil
        }

        private func maskedLink(at i: Int, end: Int, absent: inout Set<String>) -> (text: String, url: URL, length: Int)? {
            guard let middle = find("](", from: i + 1, before: end, absent: &absent), middle > i + 1,
                  let close = find(")", from: middle + 2, before: end, absent: &absent) else { return nil }
            let text = String(chars[(i + 1)..<middle])
            guard !text.contains("\n"), !text.contains("["), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var target = String(chars[(middle + 2)..<close]).trimmingCharacters(in: .whitespaces)
            // Optional title: [text](url "title")
            if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            guard target.hasPrefix("https://") || target.hasPrefix("http://"),
                  let url = URL(string: target), url.host != nil else { return nil }
            return (text, url, close + 1 - i)
        }

        private func url(at i: Int, end: Int) -> (url: String, length: Int)? {
            guard matches("https://", at: i) || matches("http://", at: i) else { return nil }
            var j = i
            while j < end, !chars[j].isWhitespace, chars[j] != "<", chars[j] != ">" { j += 1 }
            // Trailing punctuation usually belongs to the sentence, not the link.
            while j > i, ".,:;!?)\"'".contains(chars[j - 1]) {
                if chars[j - 1] == ")", chars[i..<j].contains("(") { break }
                j -= 1
            }
            let url = String(chars[i..<j])
            guard url.count > 8 else { return nil }
            return (url, j - i)
        }

        private func matches(_ s: String, at i: Int) -> Bool {
            var j = i
            for ch in s {
                guard j < chars.count, chars[j] == ch else { return false }
                j += 1
            }
            return true
        }

        /// `find`, remembering misses: a delimiter missing from `from` to `end` is missing from any later start too.
        private func find(_ s: String, from: Int, before end: Int, absent: inout Set<String>) -> Int? {
            guard !absent.contains(s) else { return nil }
            let found = find(s, from: from, before: end)
            if found == nil { absent.insert(s) }
            return found
        }

        private func find(_ s: String, from: Int, before end: Int? = nil) -> Int? {
            let limit = end ?? chars.count
            guard from <= limit - s.count else { return nil }
            var i = from
            while i <= limit - s.count {
                if matches(s, at: i) { return i }
                i += 1
            }
            return nil
        }
    }
}
