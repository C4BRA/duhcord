import CryptoKit
import Foundation
import XCTest
@testable import DuhcordCore

/// Runs the shared behaviour scenarios (spec/SCENARIOS.md) against `PrivateTrustEngine`, the trust code
/// `PrivateChatController` runs. The Companion's Rust runner (companion/crates/engine/tests/scenarios.rs) reads the
/// same files; both must pass every one.
@available(macOS 14, *)
final class PrivateScenarioTests: XCTestCase {
    static let required = [
        "duhcord-pair", "duhcord-and-companion", "companion-chat-off", "dropped-handshake", "relabel-first-handshake",
        "relabel-known-key", "new-key", "reject", "own-devices", "exclude-companion", "replay-and-delay", "outdated",
        "pending-limit", "too-many-recipients",
    ]

    static var scenarioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DuhcordCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("spec/scenarios")
    }

    func testEveryRequiredScenarioExists() {
        for name in Self.required {
            let url = Self.scenarioDirectory.appendingPathComponent("\(name).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing scenario \(url.path)")
        }
    }

    func testAllScenariosPass() throws {
        let urls = try FileManager.default.contentsOfDirectory(at: Self.scenarioDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "no scenarios found")
        let only = ProcessInfo.processInfo.environment["SCENARIO"]
        for url in urls where only.map({ url.lastPathComponent.contains($0) }) ?? true {
            try ScenarioRun(url: url).run()
        }
    }
}

@available(macOS 14, *)
private final class ScenarioRun {
    static let channel: Snowflake = "1100000000000000001"
    static let start: UInt64 = 1_700_000_000
    static let discordEpochMS: UInt64 = 1_420_070_400_000

    final class Device {
        let person: String
        let engine: PrivateTrustEngine
        var outbox: [(order: Int, content: String)] = []
        var refused: String?

        init(person: String, engine: PrivateTrustEngine) {
            self.person = person
            self.engine = engine
        }
    }

    let name: String
    let steps: [[String: Any]]
    var devices: [String: Device] = [:]
    var log: [PrivateTrustEngine.Message] = []
    var time = ScenarioRun.start
    var counter: UInt64 = 0
    var sendOrder = 0
    var names: [Data: String] = [:]

