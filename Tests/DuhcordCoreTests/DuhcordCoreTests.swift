import XCTest
import CryptoKit
import Security
@testable import DuhcordUpdateKit
@testable import DuhcordCore
@testable import DuhcordVoiceKit

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
            case .voiceChannel(let c): return "voice:" + c.displayName
            }
        }
        // Voice channels come after text channels in their group.
        XCTAssertEqual(names, ["general", "voice:voice", "cat:Cat", "inside"])
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

final class GatewayReconnectTests: XCTestCase {
    func testReconnectDelay() {
        XCTAssertEqual(GatewayClient.reconnectDelay(attempt: 1, random: 0), 1)
        XCTAssertEqual(GatewayClient.reconnectDelay(attempt: 1, random: 1), 2)
        XCTAssertEqual(GatewayClient.reconnectDelay(attempt: 10, random: 0), 30)
        XCTAssertEqual(GatewayClient.reconnectDelay(attempt: 10, random: 1), 60)

        let delays = (1...10).map { GatewayClient.reconnectDelay(attempt: $0, random: 1) }
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(delays.suffix(5), Array(repeating: 60, count: 5))
    }
}


final class UpdateVerifierTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var keys: [String] { [key.publicKey.rawRepresentation.base64EncodedString()] }

    private func manifest(version: String = "1.2.0", url: String = "https://github.com/C4BRA/duhcord/releases/download/v1.2.0/Duhcord.zip",
                          size: Int = 1000, minimumSystemVersion: String? = "13.0") -> Data {
        let m = UpdateManifest(version: version, url: url, sha256: String(repeating: "a", count: 64), size: size,
                               minimumSystemVersion: minimumSystemVersion, notes: "Fixes")
        return try! JSONEncoder().encode(m)
    }

    private func sign(_ data: Data, with signer: Curve25519.Signing.PrivateKey? = nil) -> Data {
        Data(try! (signer ?? key).signature(for: data).base64EncodedString().utf8)
    }

    func testValidManifestVerifies() throws {
        let data = manifest()
        let parsed = try UpdateVerifier.verify(manifest: data, signature: sign(data), keys: keys)
        XCTAssertEqual(parsed.version, "1.2.0")
    }

    func testTamperedManifestIsRejected() {
        var data = manifest()
        let signature = sign(data)
        data[data.startIndex + 5] ^= 0x01
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: data, signature: signature, keys: keys)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
    }

    func testOtherKeyIsRejected() {
        let data = manifest()
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: data, signature: sign(data, with: .init()), keys: keys)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
    }

    func testNoKeysMeansUpdatesAreOff() {
        let data = manifest()
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: data, signature: sign(data), keys: [])) {
            XCTAssertEqual($0 as? UpdateError, .notConfigured)
        }
    }

    func testSignedButForeignURLIsRejected() {
        let data = manifest(url: "https://evil.example/Duhcord.zip")
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: data, signature: sign(data), keys: keys)) {
            XCTAssertEqual($0 as? UpdateError, .wrongSource)
        }
    }

    func testOversizedArchiveIsRejected() {
        let data = manifest(size: UpdateKit.maxArchiveSize + 1)
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: data, signature: sign(data), keys: keys)) {
            XCTAssertEqual($0 as? UpdateError, .tooLarge)
        }
    }

    func testGarbageIsNeverParsedWithoutSignature() {
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: Data("{not json".utf8), signature: Data("AAAA".utf8), keys: keys)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
    }

    func testDowngradesAndSameVersionAreRejected() throws {
        // Encode once: JSON key order can differ between encodes, and the signature covers the exact bytes.
        let data = manifest(version: "1.2.0")
        let m = try UpdateVerifier.verify(manifest: data, signature: sign(data), keys: keys)
        XCTAssertNoThrow(try UpdateVerifier.checkApplicable(m, installedVersion: "1.1.9"))
        XCTAssertThrowsError(try UpdateVerifier.checkApplicable(m, installedVersion: "1.2.0"))
        XCTAssertThrowsError(try UpdateVerifier.checkApplicable(m, installedVersion: "1.10.0"))
    }

    func testMinimumSystemVersionIsEnforced() throws {
        let data = manifest(minimumSystemVersion: "99.0")
        let m = try UpdateVerifier.verify(manifest: data, signature: sign(data), keys: keys)
        XCTAssertThrowsError(try UpdateVerifier.checkApplicable(m, installedVersion: "1.0.0")) {
            XCTAssertEqual($0 as? UpdateError, .systemTooOld("99.0"))
        }
    }

    func testVersionOrdering() {
        XCTAssertTrue(Version("1.10.0")! > Version("1.9.9")!)
        XCTAssertTrue(Version("v2")! > Version("1.99")!)
        XCTAssertEqual(Version("1.2")!, Version("1.2.0")!)
        XCTAssertNil(Version("1.2-beta"))
        XCTAssertNil(Version(""))
    }

    func testHashStopsAtLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: 5000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = try UpdateVerifier.hash(try FileHandle(forReadingFrom: url), limit: 5000)
        XCTAssertEqual(ok.size, 5000)
        XCTAssertEqual(ok.sha256, SHA256.hash(data: Data(repeating: 7, count: 5000)).map { String(format: "%02x", $0) }.joined())
        XCTAssertThrowsError(try UpdateVerifier.hash(try FileHandle(forReadingFrom: url), limit: 4999))
    }

    func testUpdateSessionOnlyAllowsGitHubReleaseHosts() {
        XCTAssertTrue(SecureSession.isUpdateHost("github.com"))
        XCTAssertTrue(SecureSession.isUpdateHost("release-assets.githubusercontent.com"))
        XCTAssertFalse(SecureSession.isUpdateHost("discord.com"))
        XCTAssertFalse(SecureSession.isUpdateHost("evil-github.com"))
        XCTAssertFalse(SecureSession.isAllowed(host: "github.com"))
    }
}

