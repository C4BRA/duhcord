import DuhcordMediaKit
import Foundation

final class MediaDecoderService: NSObject, DuhcordMediaDecoderProtocol {
    private let decodingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    func decode(_ data: Data, maxPixel: Int, allowedTypes: [String], maxSourcePixels: Int,
                reply: @escaping @Sendable (Data?, Int, Int, Int) -> Void) {
        decodingQueue.addOperation {
            guard let decoded = MediaDecoding.decode(data, maxPixel: maxPixel, allowedTypes: allowedTypes,
                                                     maxSourcePixels: maxSourcePixels) else {
                reply(nil, 0, 0, 0)
                return
            }
            reply(decoded.bgra, decoded.width, decoded.height, decoded.bytesPerRow)
        }
    }

    func decodeFrames(_ data: Data, maxPixel: Int, allowedTypes: [String], maxFrames: Int, maxTotalBytes: Int,
                      reply: @escaping @Sendable ([Data]?, [Double], Int, Int, Int) -> Void) {
        decodingQueue.addOperation {
            guard let decoded = MediaDecoding.decodeFrames(data, maxPixel: maxPixel, allowedTypes: allowedTypes,
                                                           maxFrames: maxFrames, maxTotalBytes: maxTotalBytes) else {
                reply(nil, [], 0, 0, 0)
                return
            }
            reply(decoded.frames, decoded.delays, decoded.width, decoded.height, decoded.bytesPerRow)
        }
    }
}
