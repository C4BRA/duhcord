import CDave
import Foundation

/// End-to-end encryption for a call (Discord's DAVE protocol), on top of libdave.
///
/// Follows Discord's reference session manager (libdave/samples/typescript/DaveSessionManager.ts): the voice
/// gateway announces group changes, members exchange MLS messages through it, and each transition hands every
/// sender a new key ratchet. libdave does the MLS and frame cryptography; this class only routes messages and
/// keys. Used only on the call's queue.
final class Dave {
    /// Protocol version 0 means no end-to-end encryption (transport encryption only).
    private static let disabledVersion: UInt16 = 0
    /// Transition 0 is (re)initialisation, which applies immediately.
    private static let initTransitionID: UInt16 = 0
    private static let newGroupEpoch = 1

    private let session: OpaquePointer
    private let encryptor: OpaquePointer
    private var decryptors: [String: OpaquePointer] = [:]
    private let selfUserID: String
    private let groupID: UInt64
    private var recognizedUserIDs: Set<String> = []
    private var pendingTransitions: [UInt16: UInt16] = [:]
    private var latestPreparedVersion: UInt16 = 0

    /// Sends a JSON opcode to the voice gateway.
    var sendJSON: ((Int, [String: Any]) -> Void)?
    /// Sends a binary opcode to the voice gateway.
    var sendBinary: ((UInt8, [UInt8]) -> Void)?
    /// Whether our own audio is end-to-end encrypted.
    var onEncryptionChange: ((Bool) -> Void)?

    /// `groupID` is the voice channel's ID.
    init?(selfUserID: String, groupID: UInt64) {
        Self.installLogSink()
        guard let session = daveSessionCreate(nil, nil, { source, reason, _ in
            voiceLog.error("DAVE MLS failure in \(source.map { String(cString: $0) } ?? "?", privacy: .public): \(reason.map { String(cString: $0) } ?? "?", privacy: .public)")
        }, nil), let encryptor = daveEncryptorCreate() else { return nil }
        self.session = session
        self.encryptor = encryptor
        self.selfUserID = selfUserID
        self.groupID = groupID
    }

    deinit {
        decryptors.values.forEach { daveDecryptorDestroy($0) }
        daveEncryptorDestroy(encryptor)
        daveSessionDestroy(session)
    }

    static var maxProtocolVersion: UInt16 { daveMaxSupportedProtocolVersion() }

    // MARK: - Media

    func assignSSRC(_ ssrc: UInt32) {
        daveEncryptorAssignSsrcToCodec(encryptor, ssrc, DAVE_CODEC_OPUS)
    }

    /// Our Opus frame, end-to-end encrypted. Nil while there's no key yet (the frame is then not sent).
    func encrypt(_ frame: [UInt8], ssrc: UInt32) -> [UInt8]? {
        let capacity = daveEncryptorGetMaxCiphertextByteSize(encryptor, DAVE_MEDIA_TYPE_AUDIO, frame.count)
        var output = [UInt8](repeating: 0, count: capacity)
        var written = 0
        let result = output.withUnsafeMutableBufferPointer { out in
            daveEncryptorEncrypt(encryptor, DAVE_MEDIA_TYPE_AUDIO, ssrc, frame, frame.count, out.baseAddress, capacity, &written)
        }
        guard result == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS, written <= capacity else { return nil }
        output.removeSubrange(written...)
        return output
    }

    /// Someone's Opus frame, decrypted. Nil if it doesn't decrypt (wrong key, forged, replayed).
    func decrypt(_ frame: [UInt8], from userID: String) -> [UInt8]? {
        let handle = decryptor(for: userID)
        let capacity = daveDecryptorGetMaxPlaintextByteSize(handle, DAVE_MEDIA_TYPE_AUDIO, frame.count)
        var output = [UInt8](repeating: 0, count: capacity)
        var written = 0
        let result = output.withUnsafeMutableBufferPointer { out in
            daveDecryptorDecrypt(handle, DAVE_MEDIA_TYPE_AUDIO, frame, frame.count, out.baseAddress, capacity, &written)
        }
        guard result == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS, written <= capacity else { return nil }
        output.removeSubrange(written...)
        return output
    }