final class EmbedTests: XCTestCase {
    func testMessageWithEmbedsAndImageAttachment() throws {
        let json = """
        {"id": "1", "channel_id": "2", "author": {"id": "3", "username": "bob"}, "content": "look",
         "timestamp": "2024-01-01T12:00:00Z",
         "attachments": [{"id": "9", "filename": "SPOILER_cat.png", "url": "https://cdn.discordapp.com/a/cat.png",
                          "proxy_url": "https://media.discordapp.net/a/cat.png", "content_type": "image/png", "width": 800, "height": 600}],
         "embeds": [
           {"type": "article", "title": "A page", "description": "About **things**", "url": "https://example.com", "color": 16711680,
            "provider": {"name": "Example"}, "thumbnail": {"url": "https://example.com/t.png",
            "proxy_url": "https://images-ext-1.discordapp.net/external/abc/https/example.com/t.png", "width": 200, "height": 100}},
           {"type": "rich", "fields": "broken"},
           {"type": "gifv", "url": "https://tenor.com/x", "video": {"url": "https://media.tenor.com/x.mp4"},
            "thumbnail": {"proxy_url": "https://images-ext-2.discordapp.net/external/x", "width": 498, "height": 280}}
         ]}
        """
        let message = try makeDiscordDecoder().decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.embeds.count, 2, "the malformed embed is skipped, not the message")
        XCTAssertEqual(message.embeds[0].title, "A page")
        XCTAssertTrue(message.embeds[0].hasText)
        XCTAssertTrue(message.embeds[1].isMediaOnly)
        XCTAssertTrue(message.embeds[1].isVideo)
        XCTAssertTrue(message.attachments[0].isImage)
        XCTAssertTrue(message.attachments[0].isSpoiler)
    }

    func testMediaHostsAreDiscordProxiesOnly() {
        XCTAssertTrue(MediaRequest.isAllowedHost("media.discordapp.net"))
        XCTAssertTrue(MediaRequest.isAllowedHost("images-ext-2.discordapp.net"))
        XCTAssertFalse(MediaRequest.isAllowedHost("cdn.discordapp.com"))
        XCTAssertFalse(MediaRequest.isAllowedHost("images-ext-evil.discordapp.net"))
        XCTAssertFalse(MediaRequest.isAllowedHost("example.com"))
        XCTAssertNil(MediaRequest.url(proxy: "https://example.com/a.png", pixelWidth: 10, pixelHeight: 10))
    }

    func testRequestAsksForExactSizeAndKeepsSignature() throws {
        let url = try XCTUnwrap(MediaRequest.url(proxy: "https://media.discordapp.net/a/cat.png?ex=1&hm=abc&width=5",
                                                 pixelWidth: 720, pixelHeight: 540))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        XCTAssertEqual(dict["ex"], "1")
        XCTAssertEqual(dict["hm"], "abc")
        XCTAssertEqual(dict["width"], "720")
        XCTAssertEqual(dict["height"], "540")
        XCTAssertEqual(dict["format"], "webp")
        XCTAssertEqual(items.filter { $0.name == "width" }.count, 1)
    }

    func testFitNeverEnlarges() {
        XCTAssertTrue(MediaRequest.fit(width: 800, height: 600, maxWidth: 360, maxHeight: 270) == (360, 270))
        XCTAssertTrue(MediaRequest.fit(width: 100, height: 50, maxWidth: 360, maxHeight: 270) == (100, 50))
        XCTAssertTrue(MediaRequest.fit(width: 1000, height: 100, maxWidth: 360, maxHeight: 270) == (360, 36))
    }

    func testEmbedsArriveInMessageUpdates() throws {
        let store = Store()
        let author = User(id: "3", username: "bob")
        store.addHistory([Message(id: "1", channelId: "c", author: author, content: "https://example.com", timestamp: "")],
                         for: "c", requestedLimit: 50)
        let update = try makeDiscordDecoder().decode(MessageUpdate.self, from: Data("""
        {"id": "1", "channel_id": "c", "embeds": [{"type": "link", "title": "Example"}]}
        """.utf8))
        store.apply(.messageUpdate(update))
        XCTAssertEqual(store.messages(in: "c")?.first?.embeds.first?.title, "Example")
    }
}

final class VideoTests: XCTestCase {
    func testPlayableVideosAndGIFs() throws {
        let gifv = Embed(type: "gifv", url: "https://tenor.com/x",
                         thumbnail: EmbedMedia(url: nil, proxyUrl: "https://images-ext-1.discordapp.net/t", width: 400, height: 300),
                         video: EmbedMedia(url: "https://media.tenor.com/x.mp4",
                                           proxyUrl: "https://images-ext-1.discordapp.net/external/x/media.tenor.com/x.mp4",
                                           width: 400, height: 300))
        XCTAssertNotNil(gifv.playableVideoURL)
        let youtube = Embed(type: "video", url: "https://youtube.com/watch?v=1",
                            video: EmbedMedia(url: "https://www.youtube.com/embed/1", proxyUrl: nil, width: 1280, height: 720))
        XCTAssertNil(youtube.playableVideoURL, "YouTube has no stream; it opens in the browser")

        let mp4 = Attachment(id: "1", filename: "clip.mp4", url: "https://cdn.discordapp.com/a/clip.mp4",
                             proxyUrl: "https://media.discordapp.net/a/clip.mp4", contentType: "video/mp4", width: 1920, height: 1080)
        XCTAssertTrue(mp4.isPlayableVideo)
        let webm = Attachment(id: "2", filename: "clip.webm", url: "https://cdn.discordapp.com/a/clip.webm",
                              contentType: "video/webm", width: 640, height: 360)
        XCTAssertFalse(webm.isPlayableVideo)
        let gif = Attachment(id: "3", filename: "a.gif", url: "https://cdn.discordapp.com/a/a.gif", contentType: "image/gif", width: 100, height: 100)
        XCTAssertTrue(gif.isGIF && gif.isImage)
    }

    func testVideoHostsIncludeDiscordCDNOnly() {
        XCTAssertTrue(MediaRequest.isAllowedVideoURL(URL(string: "https://cdn.discordapp.com/attachments/1/2/a.mp4")!))
        XCTAssertTrue(MediaRequest.isAllowedVideoURL(URL(string: "https://media.discordapp.net/attachments/1/2/a.mp4")!))
        XCTAssertFalse(MediaRequest.isAllowedVideoURL(URL(string: "https://media.tenor.com/x.mp4")!))
        XCTAssertFalse(MediaRequest.isAllowedVideoURL(URL(string: "http://cdn.discordapp.com/attachments/1/2/a.mp4")!))
        XCTAssertFalse(MediaRequest.isAllowedHost("cdn.discordapp.com"), "still images keep coming from the re-encoding proxy only")
    }

    func testAnimatedRequestKeepsOriginalFormat() throws {
        let url = try XCTUnwrap(MediaRequest.url(proxy: "https://media.discordapp.net/a/a.gif", pixelWidth: 200, pixelHeight: 100, format: nil))
        XCTAssertFalse(url.absoluteString.contains("format="))
        XCTAssertTrue(url.absoluteString.contains("width=200"))
    }
}

final class TypingTrackerTests: XCTestCase {
    private let alice = User(id: "1", username: "alice")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRaiseLowerAndExpire() {
        let tracker = TypingTracker()
        tracker.focus("c")
        XCTAssertTrue(tracker.typing(alice, name: "Alice", in: "c", at: t0))
        XCTAssertFalse(tracker.typing(alice, name: "Alice", in: "other", at: t0), "other channels are ignored")
        XCTAssertEqual(tracker.nextDeadline, t0.addingTimeInterval(10))

        // Still typing at 9 s: stays raised.
        XCTAssertFalse(tracker.tick(at: t0.addingTimeInterval(9)))
        XCTAssertTrue(tracker.entries[0].raised)

        // Silent for 10 s: lowers halfway.
        XCTAssertTrue(tracker.tick(at: t0.addingTimeInterval(10)))
        XCTAssertFalse(tracker.entries[0].raised)
        XCTAssertEqual(tracker.nextDeadline, t0.addingTimeInterval(70))

        // Gone a minute after lowering.
        XCTAssertFalse(tracker.tick(at: t0.addingTimeInterval(69)))
        XCTAssertTrue(tracker.tick(at: t0.addingTimeInterval(70)))
        XCTAssertTrue(tracker.entries.isEmpty)
        XCTAssertNil(tracker.nextDeadline)
    }

    func testMessageLowersAndTypingAgainRaises() {
        let tracker = TypingTracker()
        tracker.focus("c")
        tracker.typing(alice, name: "Alice", in: "c", at: t0)
        XCTAssertTrue(tracker.messageArrived(from: "1", in: "c", at: t0.addingTimeInterval(3)))
        XCTAssertFalse(tracker.entries[0].raised)
        XCTAssertTrue(tracker.typing(alice, name: "Alice", in: "c", at: t0.addingTimeInterval(5)))
        XCTAssertTrue(tracker.entries[0].raised)
        XCTAssertNil(tracker.entries[0].loweredAt)
    }

    func testSwitchingChannelsClears() {
        let tracker = TypingTracker()
        tracker.focus("c")
        tracker.typing(alice, name: "Alice", in: "c", at: t0)
        XCTAssertTrue(tracker.focus("d"))
        XCTAssertTrue(tracker.entries.isEmpty)
    }

