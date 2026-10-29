import AppKit
import AVFoundation
import CoreImage
import DuhcordCore
import UniformTypeIdentifiers
import VideoToolbox

/// Turns a video the user attached into what's sent, written straight to memory (a fragmented MP4) so it never
/// touches the disk:
/// - Only the picture and sound are copied, so location, camera details and other metadata stay behind.
/// - With "Compress videos" on (the default), a video that's too large is re-encoded with the Mac's hardware
///   encoder at a bitrate worked out from its length and the account's upload limit, at a resolution that suits
///   that bitrate, capped at 30 fps. A video that already fits is only repackaged, which keeps its quality.
/// - H.264 outside Private, which every Discord app plays; HEVC in Private (only Duhcord decrypts those, and
///   every Mac it runs on plays HEVC), for better quality at the same size.
final class VideoPrep {
    struct Options {
        /// What the file may come to.
        let limit: Int
        let compress: Bool
        /// Private: HEVC, and nothing it can't play.
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

    /// Below this the picture falls apart, so the video is refused instead.
    private static let minVideoBitrate = 200_000.0
    /// Leaves room for the container and for the encoder landing a little over its target.
    private static let headroom = 0.92

    private let lock = NSLock()
    private var isCancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    /// Stops the work; `prepare` then throws CancellationError.
    func cancel() {
        lock.lock()
        isCancelled = true
        let reader = reader, writer = writer
        lock.unlock()
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Off the main thread. `progress` (0...1) is called from a background queue.
    func prepare(_ url: URL, name: String, options: Options, progress: @escaping (Double) -> Void) async throws -> PreparedAttachment {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.1,
              let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let (natural, transform, frameRate, formats) = try await video.load(.naturalSize, .preferredTransform,
                                                                            .nominalFrameRate, .formatDescriptions)
        let shown = natural.applying(transform)
        let display = CGSize(width: abs(shown.width), height: abs(shown.height))
        guard display.width >= 2, display.height >= 2 else { throw Failure.unreadable }
        let thumbnail = await Self.thumbnail(asset)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max

        func finish(_ data: Data, size: CGSize) -> PreparedAttachment {
            PreparedAttachment(data: data, width: Int(size.width), height: Int(size.height), kind: .mp4,
                               thumbnail: thumbnail, name: name, duration: duration)
        }

        // Already small enough, in a format the recipients can play: only repackaged.
        let codec = formats.first.map(CMFormatDescriptionGetMediaSubType)
        let playable = codec == kCMVideoCodecType_H264 || (options.forPrivate && codec == kCMVideoCodecType_HEVC)
        if playable, fileSize <= options.limit || !options.compress,
           let data = try? await remux(asset, video: video, audio: audio, transform: transform, progress: progress),
           data.count <= options.limit {
            return finish(data, size: display)
        }
        guard options.compress else {
            if cancelled { throw CancellationError() }
            throw playable ? Failure.tooLarge(limit: options.limit) : Failure.unreadable
        }

        // Bits per second the file can afford, less the sound.
        let budget = Double(options.limit) * Self.headroom * 8 / duration
        let audioBitrate: Double = audio.isEmpty ? 0 : (budget > 1_500_000 ? 128_000 : budget > 600_000 ? 96_000 : 48_000)
        var videoBitrate = budget - audioBitrate
        guard videoBitrate >= Self.minVideoBitrate else {
            let maxSeconds = Double(options.limit) * Self.headroom * 8 / (Self.minVideoBitrate + 48_000)
            throw Failure.tooLong(maxMinutes: Int(maxSeconds / 60))
        }
        // Unknown (0) counts as 30.
        let fps: Int32 = frameRate > 0 ? Int32(min(30, max(1, frameRate.rounded()))) : 30
        // Up to three tries: if the encoder overshoots, the next aims lower by as much as it went over.
        for attempt in 0..<3 {
            let size = Self.outputSize(display, bitrate: videoBitrate, hevc: options.forPrivate)
            let data = try await encode(asset, video: video, audio: audio, size: size, transform: transform, fps: fps,
                                        videoBitrate: videoBitrate, audioBitrate: audioBitrate, hevc: options.forPrivate,
                                        duration: duration) { fraction in
                progress((Double(attempt) + fraction) / Double(attempt + 1))
            }
            if data.count <= options.limit { return finish(data, size: size) }
            videoBitrate *= Double(options.limit) * Self.headroom / Double(data.count)
            guard videoBitrate >= Self.minVideoBitrate else { break }
        }
        throw Failure.tooLong(maxMinutes: Int(duration / 60 * 0.75))
    }

    /// The largest size the bitrate can carry well, never larger than the original, in even numbers of pixels.
    static func outputSize(_ display: CGSize, bitrate: Double, hevc: Bool) -> CGSize {
        // HEVC needs about 70% of H.264's bitrate for the same picture.
        let effective = hevc ? bitrate / 0.7 : bitrate
        let longest: Double
        switch effective {
        case 4_500_000...: longest = 1920
        case 2_000_000...: longest = 1280
        case 1_000_000...: longest = 960
        case 500_000...: longest = 720
        default: longest = 640
        }
        let scale = min(1, longest / Double(max(display.width, display.height)))
        func even(_ value: Double) -> CGFloat { CGFloat(max(2, Int((value * scale / 2).rounded()) * 2)) }
        return CGSize(width: even(display.width), height: even(display.height))
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
    private final class MemoryOutput: NSObject, AVAssetWriterDelegate {
        private let lock = NSLock()
        private var data = Data()

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                         segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            lock.lock()
            data.append(segmentData)
            lock.unlock()
        }

        var collected: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private func makeWriter(_ output: MemoryOutput) -> AVAssetWriter {
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4CMAFCompliant
        writer.preferredOutputSegmentInterval = CMTime(seconds: 4, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        writer.shouldOptimizeForNetworkUse = true
        writer.delegate = output
        return writer
    }

    /// The same picture and sound in a new file: nothing re-encoded, nothing else copied.
    private func remux(_ asset: AVAsset, video: AVAssetTrack, audio: [AVAssetTrack], transform: CGAffineTransform,
                       progress: @escaping (Double) -> Void) async throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let output = MemoryOutput()
        let writer = makeWriter(output)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
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
            pairs.append((readerOutput, input))
        }
        let duration = try await asset.load(.duration).seconds
        return try await run(reader: reader, writer: writer, output: output, pairs: pairs, duration: duration, progress: progress)
    }

    private func encode(_ asset: AVAsset, video: AVAssetTrack, audio: [AVAssetTrack], size: CGSize,
                        transform: CGAffineTransform, fps: Int32,
                        videoBitrate: Double, audioBitrate: Double, hevc: Bool, duration: Double,
                        progress: @escaping (Double) -> Void) async throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let output = MemoryOutput()
        let writer = makeWriter(output)

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
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(videoBitrate),
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoProfileLevelKey: hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw Failure.failed }
        reader.add(videoOutput)
        writer.add(videoInput)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