    private func decryptor(for userID: String) -> OpaquePointer {
        if let existing = decryptors[userID] { return existing }
        let created: OpaquePointer = daveDecryptorCreate()
        decryptors[userID] = created
        // Someone we hadn't been told about yet: give them the current keys.
        setUpKeyRatchet(for: userID, version: latestPreparedVersion)
        return created
    }

    // MARK: - Voice gateway events

    func clientsConnected(_ userIDs: [String]) {
        for userID in userIDs {
            recognizedUserIDs.insert(userID)
            setUpKeyRatchet(for: userID, version: latestPreparedVersion)
        }
    }

    func clientDisconnected(_ userID: String) {
        recognizedUserIDs.remove(userID)
        if let decryptor = decryptors.removeValue(forKey: userID) { daveDecryptorDestroy(decryptor) }
    }

    /// Op 4 (select protocol ack): the call's initial protocol version.
    func protocolSelected(version: UInt16) {
        handleInit(version: version)
    }

    /// Op 21: a downgrade (or re-init with transition 0) is coming.
    func prepareTransition(id: UInt16, version: UInt16) {
        prepareRatchets(transitionID: id, version: version)
        sendReadyIfNeeded(transitionID: id)
    }

    /// Op 22: everyone is ready; switch keys now.
    func executeTransition(id: UInt16) {
        guard let version = pendingTransitions.removeValue(forKey: id) else { return }
        if version == Self.disabledVersion { daveSessionReset(session) }
        setUpKeyRatchet(for: selfUserID, version: version)
    }

    /// Op 24: a new epoch; epoch 1 means a new group.
    func prepareEpoch(_ epoch: Int, version: UInt16) {
        prepareEpochState(epoch, version: version)
        if epoch == Self.newGroupEpoch { sendKeyPackage() }
    }

    /// Op 25: the voice gateway's identity as the group's external sender.
    func externalSender(_ package: [UInt8]) {
        daveSessionSetExternalSender(session, package, package.count)
    }

    /// Op 27: proposals to append or revoke; answer with our commit (and welcome) if there's one to make.
    func proposals(_ payload: [UInt8]) {
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        withRecognizedUserIDs { ids, count in
            daveSessionProcessProposals(session, payload, payload.count, ids, count, &output, &length)
        }
        guard let output else {
            voiceLog.notice("DAVE: proposals processed, nothing to commit")
            return
        }
        let commitWelcome = Array(UnsafeBufferPointer(start: output, count: length))
        daveFree(output)
        voiceLog.notice("DAVE: proposals processed, commit \(commitWelcome.count, privacy: .public) bytes")
        if !commitWelcome.isEmpty { sendBinary?(28, commitWelcome) }
    }

    /// Op 29: the winning commit for the next epoch.
    func announceCommit(transitionID: UInt16, commit: [UInt8]) {
        guard let result = daveSessionProcessCommit(session, commit, commit.count) else { return }
        defer { daveCommitResultDestroy(result) }
        if daveCommitResultIsIgnored(result) {
            voiceLog.notice("DAVE: commit for transition \(transitionID, privacy: .public) ignored")
            return
        }
        if daveCommitResultIsFailed(result) {
            voiceLog.error("DAVE: commit for transition \(transitionID, privacy: .public) failed; asking to be re-added")
            sendJSON?(31, ["transition_id": Int(transitionID)])
            handleInit(version: daveSessionGetProtocolVersion(session))
        } else {
            prepareRatchets(transitionID: transitionID, version: daveSessionGetProtocolVersion(session))
            sendReadyIfNeeded(transitionID: transitionID)
        }
    }

    /// Op 30: we've been welcomed into the group.
    func welcome(transitionID: UInt16, welcome: [UInt8]) {
        let result = withRecognizedUserIDs { ids, count in
            daveSessionProcessWelcome(session, welcome, welcome.count, ids, count)
        }
        if let result {
            voiceLog.notice("DAVE: joined the group (transition \(transitionID, privacy: .public))")
            daveWelcomeResultDestroy(result)
            prepareRatchets(transitionID: transitionID, version: daveSessionGetProtocolVersion(session))
            sendReadyIfNeeded(transitionID: transitionID)
        } else {
            voiceLog.error("DAVE: welcome for transition \(transitionID, privacy: .public) failed; asking to be re-added")
            sendJSON?(31, ["transition_id": Int(transitionID)])
            sendKeyPackage()
        }
    }