    func testTypingStartDecodes() throws {
        let json = """
        {"channel_id": "c", "guild_id": "g", "user_id": "1", "timestamp": 1700000000,
         "member": {"nick": "Al", "roles": [], "user": {"id": "1", "username": "alice", "avatar": "abc"}}}
        """
        let event = try makeDiscordDecoder().decode(TypingStart.self, from: Data(json.utf8))
        XCTAssertEqual(event.member?.nick, "Al")
        XCTAssertEqual(event.member?.user?.avatar, "abc")
    }
}

final class AvatarTests: XCTestCase {
    func testAvatarAndIconURLs() {
        let user = User(id: "80351110224678912", username: "nelly", avatar: "8342729096ea3675442027381ff50dfe")
        XCTAssertEqual(MediaRequest.avatarURL(for: user, pixels: 64)?.absoluteString,
                       "https://cdn.discordapp.com/avatars/80351110224678912/8342729096ea3675442027381ff50dfe.webp?size=64")
        XCTAssertEqual(MediaRequest.avatarURL(for: User(id: "1", username: "old", discriminator: "1337"), pixels: 64)?.absoluteString,
                       "https://cdn.discordapp.com/embed/avatars/2.png")
        let guild = Guild(id: "9", name: "g", icon: "abc")
        XCTAssertEqual(MediaRequest.iconURL(for: guild, pixels: 80)?.absoluteString, "https://cdn.discordapp.com/icons/9/abc.webp?size=128")
        XCTAssertNil(MediaRequest.iconURL(for: Guild(id: "9", name: "g"), pixels: 80))
    }

    func testCDNIsLimitedToAvatarsAndIcons() {
        XCTAssertTrue(MediaRequest.isAllowedImageURL(URL(string: "https://cdn.discordapp.com/avatars/1/a.webp?size=64")!))
        XCTAssertTrue(MediaRequest.isAllowedImageURL(URL(string: "https://cdn.discordapp.com/embed/avatars/3.png")!))
        XCTAssertFalse(MediaRequest.isAllowedImageURL(URL(string: "https://cdn.discordapp.com/attachments/1/2/raw.png")!))
        XCTAssertFalse(MediaRequest.isAllowedImageURL(URL(string: "http://cdn.discordapp.com/avatars/1/a.webp")!))
        XCTAssertEqual(MediaRequest.cdnSize(forPixels: 80), 128)
        XCTAssertEqual(MediaRequest.cdnSize(forPixels: 64), 64)
    }
}

final class MarkdownPerformanceTests: XCTestCase {
    /// Unmatched openers used to rescan to the end each time (quadratic). This must stay fast.
    func testUnmatchedOpenersStayLinear() {
        let hostile = String(repeating: "[<*`~|_", count: 3000)
        let start = Date()
        _ = Markdown.parse(hostile)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}

final class LinkGuardNormalizationTests: XCTestCase {
    func testDotSegmentsDontBypassChecks() {
        for link in ["https://discord.com/./ra/abc", "https://discord.com/x/../ra/abc", "https://discord.com//ra/abc"] {
            guard case .block = LinkGuard.check(URL(string: link)!) else { return XCTFail(link) }
        }
        guard case .warn = LinkGuard.check(URL(string: "https://discord.com/oauth2/authorize/.?client_id=1&scope=bot")!) else { return XCTFail() }
        guard case .warn = LinkGuard.check(URL(string: "https://discord.com/api/v10/oauth2/authorize?client_id=1&scope=identify")!) else { return XCTFail() }
    }
}

final class ZlibStreamTests: XCTestCase {
    // Two gateway messages from one zlib stream, each ended with a sync flush (recorded with Python's zlib).
    private let hello = Data(base64Encoded: "eJyqVsovULIyNNBRSlGyqlbKSE0sKklKTSyJz8wrSS0qS8xRsjIxNDI1qK0FAAAA//8=")!
    private let ack = Data(base64Encoded: "qlYqUbLKK83J0VEqhjHAeg3BekECtQAAAAD//w==")!