        if !audio.isEmpty {
            let channels = audioBitrate <= 48_000 ? 1 : 2
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: Int(audioBitrate),
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pairs.append((audioOutput, audioInput))
            }
        }
        return try await run(reader: reader, writer: writer, output: output, pairs: pairs, duration: duration, progress: progress)
    }

    /// Moves every sample from the reader to the writer, each track on its own queue, then finishes the file.
    private func run(reader: AVAssetReader, writer: AVAssetWriter, output: MemoryOutput,
                     pairs: [(AVAssetReaderOutput, AVAssetWriterInput)], duration: Double,
                     progress: @escaping (Double) -> Void) async throws -> Data {
        lock.lock()
        if isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.reader = reader
        self.writer = writer
        lock.unlock()
        defer {
            lock.lock()
            self.reader = nil
            self.writer = nil
            lock.unlock()
        }

        guard reader.startReading(), writer.startWriting() else { throw Failure.failed }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        for (index, pair) in pairs.enumerated() {
            let (readerOutput, input) = pair
            let queue = DispatchQueue(label: "duhcord.video.\(index)", qos: .userInitiated)
            group.enter()
            var done = false
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                while input.isReadyForMoreMediaData, !done {
                    if self?.cancelled ?? true {
                        done = true
                    } else if let sample = readerOutput.copyNextSampleBuffer() {
                        if index == 0, duration > 0 {
                            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                        }
                        if !input.append(sample) { done = true }
                    } else {
                        done = true
                    }
                    if done {
                        input.markAsFinished()
                        group.leave()
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
