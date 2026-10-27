import XCTest
import Security
@testable import DuhcordCore

final class MarkdownTests: XCTestCase {
    func testPlainText() {
        XCTAssertEqual(Markdown.parse("hello world"), [Markdown.Span("hello world")])
    }

    func testBoldItalicAndCode() {
        let spans = Markdown.parse("a **b** *c* `d`")
        XCTAssertEqual(spans, [
            Markdown.Span("a "),
            Markdown.Span("b", .bold),
            Markdown.Span(" "),
            Markdown.Span("c", .italic),
            Markdown.Span(" "),
            Markdown.Span("d", .code),
        ])
    }

    func testNestedStyles() {
        XCTAssertEqual(Markdown.parse("**bold _both_**"), [
            Markdown.Span("bold ", .bold),
            Markdown.Span("both", [.bold, .italic]),
        ])
    }

    func testUnclosedDelimiterIsLiteral() {
        XCTAssertEqual(Markdown.parse("2 * 3 = 6 and **oops"), [Markdown.Span("2 * 3 = 6 and **oops")])
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertEqual(Markdown.parse("some_variable_name"), [Markdown.Span("some_variable_name")])
    }

    func testCodeBlockDropsLanguageAndKeepsMarkup() {
        let spans = Markdown.parse("look:\n```swift\nlet x = **1**\n```")
        XCTAssertEqual(spans, [
            Markdown.Span("look:\n"),
            Markdown.Span("let x = **1**", .codeBlock),
        ])
    }

    func testQuote() {
        XCTAssertEqual(Markdown.parse("> quoted\nreply"), [
            Markdown.Span("quoted", .quote),
            Markdown.Span("\nreply"),
        ])
    }

    func testMentionsUseResolver() {
        let resolver = Markdown.Resolver(user: { $0 == "1" ? "alice" : nil }, channel: { $0 == "2" ? "general" : nil })
        XCTAssertEqual(Markdown.parse("hi <@1> see <#2>", resolver: resolver), [
            Markdown.Span("hi "),
            Markdown.Span("@alice", .mention),
            Markdown.Span(" see "),
            Markdown.Span("#general", .mention),
        ])
    }

    func testCustomEmojiBecomesText() {
        XCTAssertEqual(Markdown.parse("<:pog:123> <a:dance:456>"), [Markdown.Span(":pog: :dance:")])
    }

    func testLinksStripTrailingPunctuation() {
        XCTAssertEqual(Markdown.parse("see https://example.com/a."), [
            Markdown.Span("see "),
            Markdown.Span("https://example.com/a", .link, url: "https://example.com/a"),
            Markdown.Span("."),
        ])
    }

    func testEscapes() {
        XCTAssertEqual(Markdown.parse("\\*not italic\\*"), [Markdown.Span("*not italic*")])
    }
}

final class DecodingTests: XCTestCase {
    func testReadyWithLegacyAndNestedGuilds() throws {
        let json = """
        {
          "user": {"id": "10", "username": "me", "global_name": "Me"},
          "session_id": "abc",
          "resume_gateway_url": "wss://resume.example",
          "guilds": [
            {"id": "100", "name": "Legacy", "owner_id": "10", "roles": [], "channels": [
              {"id": "101", "type": 0, "name": "general", "position": 0}
            ]},
            {"id": "200", "properties": {"name": "Nested", "owner_id": "99"}, "roles": [], "channels": []},
            {"id": "300", "unavailable": true},
            {"broken": true}
          ],
          "private_channels": [
            {"id": "500", "type": 1, "recipient_ids": ["20"], "last_message_id": "900"}
          ],
          "users": [{"id": "20", "username": "friend"}],
          "read_state": {"entries": [{"id": "500", "last_message_id": 800, "mention_count": 1}]}
        }
        """
        let ready = try makeDiscordDecoder().decode(ReadyEvent.self, from: Data(json.utf8))
        XCTAssertEqual(ready.user.displayName, "Me")
        XCTAssertEqual(ready.guilds.map(\.name), ["Legacy", "Nested", ""])
        XCTAssertEqual(ready.guilds[0].channels.first?.guildId, "100")
        XCTAssertTrue(ready.guilds[2].unavailable)
        XCTAssertEqual(ready.privateChannels.first?.displayName, "friend")
        XCTAssertEqual(ready.readStates.first?.lastMessageId, "800")
    }