    func testMessagesShareOneStream() throws {
        let stream = ZlibStream(maxMessageSize: 1024)
        XCTAssertEqual(try stream.push(hello).map { String(decoding: $0, as: UTF8.self) },
                       #"{"op":10,"d":{"heartbeat_interval":41250}}"#)
        // The second message refers back to the first, so it only decodes on the same stream.
        XCTAssertEqual(try stream.push(ack).map { String(decoding: $0, as: UTF8.self) },
                       #"{"t":null,"s":null,"op":11,"d":null}"#)
    }

    func testMessageSplitAcrossFrames() throws {
        let stream = ZlibStream(maxMessageSize: 1024)
        let cut = hello.count / 2
        XCTAssertNil(try stream.push(hello.prefix(cut)))
        XCTAssertEqual(try stream.push(hello.dropFirst(cut)).map { String(decoding: $0, as: UTF8.self) },
                       #"{"op":10,"d":{"heartbeat_interval":41250}}"#)
    }

    func testOversizedMessageIsRefused() {
        let stream = ZlibStream(maxMessageSize: 10)
        XCTAssertThrowsError(try stream.push(hello))
    }

    func testGarbageIsRefused() {
        let stream = ZlibStream(maxMessageSize: 1024)
        XCTAssertThrowsError(try stream.push(Data([0x12, 0x34, 0x56, 0x00, 0x00, 0xFF, 0xFF])))
    }

    func testGatewayAsksForCompression() {
        XCTAssertTrue(ClientIdentity.gatewayURL.absoluteString.hasSuffix("compress=zlib-stream"))
    }
}

final class VoiceTransportTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    func testHChaCha20MatchesTheSpec() {
        // draft-irtf-cfrg-xchacha-03, section 2.2.1.
        let subkey = TransportCipher.hChaCha20(key: Array(0..<32), nonce: bytes("000000090000004a0000000031415927"))
        XCTAssertEqual(subkey, bytes("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"))
    }

    // Packets sealed independently with Python's `cryptography` (key 0…31, nonce counter 7).
    private let header = [UInt8]([0x80, 0x78, 0x00, 0x01, 0x00, 0x00, 0x09, 0x60, 0x00, 0x00, 0x04, 0xD2])
    private let payload = Array("opus frame".utf8)

    func testXChaChaSealsLikeAReferenceImplementation() throws {
        let cipher = try XCTUnwrap(TransportCipher(mode: .xChaCha20Poly1305, secretKey: Array(0..<32)))
        let sealed = try cipher.seal(payload, header: header, nonce: 7)
        XCTAssertEqual(sealed, bytes("d9c7284458a4db2aba26d6bf292ddd387623305fa3e0b30fb6f4") + [0, 0, 0, 7])
        XCTAssertEqual(cipher.open(sealed[...], header: header[...]), payload)
    }

    func testAESGCMSealsLikeAReferenceImplementation() throws {
        let cipher = try XCTUnwrap(TransportCipher(mode: .aes256GCM, secretKey: Array(0..<32)))
        let sealed = try cipher.seal(payload, header: header, nonce: 7)
        XCTAssertEqual(sealed, bytes("3097a1f25a4e51ea82b78bbffab65b56ccabcc78e02a4c56bc38") + [0, 0, 0, 7])
        XCTAssertEqual(cipher.open(sealed[...], header: header[...]), payload)
    }

    func testTamperedPacketsAreRejected() throws {
        let cipher = try XCTUnwrap(TransportCipher(mode: .aes256GCM, secretKey: Array(0..<32)))
        var packet = try RTP.seal(payload, sequence: 1, timestamp: 2400, ssrc: 1234, nonce: 7, cipher: cipher)
        XCTAssertEqual(RTP.open(packet, cipher: cipher)?.payload, payload)
        packet[13] ^= 1
        XCTAssertNil(RTP.open(packet, cipher: cipher))
    }

    func testRTPRoundTripKeepsHeaderFields() throws {
        let cipher = try XCTUnwrap(TransportCipher(mode: .xChaCha20Poly1305, secretKey: Array(0..<32)))
        let packet = try RTP.seal(payload, sequence: 513, timestamp: 96_000, ssrc: 77, nonce: 1, cipher: cipher)
        let opened = try XCTUnwrap(RTP.open(packet, cipher: cipher))
        XCTAssertEqual(opened, RTP.Packet(sequence: 513, timestamp: 96_000, ssrc: 77, payload: payload))
    }

    func testRTCPAndShortPacketsAreIgnored() throws {
        let cipher = try XCTUnwrap(TransportCipher(mode: .aes256GCM, secretKey: Array(0..<32)))
        XCTAssertNil(RTP.open([0x81, 0xC9] + [UInt8](repeating: 0, count: 40), cipher: cipher))
        XCTAssertNil(RTP.open([0x80, 0x78, 0, 1], cipher: cipher))
    }

    func testRTPWithExtensionStripsTheEncryptedExtensionBody() throws {
        let cipher = try XCTUnwrap(TransportCipher(mode: .aes256GCM, secretKey: Array(0..<32)))
        // Header with the extension bit, then the extension preamble (profile 0xBEDE, one 32-bit word).
        let clear: [UInt8] = [0x90, 0x78, 0, 5, 0, 0, 0, 1, 0, 0, 0, 9, 0xBE, 0xDE, 0x00, 0x01]
        let body: [UInt8] = [1, 2, 3, 4] + payload
        let packet = clear + (try cipher.seal(body, header: clear, nonce: 3))
        XCTAssertEqual(RTP.open(packet, cipher: cipher)?.payload, payload)
    }

    func testIPDiscovery() {
        let request = IPDiscovery.request(ssrc: 0x0102_0304)
        XCTAssertEqual(request.count, 74)
        XCTAssertEqual(Array(request[0..<8]), [0, 1, 0, 70, 1, 2, 3, 4])
        var response = [UInt8](repeating: 0, count: 74)
        response[1] = 2
        response.replaceSubrange(8..<19, with: Array("203.0.113.5".utf8))
        response[72] = 0xC3
        response[73] = 0x50
        XCTAssertEqual(IPDiscovery.parse(response)?.address, "203.0.113.5")
        XCTAssertEqual(IPDiscovery.parse(response)?.port, 50_000)
        XCTAssertNil(IPDiscovery.parse(Array(response.prefix(20))))
    }

    func testBinaryVoiceMessages() {
        let message = VoiceBinaryMessage([0x00, 0x2A, 29, 0x01, 0x02, 0xAA, 0xBB])
        XCTAssertEqual(message?.sequence, 42)
        XCTAssertEqual(message?.opcode, 29)
        XCTAssertEqual(message?.transition?.id, 0x0102)
        XCTAssertEqual(message?.transition?.body, [0xAA, 0xBB])
        XCTAssertNil(VoiceBinaryMessage([0x00, 0x01]))
        XCTAssertEqual(VoiceBinaryMessage.outgoing(opcode: 26, payload: [9, 8]), Data([26, 9, 8]))
    }

    func testModePreference() {
        XCTAssertEqual(TransportCipher.Mode.preferred(from: ["aead_xchacha20_poly1305_rtpsize", "aead_aes256_gcm_rtpsize"]), .aes256GCM)
        XCTAssertEqual(TransportCipher.Mode.preferred(from: ["aead_xchacha20_poly1305_rtpsize"]), .xChaCha20Poly1305)
        XCTAssertNil(TransportCipher.Mode.preferred(from: ["xsalsa20_poly1305"]))
    }

    func testVoiceHostsAreDiscordsOnly() {
        XCTAssertTrue(SecureSession.isVoiceHost("sweetwater-12345.discord.media"))
        XCTAssertFalse(SecureSession.isVoiceHost("discord.media.evil.com"))
        XCTAssertFalse(SecureSession.isVoiceHost("discord.com"))
        XCTAssertFalse(SecureSession.isVoiceHost(nil))
    }

    func testStoreTracksVoiceChannelMembers() throws {
        let store = Store()
        let json = """
        {"user": {"id": "1", "username": "me"}, "session_id": "s", "guilds": [{"id": "100", "name": "g",
          "channels": [{"id": "200", "type": 2, "name": "Lounge"}],
          "voice_states": [{"user_id": "5", "channel_id": "200", "self_mute": true}]}],
         "private_channels": [], "read_state": []}
        """
        store.apply(.ready(try makeDiscordDecoder().decode(ReadyEvent.self, from: Data(json.utf8))))
        XCTAssertEqual(store.voiceStates(in: "200", guildID: "100").map(\.userId), ["5"])
        XCTAssertTrue(store.voiceStates(in: "200", guildID: "100")[0].selfMute)
        store.apply(.voiceStateUpdate(VoiceState(guildId: "100", channelId: "200", userId: "1")))
        XCTAssertEqual(store.myVoiceState(in: "100")?.channelId, "200")
        store.apply(.voiceStateUpdate(VoiceState(guildId: "100", channelId: nil, userId: "5")))
        XCTAssertEqual(store.voiceStates(in: "200", guildID: "100").map(\.userId), ["1"])
    }

    func testMemberNamesFromChunksAndVoiceStates() throws {
        let store = Store()
        let chunk = """
        {"guild_id": "100", "members": [
          {"user": {"id": "5", "username": "five", "global_name": "Five"}, "roles": [], "nick": "Fiver"},
          {"user": {"id": "6", "username": "six"}, "roles": []},
          {"broken": true}]}
        """
        store.apply(.guildMembersChunk(try makeDiscordDecoder().decode(GuildMembersChunk.self, from: Data(chunk.utf8))))
        XCTAssertEqual(store.memberName("5", in: "100"), "Fiver")
        XCTAssertEqual(store.memberName("6", in: "100"), "six")
        XCTAssertNil(store.memberName("5", in: "999"))

        let voice = """
        {"guild_id": "100", "channel_id": "200", "user_id": "7", "session_id": "x",
         "member": {"user": {"id": "7", "username": "seven"}, "roles": []}}
        """
        store.apply(.voiceStateUpdate(try makeDiscordDecoder().decode(VoiceState.self, from: Data(voice.utf8))))
        XCTAssertEqual(store.memberName("7", in: "100"), "seven")
    }

    func testPrivacyCodeFormat() {
        // Six groups of five bytes, big-endian, modulo 100000, zero-padded; extra bytes are ignored.
        XCTAssertEqual(PrivacyCode.format(Array(0..<32)), "09060 60585 12110 63635 15160 66685")
        XCTAssertEqual(PrivacyCode.format([UInt8](repeating: 0xff, count: 30)), "27775 27775 27775 27775 27775 27775")
        XCTAssertNil(PrivacyCode.format(Array(0..<29)))
    }

    func testVoiceStatsSummaryAndEncoding() throws {
        let stats = VoiceStats(server: "c-ord12-816a989c", pings: [.init(age: 20, milliseconds: 40), .init(age: 5, milliseconds: 60)],
                               packetsReceived: 990, packetsLost: 10, packetsSent: 5, unreadable: 0, undecryptable: 0,
                               endToEndEncrypted: true, transport: "AES-256-GCM", daveProtocolVersion: 1,
                               privacyCode: nil, microphone: "MacBook Pro Microphone", output: nil)
        XCTAssertEqual(stats.lossPercent, 1, accuracy: 0.0001)
        XCTAssertEqual(stats.averagePing, 50)
        let event = VoiceEvent.stats(stats)
        XCTAssertEqual(try JSONDecoder().decode(VoiceEvent.self, from: JSONEncoder().encode(event)), event)

        let empty = VoiceStats(server: "", pings: [], packetsReceived: 0, packetsLost: 0, packetsSent: 0, unreadable: 0,
                               undecryptable: 0, endToEndEncrypted: false, transport: "", daveProtocolVersion: 0,
                               privacyCode: nil, microphone: nil, output: nil)
        XCTAssertEqual(empty.lossPercent, 0)
        XCTAssertNil(empty.averagePing)
    }
}

final class ProfileTests: XCTestCase {
    private let decoder = makeDiscordDecoder()

    func testProfilePrefersServerProfileAndReadsMutualsAndWidgets() throws {
        let json = """
        {"user": {"id": "80351110224678912", "username": "nelly", "global_name": "Nelly", "avatar": "a1", "bio": "x"},
         "user_profile": {"bio": "Account bio", "pronouns": "she/her", "banner": "b1", "accent_color": 16711680},
         "guild_member": {"roles": ["10", "11"], "nick": "Nel", "avatar": null, "banner": null,
                          "joined_at": "2020-01-01T00:00:00.000000+00:00"},
         "guild_member_profile": {"guild_id": "9", "bio": "Server bio", "pronouns": ""},
         "badges": [{"id": "hypesquad_house_1", "description": "HypeSquad Bravery", "icon": "8a88d63823d8a71cd5e390baa45efa02"}],
         "guild_badges": [],
         "mutual_guilds": [{"id": "9", "nick": "Nel"}, {"id": "10", "nick": null}],
         "mutual_friends": [{"id": "5", "username": "five"}], "mutual_friends_count": 1,
         "widgets": [{"id": "1", "updated_at": "2025-12-31T12:04:11.252336+00:00",
                      "data": {"type": "favorite_games", "games": [{"game_id": "505", "comment": "Best", "tags": ["expert", "open_to_teach"]}]}},
                     {"id": "2", "data": {"type": "application", "application_id": "606"}},
                     {"id": "3", "data": {"broken": true}}],
         "connected_accounts": [], "premium_type": null, "premium_since": null, "premium_guild_since": null}
        """
        let profile = try decoder.decode(UserProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.displayName, "Nel")
        XCTAssertEqual(profile.bio, "Server bio")
        // An empty server value falls back to the account's.
        XCTAssertEqual(profile.pronouns, "she/her")
        XCTAssertEqual(profile.accentColor, 0xFF0000)
        XCTAssertEqual(profile.guildMember?.roles, ["10", "11"])
        XCTAssertEqual(profile.mutualGuilds?.map(\.id), ["9", "10"])
        XCTAssertEqual(profile.friendsInCommon, 1)
        XCTAssertEqual(profile.badges.first?.description, "HypeSquad Bravery")
        XCTAssertEqual(profile.widgets.count, 2)
        XCTAssertEqual(profile.widgets[0].title, "Favorite Game")
        XCTAssertTrue(profile.widgets[0].isDetailed)
        XCTAssertEqual(profile.widgets[0].games.first?.tags, ["expert", "open_to_teach"])
        XCTAssertEqual(profile.widgets[1].applicationId, "606")
        XCTAssertEqual(ProfileWidget.tagTitle("looking_for_group"), "Looking For Group")

        let banner = MediaRequest.bannerURL(for: profile, guildID: "9", pixels: 600)
        XCTAssertEqual(banner?.absoluteString, "https://cdn.discordapp.com/banners/80351110224678912/b1.webp?size=1024")
        XCTAssertTrue(MediaRequest.isAllowedImageURL(banner!))
    }

    func testBlockedOrPrivateProfileStillDecodes() throws {
        let json = """
        {"user": {"id": "1", "username": "someone"}, "user_profile": null, "badges": null, "mutual_guilds": "nonsense"}
        """
        let profile = try decoder.decode(UserProfile.self, from: Data(json.utf8))
        XCTAssertNil(profile.bio)
        XCTAssertTrue(profile.badges.isEmpty)
        XCTAssertNil(profile.mutualGuilds)
        XCTAssertNil(MediaRequest.bannerURL(for: profile, guildID: nil, pixels: 600))
    }

    func testPresenceDecodingIsLenient() throws {
        let json = """
        {"user": {"id": "5"}, "status": "dnd", "activities": [
          {"name": "Custom Status", "type": 4, "state": "Busy", "emoji": {"name": "🔥"}},
          {"name": "Rocket League", "type": 0, "application_id": "356", "timestamps": {"start": "1700000000000"},
           "assets": {"large_image": "1234", "large_text": "Ranked"}},
          {"type": 2}]}
        """
        let presence = try decoder.decode(RawPresence.self, from: Data(json.utf8)).presence
        XCTAssertEqual(presence.userID, "5")
        XCTAssertEqual(presence.status, .dnd)
        XCTAssertEqual(presence.customStatus?.headline, "🔥 Busy")
        XCTAssertEqual(presence.shownActivities.map(\.headline), ["Playing Rocket League"])
        XCTAssertEqual(presence.shownActivities.first?.startDate, Date(timeIntervalSince1970: 1_700_000_000))
        let image = MediaRequest.activityImageURL(presence.shownActivities[0], pixels: 96)
        XCTAssertEqual(image?.absoluteString, "https://cdn.discordapp.com/app-assets/356/1234.webp?size=128")

        let unknown = try decoder.decode(RawPresence.self, from: Data(#"{"user_id": "6", "status": "invisible"}"#.utf8)).presence
        XCTAssertEqual(unknown.status, .offline)
    }

    func testActivityImagesOnlyFromDiscord() throws {
        func activity(_ image: String) throws -> Activity {
            try decoder.decode(Activity.self, from: Data(#"{"name": "x", "type": 2, "application_id": "1", "assets": {"large_image": "\#(image)"}}"#.utf8))
        }
        XCTAssertEqual(MediaRequest.activityImageURL(try activity("mp:external/abc/https/x.png"), pixels: 48)?.host, "media.discordapp.net")
        XCTAssertNil(MediaRequest.activityImageURL(try activity("spotify:ab67616d0000b273"), pixels: 48))
        XCTAssertNil(MediaRequest.activityImageURL(try activity("mp:../../evil"), pixels: 48))
        XCTAssertNil(MediaRequest.activityImageURL(try activity("https://example.com/a.png"), pixels: 48))
    }

    func testProfileImagesAreAllowedButOtherCDNPathsAreNot() {
        let allowed = [
            "https://cdn.discordapp.com/banners/1/abc.webp?size=600",
            "https://cdn.discordapp.com/app-icons/1/abc.webp",
            "https://cdn.discordapp.com/badge-icons/abc.png",
            "https://cdn.discordapp.com/guilds/1/users/2/avatars/abc.webp",
            "https://cdn.discordapp.com/guilds/1/users/2/banners/abc.webp",
        ]
        let refused = [
            "https://cdn.discordapp.com/attachments/1/2/file.png",
            "https://cdn.discordapp.com/guilds/1/users/2/other/abc.webp",
            "https://cdn.discordapp.com/guilds/1/abc.webp",
            "http://cdn.discordapp.com/banners/1/abc.webp",
        ]
        for url in allowed { XCTAssertTrue(MediaRequest.isAllowedImageURL(URL(string: url)!), url) }
        for url in refused { XCTAssertFalse(MediaRequest.isAllowedImageURL(URL(string: url)!), url) }
    }

    func testStoreKeepsOnlineStatusesAndDropsOffline() throws {
        let store = Store()
        let ready = """
        {"user": {"id": "1", "username": "me"}, "session_id": "s", "private_channels": [], "read_state": [],
         "presences": [{"user": {"id": "5"}, "status": "online", "activities": []}],
         "guilds": [{"id": "100", "name": "g", "roles": [{"id": "100", "name": "@everyone", "permissions": "0", "position": 0},
                                                         {"id": "7", "name": "Mods", "permissions": "0", "position": 3, "colors": {"primary_color": 255}}],
                     "presences": [{"user": {"id": "6"}, "status": "idle", "activities": []}]}]}
        """
        store.apply(.ready(try decoder.decode(ReadyEvent.self, from: Data(ready.utf8))))
        XCTAssertEqual(store.presence(of: "5")?.status, .online)
        XCTAssertEqual(store.presence(of: "6")?.status, .idle)
        XCTAssertEqual(store.guilds["100"]?.presences.count, 0, "presences aren't kept twice")
        XCTAssertEqual(store.guilds["100"]?.roles.last?.name, "Mods")
        XCTAssertEqual(store.guilds["100"]?.roles.last?.color, 255)

        var changes: [Store.Change] = []
        store.onChange = { changes.append($0) }
        store.apply(.presenceUpdate(Presence(userID: "5", status: .offline, activities: [])))
        XCTAssertNil(store.presence(of: "5"))
        XCTAssertEqual(changes, [.presence(userID: "5")])
    }
}

extension StoreTests {
    func testUsersAreFoundWithoutScanningMessages() throws {
        let store = try readyStore()
        XCTAssertNil(store.user("20"))
        store.apply(.messageCreate(message("60")))
        XCTAssertEqual(store.user("20")?.username, "other")
        let mentioned = User(id: "30", username: "thirty")
        store.addHistory([message("40", mentions: [mentioned])], for: "101", requestedLimit: 50)
        XCTAssertEqual(store.user("30")?.username, "thirty")
        XCTAssertEqual(store.user("10")?.username, "me")
    }

    func testMarkAllReadCoversEveryUnreadChannel() throws {
        let store = try readyStore()
        store.apply(.messageCreate(message("60")))
        store.apply(.messageCreate(message("61", channel: "103")))
        let acks = store.markAllRead(guildID: "100")
        XCTAssertEqual(Set(acks.map(\.channelID)), ["101", "103"])
        XCTAssertFalse(store.guildHasUnread("100"))
        XCTAssertTrue(store.markAllRead(guildID: "100").isEmpty)
    }

    func testNotificationTextUsesNames() throws {
        let store = try readyStore()
        let mentioned = User(id: "30", username: "thirty", globalName: "Thirty")
        let msg = message("60", content: "hey <@30> in <#103>, ||secret|| **bold** <:pog:1>", mentions: [mentioned])
        XCTAssertEqual(Markdown.plainText(msg.content, resolver: store.resolver(for: msg)),
                       "hey @Thirty in #inside, (spoiler) bold :pog:")
        // Roles use the server's names; unknown ones fall back to "@role".
        let roles = Markdown.Resolver(role: { $0 == "7" ? "Mods" : nil })
        XCTAssertEqual(Markdown.plainText("<@&7> <@&8>", resolver: roles), "@Mods @role")
    }
}

final class ClientIdentityTests: XCTestCase {
    func testLaunchSignatureClearsTheClientModBits() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: ClientIdentity.launchSignature)).uuid
        let bytes = withUnsafeBytes(of: uuid) { Array($0) }
        let high = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let low = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        XCTAssertEqual(high & 0x0080_1010_0810_0800, 0)
        XCTAssertEqual(low & 0x2081_0040_0100_0800, 0)
    }

    func testPropertiesLookLikeTheMacApp() {
        let p = ClientIdentity.properties
        XCTAssertEqual(p["os"] as? String, "Mac OS X")
        XCTAssertEqual(p["browser"] as? String, "Discord Client")
        XCTAssertEqual(p["has_client_mods"] as? Bool, false)
        XCTAssertGreaterThan(p["client_build_number"] as? Int ?? 0, 0)
        // The Darwin version ("24.2.0"), with the SDK version as its major number.
        let os = p["os_version"] as? String ?? ""
        XCTAssertEqual(os.split(separator: ".").count, 3)
        XCTAssertEqual(p["os_sdk_version"] as? String, String(os.split(separator: ".")[0]))
        XCTAssertTrue((p["browser_user_agent"] as? String ?? "").contains("discord/\(ClientIdentity.clientVersion)"))
    }
}

extension StoreTests {
    /// A DM opened from a profile is added from Discord's reply, then again from the gateway's CHANNEL_CREATE.
    func testNewDMIsKnownAtOnceAndAddingItTwiceIsHarmless() throws {
        let store = try readyStore()
        let json = #"{"id": "900", "type": 1, "last_message_id": null, "recipients": [{"id": "20", "username": "other"}]}"#
        let dm = try makeDiscordDecoder().decode(Channel.self, from: Data(json.utf8))
        store.apply(.channelCreate(dm))
        XCTAssertNotNil(store.channel("900"))
        XCTAssertEqual(store.user("20")?.username, "other")
        store.apply(.channelCreate(dm))
        XCTAssertEqual(store.privateChannels.map(\.id), ["900"])
    }
}

final class PrivateMessagingTests: XCTestCase {
    private func randomText(_ count: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<count).map { _ in letters.randomElement()! })
    }

    func testHandshakeRoundTrip() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let content = PrivateMessaging.handshake(publicKey: key, wantsReply: true)
        XCTAssertTrue(content.hasPrefix("-# encrypted messaging by C4BRA/duhcord 🤫\n"))
        XCTAssertEqual(PrivateMessaging.kind(of: content), .handshake(key: key, wantsReply: true))
        XCTAssertLessThan(content.utf16.count, 80)
        XCTAssertEqual(PrivateMessaging.kind(of: "hello"), .plain)
        XCTAssertEqual(PrivateMessaging.kind(of: "dhc2:not dense text"), .plain)
    }

