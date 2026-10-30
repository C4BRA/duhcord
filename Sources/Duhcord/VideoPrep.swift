import AppKit
import AVFoundation
import CoreImage
import DuhcordCore
import UniformTypeIdentifiers
import VideoToolbox
import os

/// Turns a video the user attached into what's sent, written straight to memory (a fragmented MP4) so it never
/// touches the disk:
/// - Only the picture and sound are copied, so location, camera details and other metadata stay behind.
/// - With "Compress videos" on (the default), a video that's too large is re-encoded with the Mac's hardware
///   encoder at a bitrate worked out from its length and the account's upload limit. Frame rate drops from 30
///   to 24 to 15 before the picture shrinks past 480, and nothing under 120 kbps of video is encoded. The
///   encoder is held to that bitrate for every second, so a busy picture cannot blow past the upload limit.
///   A video that already fits is only repackaged, which keeps its quality.
/// - H.264, which plays on every Discord app and on any operating system. A private video that already fits
///   and is HEVC is sent unchanged.
// Active reader and writer references are protected by the cancellation-state lock.
final class VideoPrep: @unchecked Sendable {
    struct Options: Sendable {
        /// What the file may come to.
        let limit: Int
        let compress: Bool
        /// Private: an already-small HEVC file can be sent unchanged. Anything re-encoded is H.264.
        let forPrivate: Bool
    }

