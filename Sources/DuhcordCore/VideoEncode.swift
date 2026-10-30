import Foundation

/// How large and how fast to encode a video so it stays watchable inside an upload budget.
///
/// 30 fps is kept while the long edge can stay at least 480 and the picture still gets about
/// 0.045 bits per pixel per frame. Below that the rate drops to 24, then 15. Only at 15 fps
/// may the long edge go down to 426. Callers refuse anything under 120 kbps of video.
public enum VideoEncode {
    public static let minVideoBitrate: Double = 120_000
    /// Mono AAC. Speech stays intelligible; music is thinner than the 96 and 128 kbps steps.
    public static let minAudioBitrate: Double = 32_000
    /// Below this, at the chosen size and rate, motion turns into blocks.
    static let minBitsPerPixel = 0.045

    public struct Picture: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var fps: Int

        public var longest: Double { max(width, height) }
    }

    /// 128 kbps while the file can afford it, then 96, then the floor. Silent clips spend nothing here.
    public static func audioBitrate(budget: Double, hasAudio: Bool) -> Double {
        guard hasAudio else { return 0 }
        if budget > 1_500_000 { return 128_000 }
        if budget > 600_000 { return 96_000 }
        return minAudioBitrate
    }

    /// Never larger than the source, and never faster than it (unknown frame rate counts as 30).
    public static func picture(width: Double, height: Double, videoBitrate: Double, sourceFPS: Double, hevc: Bool) -> Picture {
        // HEVC needs about 70% of H.264's bitrate for the same picture.
        let effective = hevc ? videoBitrate / 0.7 : videoBitrate
        let source = sourceFPS > 0 ? Int(min(30, max(1, sourceFPS.rounded()))) : 30
        var rates: [Int] = []
        for rate in [30, 24, 15] {
            let capped = min(source, rate)
            if capped >= 1, !rates.contains(capped) { rates.append(capped) }
        }
        if rates.isEmpty { rates = [1] }

        for fps in rates {
            // Past 480 only once the clip is already at 15 fps. A larger, slower picture beats a tiny 30 fps one.
            let edges: [Double] = fps <= 15 ? [1920, 1280, 960, 720, 640, 480, 426] : [1920, 1280, 960, 720, 640, 480]
            for edge in edges {
                let fitted = fit(width: width, height: height, longest: edge)
                if bitsPerPixel(fitted, fps: fps, bitrate: effective) >= minBitsPerPixel {
                    return Picture(width: fitted.width, height: fitted.height, fps: fps)
                }
            }
        }
        let fitted = fit(width: width, height: height, longest: 426)
        return Picture(width: fitted.width, height: fitted.height, fps: min(rates.last ?? 15, 15))
    }

    private struct Size {
        var width: Double
        var height: Double
    }

    private static func fit(width: Double, height: Double, longest: Double) -> Size {
        let longSide = max(width, height)
        let scale = longSide > 0 ? min(1, longest / longSide) : 1
        return Size(width: even(width * scale), height: even(height * scale))
    }

    private static func even(_ value: Double) -> Double {
        Double(max(2, Int((value / 2).rounded()) * 2))
    }

    private static func bitsPerPixel(_ size: Size, fps: Int, bitrate: Double) -> Double {
        let pixels = size.width * size.height
        guard pixels > 0, fps > 0 else { return 0 }
        return bitrate / (pixels * Double(fps))
    }
}