    func testDenseTextRoundTripsAndCountsOneUnitPerCharacter() {
        for length in [0, 1, 2, 7, 8, 14, 15, 16, 31, 100, 1000] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            let text = DenseText.encode(data)
            XCTAssertEqual(DenseText.decode(text), data, "length \(length)")
            // Every character is one UTF-16 unit, the way Discord counts.
            XCTAssertEqual(text.utf16.count, text.unicodeScalars.count)
            XCTAssertEqual(text.unicodeScalars.count, (length * 8 + 14) / 15)
            // Unicode normalisation leaves it alone.
            XCTAssertEqual(text.precomposedStringWithCanonicalMapping, text)
        }
        XCTAssertNil(DenseText.decode("abc"))
    }

    func testSafetyNumberIsTheSameBothWays() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let number = PrivateMessaging.safetyNumber(a, b)
        XCTAssertEqual(number, PrivateMessaging.safetyNumber(b, a))
        XCTAssertEqual(number.split(separator: " ").count, 12)
        XCTAssertEqual(number.filter(\.isNumber).count, 60)
    }

    func testSafetyNumberCoversEveryKey() {
        func key() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }
        let (mac1, mac2, theirs) = (key(), key(), key())
        let number = PrivateMessaging.safetyNumber([mac1, mac2], [theirs])
        // Same for both people, whatever order each lists their own keys in.
        XCTAssertEqual(number, PrivateMessaging.safetyNumber([theirs], [mac2, mac1]))
        XCTAssertEqual(number.filter(\.isNumber).count, 60)
        // A key slipped in on either side changes it.
        XCTAssertNotEqual(number, PrivateMessaging.safetyNumber([mac1, mac2], [theirs, key()]))
        XCTAssertNotEqual(number, PrivateMessaging.safetyNumber([mac1, mac2, key()], [theirs]))
        // Moving a key from one side to the other changes it too.
        XCTAssertNotEqual(number, PrivateMessaging.safetyNumber([mac1], [mac2, theirs]))
    }

    func testKeyCode() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let code = PrivateMessaging.keyCode(a)
        XCTAssertEqual(code, PrivateMessaging.keyCode(a))
        XCTAssertNotEqual(code, PrivateMessaging.keyCode(b))
        XCTAssertEqual(code.split(separator: " ").count, 6)
        XCTAssertEqual(code.filter(\.isNumber).count, 30)
    }

    func testSealRefusesToDropRecipients() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let eight = (0..<PrivateMessaging.maxRecipients).map { _ in Curve25519.KeyAgreement.PrivateKey().publicKey }
        XCTAssertNoThrow(try PrivateCrypto.seal("hi", channelID: "1", sender: alice, recipients: eight + [alice.publicKey]))
        XCTAssertThrowsError(try PrivateCrypto.seal("hi", channelID: "1", sender: alice,
                                                    recipients: eight + [Curve25519.KeyAgreement.PrivateKey().publicKey])) {
            XCTAssertEqual($0 as? PrivateMessagingError, .tooManyRecipients)
        }
    }

    func testPadmeHidesExactSizes() {
        XCTAssertEqual(PrivateMessaging.padme(1), 1)
        for length in [1000, 4097, 123_456, 2_000_001, 9_999_999] {
            let padded = PrivateMessaging.padme(length)
            XCTAssertGreaterThanOrEqual(padded, length)
            XCTAssertLessThanOrEqual(Double(padded), Double(length) * 1.12 + 1)
        }
        // Nearby sizes land on the same padded size.
        XCTAssertEqual(PrivateMessaging.padme(2_000_001), PrivateMessaging.padme(2_000_100))
    }

    func testPrivateImageRoundTrip() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        let picture = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let (file, sealed) = try PrivateCrypto.sealFile(picture, width: 640, height: 480, kind: .jpeg)
        XCTAssertEqual(sealed.count, file.sealedLength)
        XCTAssertEqual(file.sealedLength, PrivateMessaging.padme(picture.count) + 16)
        XCTAssertEqual(PrivateCrypto.openFile(sealed, file: file), picture)

        // The image's key travels inside the message, which only the recipients can open.
        let content = try PrivateCrypto.seal("look", files: [file], channelID: "5", sender: alice, recipients: [bob.publicKey])
        guard case .encrypted(let payload) = PrivateMessaging.kind(of: content) else { return XCTFail("not encrypted") }
        let opened = try XCTUnwrap(PrivateCrypto.open(payload, channelID: "5", recipient: bob, senders: [alice.publicKey],
                                                      fromSelf: false))
        XCTAssertEqual(opened.text, "look")
        XCTAssertEqual(opened.files, [file])
        // The sender reads their own, images included.
        XCTAssertEqual(PrivateCrypto.open(payload, channelID: "5", recipient: alice, senders: [], fromSelf: true)?.files, [file])

        // An image alone, with no text.
        let bare = try PrivateCrypto.seal("", files: [file, file], channelID: "5", sender: alice, recipients: [bob.publicKey])
        guard case .encrypted(let barePayload) = PrivateMessaging.kind(of: bare) else { return XCTFail("not encrypted") }
        let bareOpened = try XCTUnwrap(PrivateCrypto.open(barePayload, channelID: "5", recipient: bob,
                                                          senders: [alice.publicKey], fromSelf: false))
        XCTAssertEqual(bareOpened.text, "")
        XCTAssertEqual(bareOpened.files.count, 2)
    }

    func testPrivateImageRejectsTamperingAndSwaps() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let picture = Data(repeating: 0xAB, count: 10_000)
        let (file, sealed) = try PrivateCrypto.sealFile(picture, width: 10, height: 10, kind: .png)
        var flipped = sealed
        flipped[100] ^= 1
        XCTAssertNil(PrivateCrypto.openFile(flipped, file: file))
        XCTAssertNil(PrivateCrypto.openFile(sealed.dropLast(), file: file))
        // Another image's attachment doesn't open with this image's key.
        let (_, other) = try PrivateCrypto.sealFile(picture, width: 10, height: 10, kind: .png)
        XCTAssertNil(PrivateCrypto.openFile(other, file: file))
        XCTAssertThrowsError(try PrivateCrypto.sealFile(Data(count: PrivateMessaging.maxFileBytes + 1),
                                                        width: 1, height: 1, kind: .jpeg))
    }

    func testPrivateFileListIsChecked() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        let (file, _) = try PrivateCrypto.sealFile(Data(count: 1000), width: 1, height: 1, kind: .jpeg)
        XCTAssertThrowsError(try PrivateCrypto.seal("x", files: Array(repeating: file, count: PrivateMessaging.maxFiles + 1),
                                                    channelID: "1", sender: alice, recipients: [bob.publicKey])) {
            XCTAssertEqual($0 as? PrivateMessagingError, .tooManyFiles)
        }
        // A listed size that doesn't match its padding, or no pixels, is refused.
        let lying = PrivateFile(key: file.key, length: 1000, sealedLength: 5000, width: 1, height: 1, kind: .jpeg)
        XCTAssertNil(PrivateFile(lying.encoded()))
        let empty = PrivateFile(key: file.key, length: 1000, sealedLength: file.sealedLength, width: 0, height: 1, kind: .jpeg)
        XCTAssertNil(PrivateFile(empty.encoded()))
        XCTAssertEqual(PrivateFile(file.encoded()), file)
    }

    func testUploadLimits() {
        XCTAssertEqual(UploadLimit.discordLimit(premiumType: nil), 10 * 1024 * 1024)
        XCTAssertEqual(UploadLimit.discordLimit(premiumType: 3), 50 * 1024 * 1024)
        XCTAssertEqual(UploadLimit.discordLimit(premiumType: 2), 500 * 1024 * 1024)
        XCTAssertLessThan(UploadLimit.bytes(premiumType: 0), 10 * 1024 * 1024)
        // Never more than Duhcord holds in memory for one message.
        XCTAssertLessThanOrEqual(UploadLimit.bytes(premiumType: 2), UploadLimit.duhcordCap)
    }

    func testVideoFileKind() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let (file, sealed) = try PrivateCrypto.sealFile(Data(count: 30_000), width: 1280, height: 720, kind: .mp4)
        XCTAssertTrue(file.kind.isVideo)
        XCTAssertEqual(PrivateFile(file.encoded()), file)
        XCTAssertEqual(PrivateCrypto.openFile(sealed, file: file)?.count, 30_000)
    }

    func testAttachmentURLs() {
        XCTAssertTrue(MediaRequest.isAllowedAttachmentURL(URL(string: "https://cdn.discordapp.com/attachments/1/2/encrypted.bin?ex=1")!))
        XCTAssertFalse(MediaRequest.isAllowedAttachmentURL(URL(string: "http://cdn.discordapp.com/attachments/1/2/a")!))
        XCTAssertFalse(MediaRequest.isAllowedAttachmentURL(URL(string: "https://cdn.discordapp.com/avatars/1/2.png")!))
        XCTAssertFalse(MediaRequest.isAllowedAttachmentURL(URL(string: "https://evil.example/attachments/1/2/a")!))
        XCTAssertFalse(MediaRequest.isAllowedAttachmentURL(URL(string: "https://cdn.discordapp.com:444/attachments/1/2/a")!))
    }

    func testMultipartBody() throws {
        let body = Multipart(json: Data(#"{"content":"x"}"#.utf8),
                             files: [UploadFile(name: "encrypted.bin", data: Data([1, 2, 3]), contentType: "application/octet-stream")],
                             boundary: "B")
        XCTAssertEqual(body.contentType, "multipart/form-data; boundary=B")
        let text = String(decoding: body.body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n"))
        XCTAssertTrue(text.contains(#"name="files[0]"; filename="encrypted.bin""#))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    func testSealAndOpen() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        let eve = Curve25519.KeyAgreement.PrivateKey()
        let text = "hi **bob** 👋 " + String(repeating: "this repeats nicely. ", count: 20)
        let content = try PrivateCrypto.seal(text, channelID: "900", sender: alice, recipients: [bob.publicKey, alice.publicKey])
        XCTAssertTrue(content.hasPrefix(PrivateMessaging.notice + "\n" + PrivateMessaging.prefix))
        XCTAssertFalse(content.contains("bob"))
        guard case .encrypted(let payload) = PrivateMessaging.kind(of: content) else { return XCTFail("not encrypted") }

        // The recipient can read it, and so can the sender, without a copy sealed to themselves.
        XCTAssertEqual(PrivateCrypto.open(payload, channelID: "900", recipient: bob, senders: [alice.publicKey],
                                          fromSelf: false)?.text, text)
        XCTAssertEqual(PrivateCrypto.open(payload, channelID: "900", recipient: alice, senders: [], fromSelf: true)?.text, text)
        XCTAssertEqual(payload[26], 1, "one recipient entry: the sender's own key is skipped")
        // Not someone it wasn't sealed to, not in another DM, and not as if from someone else.
        XCTAssertNil(PrivateCrypto.open(payload, channelID: "900", recipient: eve, senders: [alice.publicKey], fromSelf: false))
        XCTAssertNil(PrivateCrypto.open(payload, channelID: "901", recipient: bob, senders: [alice.publicKey], fromSelf: false))
        XCTAssertNil(PrivateCrypto.open(payload, channelID: "901", recipient: alice, senders: [], fromSelf: true))
        XCTAssertNil(PrivateCrypto.open(payload, channelID: "900", recipient: bob, senders: [eve.publicKey], fromSelf: false))
        // Any changed byte is rejected.
        for index in [0, 1, 3, 10, 23, 30, 60, payload.count - 1] {
            var tampered = payload
            tampered[index] ^= 0x01
            XCTAssertNil(PrivateCrypto.open(tampered, channelID: "900", recipient: bob, senders: [alice.publicKey],
                                            fromSelf: false), "byte \(index)")
        }
        XCTAssertThrowsError(try PrivateCrypto.seal("a", channelID: "1", sender: alice, recipients: [alice.publicKey]))
    }

    func testOwnKeyPathNeedsOwnAuthorship() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        let content = try PrivateCrypto.seal("hi", channelID: "1", sender: alice, recipients: [bob.publicKey])
        guard case .encrypted(let payload) = PrivateMessaging.kind(of: content) else { return XCTFail("not encrypted") }

        XCTAssertEqual(PrivateCrypto.open(payload, channelID: "1", recipient: alice, senders: [], fromSelf: true)?.text, "hi")
        XCTAssertNil(PrivateCrypto.open(payload, channelID: "1", recipient: alice, senders: [], fromSelf: false))
        XCTAssertNil(PrivateCrypto.open(payload, channelID: "1", recipient: alice, senders: [alice.publicKey], fromSelf: false))
    }

    func testSendTimeAndSaltCarryThrough() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try PrivateCrypto.seal("hi", channelID: "1", sender: alice, recipients: [bob.publicKey], now: sentAt)
        let second = try PrivateCrypto.seal("hi", channelID: "1", sender: alice, recipients: [bob.publicKey], now: sentAt)
        guard case .encrypted(let a) = PrivateMessaging.kind(of: first), case .encrypted(let b) = PrivateMessaging.kind(of: second)
        else { return XCTFail("not encrypted") }
        let openedA = PrivateCrypto.open(a, channelID: "1", recipient: bob, senders: [alice.publicKey], fromSelf: false)
        let openedB = PrivateCrypto.open(b, channelID: "1", recipient: bob, senders: [alice.publicKey], fromSelf: false)
        XCTAssertEqual(openedA?.sentAt, sentAt)
        XCTAssertEqual(openedA?.salt.count, 16)
        // Each message has its own salt, so a reposted copy (same salt) stands out.
        XCTAssertNotEqual(openedA?.salt, openedB?.salt)
        // The time is authenticated: changing it breaks the message.
        var tampered = a
        tampered[7] ^= 0x01
        XCTAssertNil(PrivateCrypto.open(tampered, channelID: "1", recipient: bob, senders: [alice.publicKey], fromSelf: false))
    }

    func testAPlantedKeyWithTheSameIDDoesNotHideTheRealSender() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        let content = try PrivateCrypto.seal("hi", channelID: "1", sender: alice, recipients: [bob.publicKey])
        guard case .encrypted(let payload) = PrivateMessaging.kind(of: content) else { return XCTFail("not encrypted") }
        // Other keys tried first (as a planted key with a colliding ID would be) don't stop the real one working.
        let others = (0..<3).map { _ in Curve25519.KeyAgreement.PrivateKey().publicKey }
        XCTAssertEqual(PrivateCrypto.open(payload, channelID: "1", recipient: bob, senders: others + [alice.publicKey],
                                          fromSelf: false)?.text, "hi")
    }

    func testPrivateMessagesHoldMoreThanAPlainOne() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("HPKE needs macOS 14") }
        let alice = Curve25519.KeyAgreement.PrivateKey(), bob = Curve25519.KeyAgreement.PrivateKey()
        // Text that barely compresses still fits well past Discord's 2,000: about 1.9 bytes per character.
        let dense = randomText(3000)
        let sealed = try PrivateCrypto.seal(dense, channelID: "1", sender: alice, recipients: [bob.publicKey])
        XCTAssertLessThanOrEqual(sealed.utf16.count, 2000)
        guard case .encrypted(let payload) = PrivateMessaging.kind(of: sealed) else { return XCTFail("not encrypted") }
        XCTAssertEqual(PrivateCrypto.open(payload, channelID: "1", recipient: bob, senders: [alice.publicKey],
                                          fromSelf: false)?.text, dense)
        // Ordinary prose compresses, so far more fits.
        let prose = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        XCTAssertNoThrow(try PrivateCrypto.seal(prose, channelID: "1", sender: alice, recipients: [bob.publicKey]))
        XCTAssertThrowsError(try PrivateCrypto.seal(randomText(8000), channelID: "1", sender: alice,
                                                    recipients: [bob.publicKey])) { error in
            XCTAssertEqual(error as? PrivateMessagingError, .tooLong)
        }
        // Short messages are padded to the same size.
        let a = try PrivateCrypto.seal("ok", channelID: "1", sender: alice, recipients: [bob.publicKey])
        let b = try PrivateCrypto.seal(randomText(90), channelID: "1", sender: alice, recipients: [bob.publicKey])
        XCTAssertEqual(a.utf16.count, b.utf16.count)
    }
}