    func testMessageWithNumericNonceAndNullReply() throws {
        let json = """
        {"id": "1", "channel_id": "2", "author": {"id": "3", "username": "bob"}, "content": "hi",
         "timestamp": "2024-01-01T12:00:00.000000+00:00", "attachments": [], "nonce": 12345,
         "referenced_message": null}
        """
        let message = try makeDiscordDecoder().decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.nonce, "12345")
        XCTAssertNil(message.referencedMessage)
        XCTAssertNotNil(message.date)
    }
}

final class DateTests: XCTestCase {
    func testParsesDiscordTimestamps() {
        let micro = DiscordDate.parse("2024-01-01T12:00:00.123456+00:00")
        let plain = DiscordDate.parse("2024-01-01T12:00:00+00:00")
        XCTAssertNotNil(micro)
        XCTAssertNotNil(plain)
        XCTAssertEqual(micro!.timeIntervalSince(plain!), 0.123, accuracy: 0.001)
    }
}

final class PermissionTests: XCTestCase {
    private let me: Snowflake = "10"

    private func guild(everyone: UInt64, roles: [Role] = []) -> Guild {
        Guild(id: "1", name: "g", ownerId: "999", roles: [Role(id: "1", permissions: String(everyone))] + roles)
    }

    func testEveryoneCanView() {
        let channel = Channel(id: "5", type: 0)
        XCTAssertTrue(Permissions.canView(channel: channel, guild: guild(everyone: Permissions.viewChannel), userID: me, memberRoles: []))
    }

    func testEveryoneDenyHidesChannel() {
        let deny = PermissionOverwrite(id: "1", type: 0, allow: "0", deny: String(Permissions.viewChannel))
        let channel = Channel(id: "5", type: 0, permissionOverwrites: [deny])
        XCTAssertFalse(Permissions.canView(channel: channel, guild: guild(everyone: Permissions.viewChannel), userID: me, memberRoles: []))
    }

    func testRoleAllowOverridesEveryoneDeny() {
        let overwrites = [
            PermissionOverwrite(id: "1", type: 0, allow: "0", deny: String(Permissions.viewChannel)),
            PermissionOverwrite(id: "7", type: 0, allow: String(Permissions.viewChannel), deny: "0"),
        ]
        let channel = Channel(id: "5", type: 0, permissionOverwrites: overwrites)
        let g = guild(everyone: Permissions.viewChannel, roles: [Role(id: "7", permissions: "0")])
        XCTAssertTrue(Permissions.canView(channel: channel, guild: g, userID: me, memberRoles: ["7"]))
        XCTAssertFalse(Permissions.canView(channel: channel, guild: g, userID: me, memberRoles: []))
    }

    func testAdministratorSeesEverything() {
        let deny = PermissionOverwrite(id: "1", type: 0, allow: "0", deny: String(Permissions.viewChannel))
        let channel = Channel(id: "5", type: 0, permissionOverwrites: [deny])
        let g = guild(everyone: 0, roles: [Role(id: "7", permissions: String(Permissions.administrator))])
        XCTAssertTrue(Permissions.canView(channel: channel, guild: g, userID: me, memberRoles: ["7"]))
    }
}

final class StoreTests: XCTestCase {
    private let me = User(id: "10", username: "me")
    private let other = User(id: "20", username: "other")

    private func message(_ id: String, channel: String = "101", author: User? = nil, content: String = "x",
                         mentions: [User]? = nil) -> Message {
        Message(id: id, channelId: channel, author: author ?? other, content: content,
                timestamp: "2024-01-01T12:00:00Z", mentions: mentions)
    }

    private func readyStore() throws -> Store {
        let json = """
        {
          "user": {"id": "10", "username": "me"},
          "session_id": "s",
          "guilds": [{"id": "100", "name": "G", "roles": [{"id": "100", "permissions": "1024"}], "channels": [
            {"id": "102", "type": 4, "name": "Cat", "position": 0},
            {"id": "101", "type": 0, "name": "general", "position": 0, "last_message_id": "50"},
            {"id": "103", "type": 0, "name": "inside", "position": 1, "parent_id": "102"},
            {"id": "104", "type": 2, "name": "voice", "position": 2}
          ]}],
          "private_channels": [],
          "read_state": [{"id": "101", "last_message_id": "50"}]
        }
        """
        let ready = try makeDiscordDecoder().decode(ReadyEvent.self, from: Data(json.utf8))
        let store = Store(maxCachedChannels: 2, maxMessagesPerChannel: 3)
        store.apply(.ready(ready))
        return store
    }