    init(url: URL) throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        name = try XCTUnwrap(json["name"] as? String)
        steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        for (deviceName, value) in try XCTUnwrap(json["devices"] as? [String: [String: Any]]) {
            let person = try XCTUnwrap(value["person"] as? String)
            let config: PrivateTrustEngine.Config
            switch value["client"] as? String {
            case "duhcord": config = .duhcord(allowCompanionChat: true)
            case "companion": config = .companion(host: Self.host(value["host"] as? String))
            default: throw ScenarioError("\(name): unknown client for \(deviceName)")
            }
            let engine = PrivateTrustEngine(privateKey: Self.privateKey(deviceName), userID: Self.personID(person),
                                            config: config)
            devices[deviceName] = Device(person: person, engine: engine)
            names[PrivateMessaging.keyID(Self.publicKey(deviceName))] = deviceName
        }
        sync()
    }

    struct ScenarioError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func personID(_ person: String) -> Snowflake { person == "alice" ? "1001" : "1002" }
    static func otherPerson(_ person: String) -> String { person == "alice" ? "bob" : "alice" }

    static func host(_ name: String?) -> UInt8 {
        switch name {
        case "vencord": return 1
        case "vesktop": return 2
        case "replugged": return 3
        case "betterdiscord": return 4
        case "dorion": return 5
        default: return 0
        }
    }

    static func privateKey(_ device: String) -> Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(SHA256.hash(data: Data("duhcord-vector-\(device)".utf8))))
    }

    static func publicKey(_ device: String) -> Data { privateKey(device).publicKey.rawRepresentation }

    func snowflake() -> Snowflake {
        counter += 1
        return String(((time * 1000 - Self.discordEpochMS) << 22) + counter)
    }

    func take(_ device: String, _ sends: [PrivateTrustEngine.Outgoing]) {
        for send in sends {
            sendOrder += 1
            devices[device]?.outbox.append((sendOrder, send.content))
        }
    }

    /// Every device reads the whole log, as if Discord loaded the DM.
    func sync() {
        for deviceName in devices.keys.sorted() {
            guard let device = devices[deviceName] else { continue }
            device.engine.clock = Date(timeIntervalSince1970: TimeInterval(time))
            device.engine.setDM(channelID: Self.channel, peerID: Self.personID(Self.otherPerson(device.person)))
            take(deviceName, device.engine.read(channelID: Self.channel, messages: log).sends)
        }
    }

    func device(_ step: [String: Any]) throws -> (String, Device) {
        let deviceName = try XCTUnwrap(step["device"] as? String, "\(name): step needs a device")
        let device = try XCTUnwrap(devices[deviceName], "\(name): unknown device \(deviceName)")
        device.engine.clock = Date(timeIntervalSince1970: TimeInterval(time))
        return (deviceName, device)
    }

    func keys(_ step: [String: Any], _ field: String) throws -> [Data] {
        try XCTUnwrap(step[field] as? [String], "\(name): step needs \(field)").map(Self.publicKey)
    }

    func run() throws {
        for (index, step) in steps.enumerated() {
            if let expect = step["expect"] as? [String: [String: Any]] {
                try check(index, expect)
            } else {
                try act(step)
                sync()
            }
        }
    }

    func act(_ step: [String: Any]) throws {
        let action = try XCTUnwrap(step["do"] as? String)
        switch action {
        case "setPrivate":
            let (deviceName, device) = try self.device(step)
            take(deviceName, device.engine.setPrivate(try XCTUnwrap(step["on"] as? Bool), in: Self.channel))
        case "resendKey":
            let (deviceName, device) = try self.device(step)
            take(deviceName, device.engine.resendKey(in: Self.channel))
        case "accept":
            let keys = try self.keys(step, "keys")
            let (deviceName, device) = try self.device(step)
            var compared = step["compared"] as? String
            if compared == "shown" { compared = device.engine.safetyNumber(for: Self.channel, accepting: keys) }
            if case .success(let sends) = device.engine.accept(keys, in: Self.channel, compared: compared) {
                take(deviceName, sends)
            }
        case "reject":
            let keys = try self.keys(step, "keys")
            let (deviceName, device) = try self.device(step)
            take(deviceName, device.engine.reject(keys, in: Self.channel))
        case "markVerified":
            let (_, device) = try self.device(step)
            device.engine.markVerified(in: Self.channel)
        case "excludeCompanion":
            let (deviceName, device) = try self.device(step)
            take(deviceName, device.engine.setCompanionExcluded(try XCTUnwrap(step["on"] as? Bool), in: Self.channel))
        case "allowCompanionChat":
            let (deviceName, device) = try self.device(step)
            if device.engine.config.client == .duhcord {
                take(deviceName, device.engine.setAllowCompanionChat(try XCTUnwrap(step["on"] as? Bool)))
            }
        case "setDevice":
            let key = Self.publicKey(try XCTUnwrap(step["key"] as? String))
            let trust = try XCTUnwrap(PrivateTrustEngine.Trust(rawValue: try XCTUnwrap(step["trust"] as? String)))
            let (_, device) = try self.device(step)
            device.engine.setDevice(key, trust: trust)
        case "send":
            let text = try XCTUnwrap(step["text"] as? String)
            let (deviceName, device) = try self.device(step)
            do {
                let content = try device.engine.seal(text, in: Self.channel)
                device.refused = nil
                sendOrder += 1
                device.outbox.append((sendOrder, content))
            } catch PrivateTrustEngine.SendError.notReady {
                device.refused = "not-ready"
            } catch PrivateTrustEngine.SendError.tooManyRecipients {
                device.refused = "too-many-recipients"
            }
            _ = deviceName
        case "deliver":
            var queued: [(order: Int, person: String, content: String)] = []
            for device in devices.values {
                queued += device.outbox.map { ($0.order, device.person, $0.content) }
                device.outbox = []
            }
            for item in queued.sorted(by: { $0.order < $1.order }) {
                log.append(PrivateTrustEngine.Message(id: snowflake(), authorID: Self.personID(item.person),
                                                      content: item.content))
                time += 1
            }
        case "drop":
            let (_, device) = try self.device(step)
            device.outbox = []
        case "relabel":
            let client = UInt8(try XCTUnwrap(step["client"] as? Int))
            let (_, device) = try self.device(step)
            device.outbox = device.outbox.map { item in
                guard case .handshake = PrivateMessaging.kind(of: item.content),
                      let line = item.content.split(separator: "\n").last,
                      var frame = DenseText.decode(line.dropFirst(PrivateMessaging.prefix.count)) else { return item }
                frame = Data(frame)
                frame[3] = client
                return (item.order, PrivateMessaging.content(for: frame))
            }
        case "replay":
            let index = try XCTUnwrap(step["index"] as? Int)
            var copy = log[index < 0 ? log.count + index : index]
            copy.id = snowflake()
            time += 1
            log.append(copy)
        case "inject":
            let person = try XCTUnwrap(step["person"] as? String)
            let fields = try XCTUnwrap(step["handshake"] as? [String: Any])
            let handshake = PrivateHandshake(
                key: Self.publicKey(try XCTUnwrap(fields["key"] as? String)),
                wantsReply: fields["wantsReply"] as? Bool ?? false,
                client: PeerClient(rawValue: UInt8(fields["client"] as? Int ?? 0)) ?? .duhcord,
                host: UInt8(fields["host"] as? Int ?? 0),
                features: PeerFeatures(rawValue: UInt16(fields["features"] as? Int ?? 0x030F)),
                acceptedKeyIDs: (fields["acceptedKeys"] as? [String] ?? []).map { PrivateMessaging.keyID(Self.publicKey($0)) })
            var frame = PrivateMessaging.handshakeFrame(handshake)
            frame[2] = UInt8(fields["version"] as? Int ?? 3)
            log.append(PrivateTrustEngine.Message(id: snowflake(), authorID: Self.personID(person),
                                                  content: PrivateMessaging.content(for: frame)))
            time += 1
        case "delay":
            time += UInt64(try XCTUnwrap(step["seconds"] as? Int))
        default:
            throw ScenarioError("\(name): unknown action \(action)")
        }
    }

    func label(_ keyID: Data) -> String { names[keyID] ?? "?" }

    func check(_ index: Int, _ expect: [String: [String: Any]]) throws {
        for (deviceName, wanted) in expect {
            let at = "\(name) step \(index), \(deviceName)"
            let device = try XCTUnwrap(devices[deviceName], "\(at): unknown device")
            let engine = device.engine
            let status = engine.status(for: Self.channel)
            for (field, value) in wanted {
                switch field {
                case "state": XCTAssertEqual(status.state.rawValue, value as? String, "\(at): state")
                case "newKey": XCTAssertEqual(status.newKey, value as? Bool, "\(at): newKey")
                case "verified": XCTAssertEqual(status.verified, value as? Bool, "\(at): verified")
                case "canSend": XCTAssertEqual(status.canSend, value as? Bool, "\(at): canSend")
                case "hasOurKey": XCTAssertEqual(engine.hasOurKey(in: Self.channel), value as? Bool, "\(at): hasOurKey")
                case "keys":
                    let peerID = Self.personID(Self.otherPerson(device.person))
                    let keys = engine.peerKeys(in: Self.channel)
                    for (keyName, expected) in try XCTUnwrap(value as? [String: String]) {
                        let key = Self.publicKey(keyName)
                        let actual: String
                        if let peerKey = keys.first(where: { $0.key == key }) {
                            actual = peerKey.trust == .accepted && engine.excluded(peerKey, peerID: peerID)
                                ? "excluded" : peerKey.trust.rawValue
                        } else {
                            actual = "unknown"
                        }
                        XCTAssertEqual(actual, expected, "\(at): key \(keyName)")
                    }
                case "devices":
                    for (keyName, expected) in try XCTUnwrap(value as? [String: String]) {
                        let key = Self.publicKey(keyName)
                        let actual = engine.devices.first(where: { $0.key == key })?.trust.rawValue ?? "unknown"
                        XCTAssertEqual(actual, expected, "\(at): device \(keyName)")
                    }
                case "outbox":
                    let expected = try XCTUnwrap(value as? [Any])
                    XCTAssertEqual(device.outbox.count, expected.count, "\(at): outbox length \(describe(device))")
                    for (item, (_, content)) in zip(expected, device.outbox) { checkOutgoing(at, item, content) }
                case "messages":
                    let opened = engine.openedMessages(in: Self.channel)
                    let expected = try XCTUnwrap(value as? [[String: Any]])
                    let actual = opened.map { "\(label(PrivateMessaging.keyID($0.opened.senderKey))): \($0.opened.message.text) \($0.opened.warnings.map(\.code))" }
                    XCTAssertEqual(opened.count, expected.count, "\(at): messages \(actual)")
                    for (item, wantedMessage) in zip(opened, expected) {
                        XCTAssertEqual(label(PrivateMessaging.keyID(item.opened.senderKey)), wantedMessage["from"] as? String,
                                       "\(at): message sender \(actual)")
                        XCTAssertEqual(item.opened.message.text, wantedMessage["text"] as? String, "\(at): message text")
                        if let warnings = wantedMessage["warnings"] as? [String] {
                            XCTAssertEqual(item.opened.warnings.map(\.code), warnings,
                                           "\(at): warnings on \"\(item.opened.message.text)\"")
                        }
                    }
                case "sendRefused":
                    XCTAssertEqual(device.refused, value as? String, "\(at): sendRefused")
                case "safetyNumber":
                    let relation = try XCTUnwrap((value as? [String: String])?.first)
                    let mine = engine.safetyNumber(for: Self.channel)
                    if relation.key == "none" {
                        XCTAssertNil(mine, "\(at): expected no safety number")
                        continue
                    }
                    let theirs = devices[relation.value]?.engine.safetyNumber(for: Self.channel)
                    switch relation.key {
                    case "same-as":
                        XCTAssertNotNil(mine, "\(at): no safety number")
                        XCTAssertEqual(mine, theirs, "\(at): safety number vs \(relation.value)")
                    case "differs-from":
                        XCTAssertNotEqual(mine, theirs, "\(at): safety number vs \(relation.value)")
                    default:
                        XCTFail("\(at): unknown safety number relation \(relation.key)")
                    }
                default:
                    XCTFail("\(at): unknown expectation \(field)")
                }
            }
        }
    }

    func describe(_ device: Device) -> [String] {
        device.outbox.map { item in
            switch PrivateMessaging.kind(of: item.content) {
            case .handshake(let handshake):
                return "handshake wantsReply=\(handshake.wantsReply) accepted=\(handshake.acceptedKeyIDs.map(label))"
            case .encrypted: return "message"
            default: return "other"
            }
        }
    }

    func checkOutgoing(_ at: String, _ item: Any, _ content: String) {
        let kind = PrivateMessaging.kind(of: content)
        if let word = item as? String {
            switch (word, kind) {
            case ("message", .encrypted), ("handshake", .handshake): return
            default: return XCTFail("\(at): outbox item \(word) doesn't match")
            }
        }
        guard let object = item as? [String: [String: Any]], let fields = object["handshake"],
              case .handshake(let handshake) = kind else {
            return XCTFail("\(at): outbox item \(item) doesn't match")
        }
        if let wantsReply = fields["wantsReply"] as? Bool {
            XCTAssertEqual(handshake.wantsReply, wantsReply, "\(at): outbox wantsReply")
        }
        if let accepted = fields["acceptedKeys"] as? [String] {
            XCTAssertEqual(handshake.acceptedKeyIDs.map(label).sorted(), accepted.sorted(), "\(at): outbox acceptedKeys")
        }
    }
}