    enum Failure: LocalizedError {
        case unreadable
        /// It would need a bitrate too low to watch; `maxMinutes` would fit.
        case tooLong(maxMinutes: Int)
        /// Larger than the limit, and compression is off.
        case tooLarge(limit: Int)
        case failed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "It isn't a video Duhcord can read."
            case .tooLong(let minutes):
                return "It's too long to fit your upload limit at a watchable quality. Videos up to about "
                    + "\(max(1, minutes)) minute\(minutes == 1 ? "" : "s") fit."
            case .tooLarge(let limit):
                return "It's larger than your upload limit (\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))). "
                    + "Turn on Settings → Videos → Compress to fit, or send a shorter clip."
            case .failed: return "It couldn't be re-encoded."
            }
        }
    }

    /// Leaves room for the container and for the encoder landing a little over its target.
    private static let headroom = 0.92

    // The lock protects these active references while cancellation may arrive from another thread.
    private struct ActiveMedia: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter?
        /// A clip reads its sound with a second reader. One reader drops it.
        var audioReader: AVAssetReader? = nil
    }

    private struct State: Sendable {
        var isCancelled = false
        var activeMedia: ActiveMedia?
    }

    // AVFoundation cancellation state is read and changed only while holding this lock.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Stops the work; `prepare` then throws CancellationError.
    func cancel() {
        let activeMedia = state.withLock { state in
            state.isCancelled = true
            return state.activeMedia
        }
        activeMedia?.reader.cancelReading()
        activeMedia?.audioReader?.cancelReading()
        activeMedia?.writer?.cancelWriting()
    }

    private var cancelled: Bool { state.withLock { $0.isCancelled } }
    /// Set once the user stops the job, including during the pause between chained messages.
    var isCancelled: Bool { cancelled }

    /// Off the main thread. `progress` (0...1) is called from a background queue.
    /// `clip` encodes only that stretch, used when a private video is split into pieces.
    func prepare(_ url: URL, name: String, options: Options, clip: Range<Double>? = nil,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedAttachment {
        let asset = AVURLAsset(url: url)
        let fullDuration = try await asset.load(.duration).seconds
        let duration = clip.map { $0.upperBound - $0.lowerBound } ?? fullDuration
        guard fullDuration.isFinite, fullDuration > 0.1, duration.isFinite, duration > 0.05,
              let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let (natural, transform, frameRate, formats) = try await video.load(.naturalSize, .preferredTransform,
                                                                            .nominalFrameRate, .formatDescriptions)
        let shown = natural.applying(transform)
        let display = CGSize(width: abs(shown.width), height: abs(shown.height))
        guard display.width >= 2, display.height >= 2 else { throw Failure.unreadable }
        let thumbnail = await Self.thumbnail(asset)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max

        func finish(_ data: Data, size: CGSize, length: Double) -> PreparedAttachment {
            PreparedAttachment(data: data, width: Int(size.width), height: Int(size.height), kind: .mp4,
                               thumbnail: thumbnail, name: name, duration: length)
        }

        // Already small enough, in a format the recipients can play: only repackaged. A clip has to be encoded.
        let codec = formats.first.map(CMFormatDescriptionGetMediaSubType)
        let playable = codec == kCMVideoCodecType_H264 || (options.forPrivate && codec == kCMVideoCodecType_HEVC)
        if clip == nil, playable, fileSize <= options.limit || !options.compress,
           let data = try? await remux(asset, video: video, audio: audio, transform: transform, progress: progress),
           data.count <= options.limit {
            return finish(data, size: display, length: duration)
        }
        guard options.compress else {
            if cancelled { throw CancellationError() }
            throw playable ? Failure.tooLarge(limit: options.limit) : Failure.unreadable
        }

        // Bits per second the file can afford, less the sound.
        let budget = Double(options.limit) * Self.headroom * 8 / duration
        let audioBitrate = VideoEncode.audioBitrate(budget: budget, hasAudio: !audio.isEmpty)
        var videoBitrate = budget - audioBitrate
        guard videoBitrate >= VideoEncode.minVideoBitrate else {
            let floor = VideoEncode.minVideoBitrate + (audio.isEmpty ? 0 : VideoEncode.minAudioBitrate)
            let maxSeconds = Double(options.limit) * Self.headroom * 8 / floor
            throw Failure.tooLong(maxMinutes: Int(maxSeconds / 60))
        }
        // Up to three tries: if the encoder overshoots, the next aims lower by as much as it went over.
        // Each try picks size and frame rate again, so a lower target can drop to 15 fps instead of blocking.
        for attempt in 0..<3 {
            let plan = VideoEncode.picture(width: Double(display.width), height: Double(display.height), videoBitrate: videoBitrate,
                                           sourceFPS: Double(frameRate), hevc: false)
            let size = CGSize(width: plan.width, height: plan.height)
            let data = try await encode(asset, video: video, audio: audio, size: size, transform: transform,
                                        fps: Int32(plan.fps), videoBitrate: videoBitrate, audioBitrate: audioBitrate,
                                        duration: duration, clip: clip) { fraction in
                progress((Double(attempt) + fraction) / Double(attempt + 1))
            }
            if data.count <= options.limit {
                if clip != nil {
                    let played = await Self.playedDuration(data)
                    guard Self.durationMatches(played, span: duration) else {
                        throw Failure.tooLong(maxMinutes: max(1, Int(duration / 60)))
                    }
                    // The bar uses this length, so it is what the file actually plays, not the slice that was asked for.
                    return finish(data, size: size, length: played)
                }
                return finish(data, size: size, length: duration)
            }
            videoBitrate *= Double(options.limit) * Self.headroom / Double(data.count)
            guard videoBitrate >= VideoEncode.minVideoBitrate else { break }
        }
        throw Failure.tooLong(maxMinutes: Int(duration / 60 * 0.75))
    }

    /// Encodes `url` into pieces that each fit `options.limit`. One piece when the whole video fits; otherwise
    /// successive stretches, handed over one at a time so a long film is never all in memory.
    func preparePieces(_ url: URL, name: String, options: Options,
                       progress: @escaping @Sendable (Double) -> Void,
                       piece: @escaping (PreparedAttachment) async throws -> Void) async throws {
        do {
            try await piece(try await prepare(url, name: name, options: options, progress: progress))
            return
        } catch Failure.tooLong {
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.1 else { throw Failure.unreadable }
        let hasAudio = try await asset.loadTracks(withMediaType: .audio).isEmpty == false
        let floor = VideoEncode.minVideoBitrate + (hasAudio ? VideoEncode.minAudioBitrate : 0)
        var slice = max(1, Double(options.limit) * Self.headroom * 8 / floor * 0.85)
        var start = 0.0
        var count = 0
        while start < duration - 0.05 {
            if cancelled { throw CancellationError() }
            if count >= 48 {
                throw Failure.tooLong(maxMinutes: max(1, Int(start / 60)))
            }
            let end = min(duration, start + slice)
            let sliceStart = start
            do {
                let made = try await prepare(url, name: name, options: options, clip: sliceStart..<end) { fraction in
                    progress(min(1, (sliceStart + fraction * (end - sliceStart)) / duration))
                }
                try await piece(made)
                start = end
                count += 1
            } catch Failure.tooLong {
                let shorter = (end - start) / 2
                guard shorter >= 1 else { throw Failure.tooLong(maxMinutes: max(1, Int(start / 60))) }
                slice = shorter
            }
        }
    }

    /// Which way a track's transform turns it, for the quarter turns phones record with.
    private static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    private static func thumbnail(_ asset: AVAsset) async -> NSImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        if let image = try? await generator.image(at: .zero).image {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return NSImage(systemSymbolName: "film", accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: - Writing

    /// A writer that hands its output over in pieces (an MP4 header, then fragments), collected in memory.
    // The writer delegate appends and reads segments only while holding the lock.
    private final class MemoryOutput: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let data = OSAllocatedUnfairLock(initialState: Data())

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                         segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            data.withLock { $0.append(segmentData) }
        }

        var collected: Data { data.withLock { $0 } }
    }

    // Each pair is accessed only by its dedicated media-data queue after setup.
    private struct TrackPair: @unchecked Sendable {
        let readerOutput: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    /// `segmentInterval` `.indefinite` writes one fragment at the end, the only way the writer will pass picture
    /// and sound through together.
    private func makeWriter(_ output: MemoryOutput,
                            segmentInterval: CMTime = CMTime(seconds: 4, preferredTimescale: 600)) -> AVAssetWriter {
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        // Not CMAF: it allows only one track, so every video with sound failed.
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = segmentInterval
        if segmentInterval.isNumeric { writer.initialSegmentStartTime = .zero }
        writer.shouldOptimizeForNetworkUse = true
        writer.delegate = output
        return writer
    }

    /// The same picture and sound in a new file: nothing re-encoded, nothing else copied.
    private func remux(_ asset: AVAsset, video: AVAssetTrack, audio: [AVAssetTrack], transform: CGAffineTransform,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let output = MemoryOutput()
        let writer = makeWriter(output, segmentInterval: .indefinite)
        var pairs: [TrackPair] = []
        for track in [video] + audio.prefix(1) {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = transform }
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw Failure.failed }
            reader.add(readerOutput)
            writer.add(input)
            pairs.append(TrackPair(readerOutput: readerOutput, input: input))
        }
        let duration = try await asset.load(.duration).seconds
        return try await run(reader: reader, writer: writer, output: output, pairs: pairs, duration: duration, progress: progress)
    }

    /// Compressed pictures, in the order the encoder handed them over.
    private final class SampleBufferList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CMSampleBuffer] = []
        private var failure: OSStatus = noErr

        func add(_ sample: CMSampleBuffer) {
            lock.lock()
            stored.append(sample)
            lock.unlock()
        }

        func fail(_ status: OSStatus) {
            lock.lock()
            if failure == noErr { failure = status }
            lock.unlock()
        }

        var samples: [CMSampleBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var status: OSStatus {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
    }

    /// Pulls one reader output onto a background queue without the queue closure touching the reader itself.
    private final class OutputPump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let frames: SampleBufferList
        let state: OSAllocatedUnfairLock<State>

        let origin: CMTime

        init(output: AVAssetReaderOutput, frames: SampleBufferList, state: OSAllocatedUnfairLock<State>, origin: CMTime) {
            self.output = output
            self.frames = frames
            self.state = state
            self.origin = origin
        }

        func run() {
            while !state.withLock({ $0.isCancelled }), let sample = output.copyNextSampleBuffer() {
                frames.add(VideoPrep.shifted(sample, from: origin))
            }
        }
    }

    /// Writes already-read samples. The ready-callback only sees this object, which is safe to pass across queues.
    private final class InputPump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let samples: [CMSampleBuffer]
        let report: Bool
        let progress: @Sendable (Double) -> Void
        let state: OSAllocatedUnfairLock<State>
        let failed: OSAllocatedUnfairLock<Bool>
        private let done = OSAllocatedUnfairLock(initialState: false)
        private let index = OSAllocatedUnfairLock(initialState: 0)

        init(input: AVAssetWriterInput, samples: [CMSampleBuffer], report: Bool,
             progress: @escaping @Sendable (Double) -> Void, state: OSAllocatedUnfairLock<State>,
             failed: OSAllocatedUnfairLock<Bool>) {
            self.input = input
            self.samples = samples
            self.report = report
            self.progress = progress
            self.state = state
            self.failed = failed
        }

        func step(finish: @escaping @Sendable () -> Void) {
            while input.isReadyForMoreMediaData, !done.withLock({ $0 }) {
                let next = index.withLock { value -> Int? in
                    guard value < samples.count else { return nil }
                    let current = value
                    value += 1
                    return current
                }
                let stop: Bool
                if state.withLock({ $0.isCancelled }) || failed.withLock({ $0 }) || next == nil {
                    stop = true
                } else if let next {
                    if report, !samples.isEmpty {
                        progress(min(1, 0.9 + 0.1 * Double(next + 1) / Double(samples.count)))
                    }
                    let appended = input.append(samples[next])
                    if !appended { failed.withLock { $0 = true } }
                    stop = !appended
                } else {
                    stop = true
                }
                if stop {
                    let finished = done.withLock { finished in
                        guard !finished else { return false }
                        finished = true
                        return true
                    }
                    if finished { 
                        input.markAsFinished()
                        finish()
                    }
                }
            }
        }
    }

    /// H.264, with a hard cap of `bitrate` bits in any one second. The average is the same number; the cap is what
    /// stops a busy stretch from coming out several times larger than the upload allows.
    private static func compressionSession(size: CGSize, fps: Int32, bitrate: Double) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                                 codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                 imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                 outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard created == noErr, let session else { throw Failure.failed }
        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
            VTSessionSetProperty(session, key: key, value: value)
        }
        var rate = Int32(min(Double(Int32.max), max(1, bitrate.rounded())))
        var frameRate = fps
        var interval = fps * 2
        guard set(kVTCompressionPropertyKey_AverageBitRate, CFNumberCreate(nil, .sInt32Type, &rate)) == noErr,
              set(kVTCompressionPropertyKey_ExpectedFrameRate, CFNumberCreate(nil, .sInt32Type, &frameRate)) == noErr,
              set(kVTCompressionPropertyKey_MaxKeyFrameInterval, CFNumberCreate(nil, .sInt32Type, &interval)) == noErr,
              set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Failure.failed
        }
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, AVVideoColorPrimaries_ITU_R_709_2 as CFString)
        _ = set(kVTCompressionPropertyKey_TransferFunction, AVVideoTransferFunction_ITU_R_709_2 as CFString)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2 as CFString)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Failure.failed
        }
        // Set after prepare: doing it earlier makes the encoder undershoot the average.
        let bytesPerSecond = max(1, Int(bitrate / 8))
        let limits = [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray
        guard set(kVTCompressionPropertyKey_DataRateLimits, limits) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Failure.failed
        }
        return session
    }

    /// A clip keeps the source timeline, so every sample in the slice moves back by the same start.
    private static func shiftedTime(_ time: CMTime, from origin: CMTime) -> CMTime {
        guard origin.isNumeric, origin.seconds > 0.05, time.isNumeric else { return time }
        return CMTimeSubtract(time, origin)
    }

    /// How long the file that was just written actually plays.
    private static func playedDuration(_ data: Data) async -> Double {
        let loader = MemoryAssetLoader(data: data)
        let asset = loader.makeAsset()
        return (try? await asset.load(.duration).seconds) ?? 0
    }

    /// Close enough to the slice that was asked for. A file that starts at the wrong place fails this.
    private static func durationMatches(_ played: Double, span: Double) -> Bool {
        guard played.isFinite, span.isFinite, played > 0.2 else { return false }
        let slack = max(1.0, span * 0.02)
        return played >= span - slack && played <= span + slack
    }

    /// Moves a sample's timestamps back by `origin`, so a later piece of a film starts at zero.
    private static func shifted(_ sample: CMSampleBuffer, from origin: CMTime) -> CMSampleBuffer {
        guard origin.isNumeric, origin.seconds > 0 else { return sample }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return sample }
        var info = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid,
                                                       decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &info, entriesNeededOut: nil) == noErr
        else { return sample }
        for index in info.indices {
            info[index].presentationTimeStamp = shiftedTime(info[index].presentationTimeStamp, from: origin)
            if info[index].decodeTimeStamp.isNumeric {
                info[index].decodeTimeStamp = shiftedTime(info[index].decodeTimeStamp, from: origin)
            }
        }
        var copy: CMSampleBuffer?
        let timingCount = info.count
        let made = info.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMSampleBufferError_RequiredParameterMissing }
            return CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
                                                         sampleTimingEntryCount: timingCount, sampleTimingArray: base,
                                                         sampleBufferOut: &copy)
        }
        guard made == noErr, let copy else { return sample }
        return copy
    }

    private func encode(_ asset: AVAsset, video: AVAssetTrack, audio: [AVAssetTrack], size: CGSize,
                        transform: CGAffineTransform, fps: Int32,
                        videoBitrate: Double, audioBitrate: Double, duration: Double, clip: Range<Double>?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        // Turned upright, scaled down and brought to standard (SDR) colour by the composition, at most 30 fps.
        let turn = Self.orientation(of: transform)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            var source = request.sourceImage
            // The composition hands frames over upright; if one still comes sideways (its width and height the
            // wrong way round for the picture), turn it here.
            let sideways = (source.extent.width > source.extent.height) != (size.width > size.height)
            if sideways, size.width != size.height, turn == .left || turn == .right { source = source.oriented(turn) }
            let moved = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            let scale = min(size.width / max(1, moved.extent.width), size.height / max(1, moved.extent.height))
            request.finish(with: moved.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), context: nil)
        }
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: fps)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw Failure.failed }
        reader.add(videoOutput)
        // The sound has its own reader. Sharing one stalls a long clip, and pulling both outputs at once
        // comes back with no sound while the picture still finishes.
        let soundOutput: AVAssetReaderAudioMixOutput?
        let soundReader: AVAssetReader?
        if audio.isEmpty {
            soundOutput = nil
            soundReader = nil
        } else {
            let extra = try AVAssetReader(asset: asset)
            let output = Self.audioReader(audio, bitrate: audioBitrate)
            guard extra.canAdd(output) else { throw Failure.failed }
            extra.add(output)
            soundOutput = output
            soundReader = extra
        }

        let session = try Self.compressionSession(size: size, fps: fps, bitrate: videoBitrate)
        defer { VTCompressionSessionInvalidate(session) }
        let frames = SampleBufferList()
        let audioFrames = SampleBufferList()
        let reading = ActiveMedia(reader: reader, writer: nil, audioReader: soundReader)
        guard state.withLock({ state in
            guard !state.isCancelled else { return false }
            state.activeMedia = reading
            return true
        }) else { throw CancellationError() }
        defer { state.withLock { $0.activeMedia = nil } }
        let origin = CMTime(seconds: clip?.lowerBound ?? 0, preferredTimescale: 600)
        if let clip {
            let range = CMTimeRange(start: origin, duration: CMTime(seconds: clip.upperBound - clip.lowerBound,
                                                                    preferredTimescale: 600))
            reader.timeRange = range
            soundReader?.timeRange = range
        }
        if let soundReader {
            guard soundReader.startReading() else { throw Failure.failed }
        }
        guard reader.startReading() else { throw Failure.failed }

        let audioGroup = DispatchGroup()
        if let audioOutput = soundOutput {
            audioGroup.enter()
            let pump = OutputPump(output: audioOutput, frames: audioFrames, state: state, origin: origin)
            DispatchQueue.global(qos: .userInitiated).async {
                pump.run()
                audioGroup.leave()
            }
        }

        let frameDuration = CMTime(value: 1, timescale: fps)
        var encodeFailed = false
        while !cancelled {
            guard let sample = videoOutput.copyNextSampleBuffer() else { break }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let raw = CMSampleBufferGetPresentationTimeStamp(sample)
            let pts = Self.shiftedTime(raw, from: origin)
            if duration > 0 { progress(min(0.9, max(0, pts.seconds / duration))) }
            var sampleDuration = CMSampleBufferGetDuration(sample)
            if !sampleDuration.isValid || sampleDuration.isIndefinite { sampleDuration = frameDuration }
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: image, presentationTimeStamp: pts, duration: sampleDuration,
                frameProperties: nil, infoFlagsOut: nil, outputHandler: { status, _, compressed in
                    if status != noErr {
                        frames.fail(status)
                        return
                    }
                    if let compressed { frames.add(compressed) }
                })
            if status != noErr {
                encodeFailed = true
                break
            }
        }
        if cancelled || encodeFailed {
            reader.cancelReading()
            soundReader?.cancelReading()
        }
        let complete = cancelled || encodeFailed
            ? noErr
            : VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        await Self.wait(audioGroup)
        if cancelled { throw CancellationError() }
        if let soundReader, soundReader.status != .completed || audioFrames.samples.isEmpty {
            throw Failure.failed
        }
        guard !encodeFailed, complete == noErr, frames.status == noErr, !frames.samples.isEmpty,
              reader.status == .completed else { throw Failure.failed }
        return try await mux(reader: reader, video: frames.samples, audio: audioFrames.samples,
                             audioBitrate: audioBitrate, progress: progress)
    }

    /// Puts the already-capped H.264 pictures, and AAC for the sound, into the same fragmented MP4 as a remux.
    private func mux(reader: AVAssetReader, video: [CMSampleBuffer], audio: [CMSampleBuffer], audioBitrate: Double,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let hint = CMSampleBufferGetFormatDescription(video[0]) else { throw Failure.failed }
        // The writer can pass both tracks through, or encode both. It cannot encode the sound while the
        // picture is already H.264, so the sound becomes AAC here.
        let sound = try Self.aacPackets(audio, bitrate: audioBitrate)
        let collected = MemoryOutput()
        // A timed fragment cannot carry picture and sound together. One fragment at the end can.
        let writer = makeWriter(collected, segmentInterval: .indefinite)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw Failure.failed }
        writer.add(videoInput)
        let includeAudio = !sound.isEmpty
        var audioInput: AVAssetWriterInput?
        if includeAudio, let audioHint = CMSampleBufferGetFormatDescription(sound[0]) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.failed }
            writer.add(input)
            audioInput = input
        }
        let writing = ActiveMedia(reader: reader, writer: writer)
        guard state.withLock({ state -> Bool in
            guard !state.isCancelled else { return false }
            state.activeMedia = writing
            return true
        }) else { throw CancellationError() }
        guard writer.startWriting() else { throw Failure.failed }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let failed = OSAllocatedUnfairLock(initialState: false)
        let state = self.state
        func feed(_ input: AVAssetWriterInput, _ samples: [CMSampleBuffer], report: Bool) {
            let queue = DispatchQueue(label: report ? "duhcord.video.mux" : "duhcord.video.mux-audio", qos: .userInitiated)
            group.enter()
            let pump = InputPump(input: input, samples: samples, report: report, progress: progress, state: state, failed: failed)
            input.requestMediaDataWhenReady(on: queue) { pump.step { group.leave() } }
        }
        feed(videoInput, video, report: true)
        if includeAudio, let audioInput { feed(audioInput, sound, report: false) }
        await Self.wait(group)
        if cancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if failed.withLock({ $0 }) {
            writer.cancelWriting()
            throw Failure.failed
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw Failure.failed }
        progress(1)
        return collected.collected
    }

    private static func wait(_ group: DispatchGroup) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }

    /// The sound mixed down to PCM; mono at the lowest bitrates. AAC is made later, once the picture is already H.264.
    /// The bytes are copied: a long clip holds them until the picture is finished, and an uncopied buffer is gone by then.
    private static func audioReader(_ tracks: [AVAssetTrack], bitrate: Double) -> AVAssetReaderAudioMixOutput {
        let channels = bitrate <= VideoEncode.minAudioBitrate ? 1 : 2
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = true
        return output
    }

    /// AAC packets starting at the first sample's time. Empty when there is nothing to encode.
    private static func aacPackets(_ samples: [CMSampleBuffer], bitrate: Double) throws -> [CMSampleBuffer] {
        guard let first = samples.first else { return [] }
        guard let sourceDescription = CMSampleBufferGetFormatDescription(first),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(sourceDescription) else { throw Failure.failed }
        guard let source = AVAudioFormat(streamDescription: basic),
              let destination = AVAudioFormat(settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: basic.pointee.mSampleRate,
                AVNumberOfChannelsKey: basic.pointee.mChannelsPerFrame,
                AVEncoderBitRateKey: Int(bitrate),
              ]),
              let converter = AVAudioConverter(from: source, to: destination) else { throw Failure.failed }
        let sourceBuffers = PCMSource(samples: samples, format: source)
        var encoded: [CMSampleBuffer] = []
        var failure: NSError?
        let sampleRate = basic.pointee.mSampleRate
        var cursor = CMSampleBufferGetPresentationTimeStamp(first)
        while true {
            let packet = AVAudioCompressedBuffer(format: destination, packetCapacity: 8,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            let status = converter.convert(to: packet, error: &failure) { requested, outStatus in
                sourceBuffers.next(outStatus, packets: requested)
            }
            // The AAC format leaves the packet size unset. Treating that as one sample runs the song about a
            // thousand times too fast.
            let packetDuration = Self.aacFrameDuration(packet, sampleRate: sampleRate)
            if packet.packetCount > 0, let sample = compressedAudioSample(packet, at: cursor, packetDuration: packetDuration) {
                cursor = CMTimeAdd(cursor, CMSampleBufferGetDuration(sample))
                encoded.append(sample)
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && packet.packetCount == 0) { break }
            if failure != nil { break }
        }
        if failure != nil || encoded.isEmpty { throw Failure.failed }
        return encoded
    }

    /// AAC-LC packets hold 1024 frames. A reported count of 0 or 1 is the unset format, not the real size.
    private static func aacFrameDuration(_ buffer: AVAudioCompressedBuffer, sampleRate: Float64) -> CMTime {
        let reported = buffer.format.streamDescription.pointee.mFramesPerPacket
        let frames: UInt32 = reported > 1 ? reported : 1024
        return CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate.rounded()))
    }

    /// One compressed buffer may hold several AAC packets. Their times walk forward from `time`.
    private static func compressedAudioSample(_ buffer: AVAudioCompressedBuffer, at time: CMTime,
                                              packetDuration: CMTime) -> CMSampleBuffer? {
        let packetCount = CMItemCount(buffer.packetCount)
        guard packetCount > 0 else { return nil }
        let format = buffer.format.formatDescription
        let dataLength = Int(buffer.byteLength)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: dataLength,
                                                  blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                  dataLength: dataLength, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: buffer.data, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: dataLength) == noErr else { return nil }
        var cursor = time
        var timings = [CMSampleTimingInfo]()
        var sizes = [Int]()
        let descriptions = buffer.packetDescriptions
        for index in 0..<packetCount {
            timings.append(CMSampleTimingInfo(duration: packetDuration, presentationTimeStamp: cursor, decodeTimeStamp: .invalid))
            cursor = CMTimeAdd(cursor, packetDuration)
            let size = descriptions.map { Int($0[index].mDataByteSize) } ?? dataLength / Int(packetCount)
            sizes.append(size)
        }
        var sample: CMSampleBuffer?
        let status = timings.withUnsafeMutableBufferPointer { timingBuffer in
            sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                     refcon: nil, formatDescription: format, sampleCount: packetCount,
                                     sampleTimingEntryCount: packetCount, sampleTimingArray: timingBuffer.baseAddress,
                                     sampleSizeEntryCount: packetCount, sampleSizeArray: sizeBuffer.baseAddress,
                                     sampleBufferOut: &sample)
            }
        }
        guard status == noErr else { return nil }
        return sample
    }

    /// PCM handed over in the pieces the converter asked for. A whole read is longer than that, and the rest of it
    /// has to wait for the next request.
    private final class PCMSource: @unchecked Sendable {
        let samples: [CMSampleBuffer]
        let format: AVAudioFormat
        var index = 0
        var offset = 0

        init(samples: [CMSampleBuffer], format: AVAudioFormat) {
            self.samples = samples
            self.format = format
        }

        func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>, packets requested: AVAudioPacketCount) -> AVAudioBuffer? {
            let wanted = Int(requested)
            guard wanted > 0 else {
                outStatus.pointee = .noDataNow
                return nil
            }
            while index < samples.count {
                let available = CMSampleBufferGetNumSamples(samples[index]) - offset
                if available <= 0 {
                    index += 1
                    offset = 0
                    continue
                }
                let frames = min(wanted, available)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                pcm.frameLength = AVAudioFrameCount(frames)
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(samples[index], at: Int32(offset), frameCount: Int32(frames),
                                                                   into: pcm.mutableAudioBufferList) == noErr else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                offset += frames
                if offset >= CMSampleBufferGetNumSamples(samples[index]) {
                    index += 1
                    offset = 0
                }
                outStatus.pointee = .haveData
                return pcm
            }
            outStatus.pointee = .endOfStream
            return nil
        }
    }

    /// Moves every sample from the reader to the writer, each track on its own queue, then finishes the file.
    private func run(reader: AVAssetReader, writer: AVAssetWriter, output: MemoryOutput,
                     pairs: [TrackPair], duration: Double,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let activeMedia = ActiveMedia(reader: reader, writer: writer)
        guard state.withLock({ state in
            guard !state.isCancelled else { return false }
            state.activeMedia = activeMedia
            return true
        }) else { throw CancellationError() }
        defer {
            state.withLock { $0.activeMedia = nil }
        }

        guard reader.startReading(), writer.startWriting() else { throw Failure.failed }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        let state = self.state
        for (index, track) in pairs.enumerated() {
            let queue = DispatchQueue(label: "duhcord.video.\(index)", qos: .userInitiated)
            group.enter()
            let done = OSAllocatedUnfairLock(initialState: false)
            track.input.requestMediaDataWhenReady(on: queue) { [track, state, done] in
                while track.input.isReadyForMoreMediaData, !done.withLock({ $0 }) {
                    let shouldFinish: Bool
                    if state.withLock({ $0.isCancelled }) {
                        shouldFinish = true
                    } else if let sample = track.readerOutput.copyNextSampleBuffer() {
                        if index == 0, duration > 0 {
                            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                        }
                        shouldFinish = !track.input.append(sample)
                    } else {
                        shouldFinish = true
                    }
                    if shouldFinish {
                        let finished = done.withLock { finished in
                            guard !finished else { return false }
                            finished = true
                            return true
                        }
                        if finished {
                            track.input.markAsFinished()
                            group.leave()
                        }
                    }
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        if cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw Failure.failed
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw Failure.failed }
        return output.collected
    }
}