    func testChannelListGroupsAndFilters() throws {
        let store = try readyStore()
        let names: [String] = store.channelList(guildID: "100").map {
            switch $0 {
            case .category(let c): return "cat:" + c.displayName
            case .channel(let c): return c.displayName
            }
        }
        XCTAssertEqual(names, ["general", "cat:Cat", "inside"])
    }

    func testUnreadAndMentions() throws {
        let store = try readyStore()
        XCTAssertFalse(store.isUnread("101"))
        store.apply(.messageCreate(message("60")))
        XCTAssertTrue(store.isUnread("101"))
        XCTAssertEqual(store.mentionCount("101"), 0)
        store.apply(.messageCreate(message("61", mentions: [me])))
        XCTAssertEqual(store.mentionCount("101"), 1)
        XCTAssertEqual(store.markRead("101"), "61")
        XCTAssertFalse(store.isUnread("101"))
        XCTAssertNil(store.markRead("101"))
    }

    func testOwnMessagesAreRead() throws {
        let store = try readyStore()
        store.apply(.messageCreate(message("60", author: me)))
        XCTAssertFalse(store.isUnread("101"))
    }

    func testHistoryMergesAndCapsMessages() throws {
        let store = try readyStore()
        store.addHistory([message("3"), message("2")], for: "101", requestedLimit: 2)
        XCTAssertFalse(store.hasReachedStart(of: "101"))
        store.addHistory([message("1")], for: "101", requestedLimit: 2)
        XCTAssertTrue(store.hasReachedStart(of: "101"))
        XCTAssertEqual(store.messages(in: "101")?.map(\.id), ["1", "2", "3"])

        store.apply(.messageCreate(message("4")))
        XCTAssertEqual(store.messages(in: "101")?.map(\.id), ["2", "3", "4"])
        XCTAssertFalse(store.hasReachedStart(of: "101"))
    }

    func testCacheEvictsLeastRecentlyUsedChannel() throws {
        let store = try readyStore()
        store.addHistory([message("1", channel: "a")], for: "a", requestedLimit: 50)
        store.addHistory([message("2", channel: "b")], for: "b", requestedLimit: 50)
        store.addHistory([message("3", channel: "c")], for: "c", requestedLimit: 50)
        XCTAssertNil(store.messages(in: "a"))
        XCTAssertNotNil(store.messages(in: "b"))
        XCTAssertNotNil(store.messages(in: "c"))
    }
}

final class RemoteAuthTests: XCTestCase {
    func testPublicKeyIsWrappedAsSubjectPublicKeyInfo() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let spki = try XCTUnwrap(RemoteAuth.subjectPublicKeyInfo(for: publicKey))
        // A 2048-bit RSA SubjectPublicKeyInfo is always 294 bytes and starts with this header.
        XCTAssertEqual(spki.count, 294)
        XCTAssertEqual(Array(spki.prefix(4)), [0x30, 0x82, 0x01, 0x22])
        XCTAssertEqual(Array(spki[4..<19]), [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
    }

    func testDERLengths() {
        XCTAssertEqual(Array(RemoteAuth.der(tag: 0x04, Data([1, 2]))), [0x04, 0x02, 1, 2])
        XCTAssertEqual(Array(RemoteAuth.der(tag: 0x04, Data(count: 300)).prefix(4)), [0x04, 0x82, 0x01, 0x2C])
    }

    func testBase64URLHasNoPadding() {
        XCTAssertEqual(RemoteAuth.base64URL(Data([0xFB, 0xFF])), "-_8")
    }
}

final class SecureSessionTests: XCTestCase {
    func testOnlyDiscordHostsAreAllowed() {
        XCTAssertTrue(SecureSession.isAllowed(host: "discord.com"))
        XCTAssertTrue(SecureSession.isAllowed(host: "gateway.discord.gg"))
        XCTAssertTrue(SecureSession.isAllowed(host: "gateway-us-east1-b.discord.gg"))
        XCTAssertFalse(SecureSession.isAllowed(host: "evil-discord.gg"))
        XCTAssertFalse(SecureSession.isAllowed(host: "discord.com.evil.net"))
        XCTAssertFalse(SecureSession.isAllowed(host: "cdn.discordapp.com"))
        XCTAssertFalse(SecureSession.isAllowed(host: nil))
    }

