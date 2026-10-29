import CoreGraphics
import DuhcordMediaKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class MediaDecodingTests: XCTestCase {
    func testPNGDecodesToRequestedPixelLimit() throws {
        let data = try makeImageData(type: UTType.png.identifier, frames: [(64, 32, CGColor(red: 1, green: 0, blue: 0, alpha: 1))])

        let decoded = MediaDecoding.decode(data, maxPixel: 16, allowedTypes: [UTType.png.identifier], maxSourcePixels: 4_096)

        XCTAssertNotNil(decoded)
        XCTAssertLessThanOrEqual(max(decoded?.width ?? 0, decoded?.height ?? 0), 16)
        XCTAssertEqual(decoded?.bytesPerRow, (decoded?.width ?? 0) * 4)
        XCTAssertEqual(decoded?.bgra.count, (decoded?.bytesPerRow ?? 0) * (decoded?.height ?? 0))
    }

    func testDecodeRejectsTypesOutsideAllowlist() throws {
        let data = try makeImageData(type: UTType.png.identifier, frames: [(8, 8, CGColor(red: 1, green: 0, blue: 0, alpha: 1))])

        XCTAssertNil(MediaDecoding.decode(data, maxPixel: 8, allowedTypes: [UTType.jpeg.identifier], maxSourcePixels: 100))
    }

    func testDecodeRejectsImagesOverPixelCap() throws {
        let data = try makeImageData(type: UTType.png.identifier, frames: [(8, 8, CGColor(red: 1, green: 0, blue: 0, alpha: 1))])

        XCTAssertNil(MediaDecoding.decode(data, maxPixel: 8, allowedTypes: [UTType.png.identifier], maxSourcePixels: 16))
    }

    func testDecodeFramesForTwoFrameGIF() throws {
        let data = try makeImageData(type: "com.compuserve.gif", frames: [
            (16, 12, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (16, 12, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
        ])

        let decoded = MediaDecoding.decodeFrames(data, maxPixel: 8, allowedTypes: ["com.compuserve.gif"])

        XCTAssertEqual(decoded?.frames.count, 2)
        XCTAssertEqual(decoded?.delays.count, 2)
        XCTAssertLessThanOrEqual(max(decoded?.width ?? 0, decoded?.height ?? 0), 8)
        XCTAssertEqual(decoded?.frames.first?.count, (decoded?.bytesPerRow ?? 0) * (decoded?.height ?? 0))
    }

    private func makeImageData(type: String, frames: [(width: Int, height: Int, color: CGColor)]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frames.count, nil) else {
            throw TestError.couldNotCreateImage
        }
        for frame in frames {
            guard let context = CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)) else {
                throw TestError.couldNotCreateImage
            }
            context.setFillColor(frame.color)
            context.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            guard let image = context.makeImage() else { throw TestError.couldNotCreateImage }
            if type == "com.compuserve.gif" {
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
                ] as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, image, nil)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw TestError.couldNotCreateImage }
        return data as Data
    }

    private enum TestError: Error {
        case couldNotCreateImage
    }
}
