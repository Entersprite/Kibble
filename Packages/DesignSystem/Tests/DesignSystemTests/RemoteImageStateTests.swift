import CoreGraphics
import Foundation
import Testing
@testable import DesignSystem

/// Review finding 2: a picture loaded for one URL never stands in for
/// another, so an app card updated in place shows its new image.
struct RemoteImageStateTests {
    private static let first = URL(string: "https://acme.example/a.png")!
    private static let second = URL(string: "https://acme.example/b.png")!

    private static func pixel() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private static func isLoading(_ phase: RemoteImagePhase) -> Bool {
        if case .loading = phase {
            return true
        }
        return false
    }

    private static func isLoaded(_ phase: RemoteImagePhase) -> Bool {
        if case .loaded = phase {
            return true
        }
        return false
    }

    private static func isFailed(_ phase: RemoteImagePhase) -> Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    @Test func aLoadedImageCountsOnlyForItsOwnURL() throws {
        var state = RemoteImageState()
        state.loaded = try (Self.first, Self.pixel())
        #expect(Self.isLoaded(state.phase(for: Self.first)))
        #expect(Self.isLoading(state.phase(for: Self.second)))
    }

    @Test func aFailureCountsOnlyForItsOwnURL() {
        var state = RemoteImageState()
        state.failed = Self.first
        #expect(Self.isFailed(state.phase(for: Self.first)))
        #expect(Self.isLoading(state.phase(for: Self.second)))
    }
}
