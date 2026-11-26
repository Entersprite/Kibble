import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// GIF bytes for tests: one solid frame per color, each shown for `delay`.
enum TestGIF {
    static func make(frames: Int, side: Int, delay: Double = 0.1) throws -> Data {
        try make(
            colors: (0 ..< frames).map { (red: CGFloat($0) / CGFloat(max(frames, 1)), green: 0) },
            side: side, delay: delay
        )
    }

    static func make(
        colors: [(red: CGFloat, green: CGFloat)],
        side: Int,
        delay: Double = 0.1
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, colors.count, nil
        ))
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for color in colors {
            context.setFillColor(CGColor(red: color.red, green: color.green, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
