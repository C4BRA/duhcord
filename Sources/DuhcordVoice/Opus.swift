import AudioToolbox
import Foundation

/// Opus with macOS's built-in codec (AudioToolbox), so no libopus is bundled. 48 kHz, 20 ms frames.
enum Opus {
    static let sampleRate = 48_000.0
    static let frameSize = 960
    /// Discord's silence frame, sent five times when we stop talking.
    static let silence: [UInt8] = [0xF8, 0xFF, 0xFE]
    static let maxPacketSize = 4000

    /// Returned by our input callbacks when they have nothing more for this call. Not end-of-stream, so the
    /// converter keeps its state for the next frame.
    fileprivate static let noMoreInput: OSStatus = 1
}

/// Our microphone, mono, at 64 kbit/s.
final class OpusEncoder {
    private var converter: AudioConverterRef?
    private let pcm = UnsafeMutablePointer<Float>.allocate(capacity: Opus.frameSize)
    private var hasInput = false
    private var output = [UInt8](repeating: 0, count: Opus.maxPacketSize)

    init?() {
        var input = AudioStreamBasicDescription(
            mSampleRate: Opus.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var opus = AudioStreamBasicDescription(
            mSampleRate: Opus.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Opus.frameSize), mBytesPerFrame: 0, mChannelsPerFrame: 1,
            mBitsPerChannel: 0, mReserved: 0)
        guard AudioConverterNew(&input, &opus, &converter) == noErr, let converter else {
            pcm.deallocate()
            return nil
        }
        var bitRate: UInt32 = 64_000
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        pcm.deallocate()
    }

    /// One 20 ms frame of mono samples in, one Opus packet out (nil while the encoder is still priming).
    func encode(_ samples: [Float]) -> [UInt8]? {
        guard let converter, samples.count == Opus.frameSize else { return nil }
        samples.withUnsafeBufferPointer { pcm.update(from: $0.baseAddress!, count: Opus.frameSize) }
        hasInput = true

        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status = output.withUnsafeMutableBytes { out -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(out.count), mData: out.baseAddress))
            return AudioConverterFillComplexBuffer(converter, Self.supplyInput, Unmanaged.passUnretained(self).toOpaque(),
                                                   &packets, &list, &description)
        }
        guard status == noErr || status == Opus.noMoreInput, packets == 1 else { return nil }
        let start = Int(description.mStartOffset), size = Int(description.mDataByteSize)
        guard size > 0, start + size <= output.count else { return nil }
        return Array(output[start..<(start + size)])
    }

    private static let supplyInput: AudioConverterComplexInputDataProc = { _, packets, data, _, context in
        let encoder = Unmanaged<OpusEncoder>.fromOpaque(context!).takeUnretainedValue()
        guard encoder.hasInput else {
            packets.pointee = 0
            return Opus.noMoreInput
        }
        encoder.hasInput = false
        packets.pointee = UInt32(Opus.frameSize)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Opus.frameSize * 4),
                                            mData: UnsafeMutableRawPointer(encoder.pcm))
        return noErr
    }
}

/// One speaker's audio, decoded to interleaved stereo at 48 kHz.
final class OpusDecoder {
    private var converter: AudioConverterRef?
    private let packet = UnsafeMutablePointer<UInt8>.allocate(capacity: Opus.maxPacketSize)
    private let packetDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var packetSize = 0
    private let pcm = UnsafeMutablePointer<Float>.allocate(capacity: Opus.frameSize * 2)

    init?() {
        var opus = AudioStreamBasicDescription(
            mSampleRate: Opus.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Opus.frameSize), mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: Opus.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        guard AudioConverterNew(&opus, &output, &converter) == noErr else {
            packet.deallocate()
            packetDescription.deallocate()
            pcm.deallocate()
            return nil
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        packet.deallocate()
        packetDescription.deallocate()
        pcm.deallocate()
    }

    /// Up to 960 frames of interleaved stereo samples (fewer while the decoder primes).
    func decode(_ frame: [UInt8]) -> [Float]? {
        guard let converter, !frame.isEmpty, frame.count <= Opus.maxPacketSize else { return nil }
        frame.withUnsafeBufferPointer { packet.update(from: $0.baseAddress!, count: frame.count) }
        packetSize = frame.count

        var frames = UInt32(Opus.frameSize)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(Opus.frameSize * 8), mData: UnsafeMutableRawPointer(pcm)))
        let status = AudioConverterFillComplexBuffer(converter, Self.supplyInput, Unmanaged.passUnretained(self).toOpaque(),
                                                     &frames, &list, nil)
        guard status == noErr || status == Opus.noMoreInput, frames > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: pcm, count: Int(min(frames, UInt32(Opus.frameSize))) * 2))
    }

    private static let supplyInput: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, context in
        let decoder = Unmanaged<OpusDecoder>.fromOpaque(context!).takeUnretainedValue()
        guard decoder.packetSize > 0 else {
            packets.pointee = 0
            return Opus.noMoreInput
        }
        packets.pointee = 1
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(decoder.packetSize),
                                            mData: UnsafeMutableRawPointer(decoder.packet))
        decoder.packetDescription.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(decoder.packetSize))
        descriptions?.pointee = decoder.packetDescription
        decoder.packetSize = 0
        return noErr
    }
}