    /// Network test: the strict trust evaluation must still accept Discord's real certificate.
    func testDiscordCertificateIsAccepted() async throws {
        let url = URL(string: "https://discord.com/api/v9/gateway")!
        let (_, response) = try await SecureSession.shared.session.data(from: url)
        XCTAssertNotNil(response as? HTTPURLResponse)
    }

    /// Network test: any other host is refused before a request is sent.
    func testOtherHostsAreRefused() async {
        do {
            _ = try await SecureSession.shared.session.data(from: URL(string: "https://example.com")!)
            XCTFail("connection to a non-Discord host should fail")
        } catch {
            // Expected.
        }
    }
}

final class MaskedLinkTests: XCTestCase {
    func testMaskedLinkShowsRealHost() {
        XCTAssertEqual(Markdown.parse("see [the docs](https://example.com/a)"), [
            Markdown.Span("see "),
            Markdown.Span("the docs", .link, url: "https://example.com/a"),
            Markdown.Span(" (example.com)", .linkHost),
        ])
    }

    func testMaskedLinkRequiresWebURL() {
        XCTAssertEqual(Markdown.parse("[click](javascript:alert(1))"), [Markdown.Span("[click](javascript:alert(1))")])
    }

    func testDeepNestingIsCapped() {
        let message = String(repeating: "*_", count: 50) + "x" + String(repeating: "_*", count: 50)
        let spans = Markdown.parse(message)
        XCTAssertTrue(spans.contains { $0.text.contains("x") })
    }
}

final class LinkGuardTests: XCTestCase {
    private func check(_ s: String, shown: String? = nil) -> LinkGuard.Verdict {
        LinkGuard.check(URL(string: s)!, shownText: shown)
    }

    func testOrdinaryLinksOpen() {
        XCTAssertEqual(check("https://github.com/C4BRA/duhcord"), .open)
        XCTAssertEqual(check("https://discord.com/channels/1/2"), .open)
        XCTAssertEqual(check("https://cdn.discordapp.com/attachments/1/2/cat.png"), .open)
        XCTAssertEqual(check("https://disco.example"), .open)
    }

    func testQRLoginLinksAreBlocked() {
        guard case .block = check("https://discord.com/ra/abc123") else { return XCTFail() }
    }

    func testNonWebLinksAreBlocked() {
        guard case .block = check("file:///etc/passwd") else { return XCTFail() }
    }

    func testOAuthAuthorizeWarnsAndExplainsAdministrator() {
        let verdict = check("https://discord.com/oauth2/authorize?client_id=1&scope=bot%20guilds.join&permissions=8")
        guard case .warn(let reasons) = verdict else { return XCTFail() }
        XCTAssertTrue(reasons.contains { $0.contains("ADMINISTRATOR") })
        XCTAssertTrue(reasons.contains { $0.contains("join servers") })
        guard case .warn = check("https://discord.com/api/oauth2/authorize?client_id=1&scope=identify") else { return XCTFail() }
    }

    func testLookalikeDomainsWarn() {
        for host in ["https://dlscord.com/gift", "https://discrod.gift/x", "https://discord-nitro.ru", "https://d1scord.app"] {
            guard case .warn = check(host) else { return XCTFail(host) }
        }
    }

    func testMaskedLinkPointingElsewhereWarns() {
        guard case .warn = check("https://evil.example/login", shown: "discord.com/nitro") else { return XCTFail() }
        XCTAssertEqual(check("https://www.github.com/x", shown: "github.com"), .open)
        XCTAssertEqual(check("https://evil.example", shown: "click here"), .open)
    }
}

final class GatewayPayloadTests: XCTestCase {
    func testGuildSubscriptionUsesBulkOpcodeWithTyping() throws {
        let payload = GatewayClient.subscriptionPayload(guildID: "123")
        XCTAssertEqual(payload["op"] as? Int, 37)
        let d = try XCTUnwrap(payload["d"] as? [String: Any])
        let subscriptions = try XCTUnwrap(d["subscriptions"] as? [String: Any])
        let options = try XCTUnwrap(subscriptions["123"] as? [String: Any])
        XCTAssertEqual(options["typing"] as? Bool, true)
        XCTAssertEqual(options["threads"] as? Bool, false)
        XCTAssertEqual(options["member_updates"] as? Bool, false)
        XCTAssertNil(options["channels"], "member-list ranges would stream the whole sidebar")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }
}