    // MARK: - Internals

    private func handleInit(version: UInt16) {
        if version > Self.disabledVersion {
            prepareEpochState(Self.newGroupEpoch, version: version)
            sendKeyPackage()
        } else {
            prepareRatchets(transitionID: Self.initTransitionID, version: version)
            executeTransition(id: Self.initTransitionID)
        }
    }

    private func prepareEpochState(_ epoch: Int, version: UInt16) {
        guard epoch == Self.newGroupEpoch else { return }
        daveSessionInit(session, version, groupID, selfUserID)
    }

    private func prepareRatchets(transitionID: UInt16, version: UInt16) {
        for userID in recognizedUserIDs where userID != selfUserID {
            setUpKeyRatchet(for: userID, version: version)
        }
        if transitionID == Self.initTransitionID {
            setUpKeyRatchet(for: selfUserID, version: version)
        } else {
            pendingTransitions[transitionID] = version
        }
        latestPreparedVersion = version
    }

    private func sendReadyIfNeeded(transitionID: UInt16) {
        guard transitionID != Self.initTransitionID else { return }
        sendJSON?(23, ["transition_id": Int(transitionID)])
    }

    private func sendKeyPackage() {
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        daveSessionGetMarshalledKeyPackage(session, &output, &length)
        guard let output else { return }
        let keyPackage = Array(UnsafeBufferPointer(start: output, count: length))
        daveFree(output)
        voiceLog.notice("DAVE: key package sent (\(keyPackage.count, privacy: .public) bytes)")
        sendBinary?(26, keyPackage)
    }

    /// Hands a sender's current key ratchet to the encryptor (us) or their decryptor. Version 0 means no
    /// end-to-end encryption, so frames pass through.
    private func setUpKeyRatchet(for userID: String, version: UInt16) {
        let ratchet: OpaquePointer? = version == Self.disabledVersion ? nil : daveSessionGetKeyRatchet(session, userID)
        // libdave copies the ratchet, so ours can go straight away.
        defer { if let ratchet { daveKeyRatchetDestroy(ratchet) } }

        if userID == selfUserID {
            if let ratchet {
                daveEncryptorSetKeyRatchet(encryptor, ratchet)
                daveEncryptorSetPassthroughMode(encryptor, false)
            } else {
                daveEncryptorSetPassthroughMode(encryptor, true)
            }
            voiceLog.notice("DAVE: own key for version \(version, privacy: .public): \(ratchet != nil, privacy: .public)")
            onEncryptionChange?(ratchet != nil)
        } else if let handle = decryptors[userID] {
            if let ratchet {
                daveDecryptorTransitionToKeyRatchet(handle, ratchet)
                daveDecryptorTransitionToPassthroughMode(handle, false)
            } else {
                daveDecryptorTransitionToPassthroughMode(handle, true)
            }
        } else if recognizedUserIDs.contains(userID) {
            // Create it now so it's ready before their first frame arrives.
            _ = decryptor(for: userID)
        }
    }

    /// Our user ID plus everyone the voice gateway said is in the call, as C strings for libdave.
    private func withRecognizedUserIDs<R>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, Int) -> R) -> R {
        let ids = Array(recognizedUserIDs.union([selfUserID]))
        let pointers: [UnsafeMutablePointer<CChar>?] = ids.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var constPointers: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer($0) } }
        return constPointers.withUnsafeMutableBufferPointer { body($0.baseAddress!, ids.count) }
    }

    private static var logSinkInstalled = false

    /// libdave logs to stdout by default; route warnings and errors to the system log instead.
    private static func installLogSink() {
        guard !logSinkInstalled else { return }
        logSinkInstalled = true
        daveSetLogSinkCallback { severity, _, _, message in
            guard severity == DAVE_LOGGING_SEVERITY_WARNING || severity == DAVE_LOGGING_SEVERITY_ERROR,
                  let message else { return }
            voiceLog.notice("libdave: \(String(cString: message), privacy: .public)")
        }
    }
}
