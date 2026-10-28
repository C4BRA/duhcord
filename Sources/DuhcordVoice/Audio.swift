import AVFoundation
import CoreAudio
import os

/// Mixes everyone's decoded audio for the speakers.
///
/// Written from the call's queue, read on the real-time audio thread. Each speaker has a fixed ring buffer
/// allocated up front; the audio thread only takes a short lock and copies, and never allocates.
final class Mixer {
    /// Interleaved stereo samples per speaker: 0.5 s of room.
    private static let capacity = 48_000
    /// Start playing a speaker once 40 ms is buffered; trim back to 60 ms if they drift past 200 ms.
    private static let primeLevel = 2 * Opus.frameSize * 2
    private static let trimAbove = 10 * Opus.frameSize * 2
    private static let trimTo = 3 * Opus.frameSize * 2

    private final class Ring {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: Mixer.capacity)
        var start = 0
        var count = 0
        var playing = false
        deinit { samples.deallocate() }
    }

    private let lock = OSAllocatedUnfairLock()
    private var rings: [UInt32: Ring] = [:]

    /// Adds decoded audio (interleaved stereo) for the speaker with this SSRC.
    func push(_ samples: [Float], for ssrc: UInt32) {
        let incoming = rings[ssrc]
        let ring: Ring
        if let incoming {
            ring = incoming
        } else {
            ring = Ring()
            lock.withLockUnchecked { rings[ssrc] = ring }
        }
        lock.withLockUnchecked {
            for sample in samples.suffix(Self.capacity) {
                if ring.count == Self.capacity {
                    ring.start = (ring.start + 1) % Self.capacity
                    ring.count -= 1
                }
                ring.samples[(ring.start + ring.count) % Self.capacity] = sample
                ring.count += 1
            }
            if ring.count > Self.trimAbove {
                let drop = ring.count - Self.trimTo
                ring.start = (ring.start + drop) % Self.capacity
                ring.count -= drop
            }
        }
    }

    func remove(_ ssrc: UInt32) {
        lock.withLockUnchecked { rings[ssrc] = nil }
    }

    func removeAll() {
        lock.withLockUnchecked { rings.removeAll() }
    }

    /// Fills the output (non-interleaved stereo) for the audio hardware. Real-time thread.
    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        lock.withLockUnchecked {
            for ring in rings.values {
                if !ring.playing {
                    guard ring.count >= Self.primeLevel else { continue }
                    ring.playing = true
                }
                let available = min(frames, ring.count / 2)
                for i in 0..<available {
                    left[i] += ring.samples[(ring.start + 2 * i) % Self.capacity]
                    right[i] += ring.samples[(ring.start + 2 * i + 1) % Self.capacity]
                }
                ring.start = (ring.start + 2 * available) % Self.capacity
                ring.count -= 2 * available
                // Ran dry: wait for a little to build up again rather than stuttering.
                if available < frames { ring.playing = false }
            }
        }
    }
}

/// The microphone and speakers for a call, through AVAudioEngine with Apple's voice processing (echo
/// cancellation, noise suppression, automatic gain).
///
/// Rebuilt whenever mute or deafen changes: the microphone is only opened while unmuted and nothing runs while
/// deafened, so macOS's microphone indicator is on exactly when Duhcord can hear you.
final class AudioIO {
    private static let stereo = AVAudioFormat(standardFormatWithSampleRate: Opus.sampleRate, channels: 2)!
    private static let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Opus.sampleRate, channels: 1,
                                            interleaved: false)!

    let mixer = Mixer()
    /// 20 ms of mono microphone audio at 48 kHz, delivered on an audio thread.
    var onFrame: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private var capturing = false
    private var pending: [Float] = []

    func run(capture: Bool, playback: Bool) throws {
        stop()
        guard capture || playback else { return }
        let engine = AVAudioEngine()

        if capture {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                // Voice processing lowers other apps' audio by default; keep that to a minimum.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            let converter = format.sampleRate == Opus.sampleRate ? nil : AVAudioConverter(
                from: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!,
                to: Self.mono)
            pending = []
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Opus.frameSize), format: format) { [weak self] buffer, _ in
                self?.captured(buffer, converter: converter)
            }
            capturing = true
        }

        if playback {
            let mixer = self.mixer
            let source = AVAudioSourceNode(format: Self.stereo) { _, _, frameCount, bufferList -> OSStatus in
                mixer.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: Self.stereo)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        // The input node is only touched if it was used: creating it can wake the microphone.
        if capturing { engine.inputNode.removeTap(onBus: 0) }
        capturing = false
        engine.stop()
        self.engine = nil
        mixer.removeAll()
    }

    /// First channel only (voice processing may hand over several), converted to 48 kHz, cut into 20 ms frames.
    private func captured(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var samples: [Float]
        if let converter {
            guard let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: buffer.frameLength),
                  let monoChannel = mono.floatChannelData?[0] else { return }
            monoChannel.update(from: channel, count: Int(buffer.frameLength))
            mono.frameLength = buffer.frameLength
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Opus.sampleRate / converter.inputFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.mono, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return mono
            }
            guard error == nil, let converted = out.floatChannelData?[0] else { return }
            samples = Array(UnsafeBufferPointer(start: converted, count: Int(out.frameLength)))
        } else {
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        pending += samples
        while pending.count >= Opus.frameSize {
            onFrame?(Array(pending.prefix(Opus.frameSize)))
            pending.removeFirst(Opus.frameSize)
        }
    }
}

/// The names of the system's default microphone and speakers, for the connection details panel.
enum AudioDevices {
    static var defaultInputName: String? { name(of: kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutputName: String? { name(of: kAudioHardwarePropertyDefaultOutputDevice) }

    private static func name(of selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
