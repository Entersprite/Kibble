import CoreGraphics
import Testing
@testable import MacHost

struct NativeScreenFrameCropTests {
    @Test func aWindowUsesOnlyItsPointScaledContentOnTheVideoSurface() {
        let content = CGRect(x: 1, y: 1, width: 300.5, height: 201.75)
        let crop = NativeScreenFrameCrop.bounds(content, scale: 2, width: 1280, height: 720)
        #expect(crop == CGRect(x: 2, y: 2, width: 600, height: 402))
    }

    @Test func aCropStaysInsideTheSurfaceAndUsesEvenChromaBoundaries() {
        let content = CGRect(x: -5, y: 3, width: 300, height: 200)
        let crop = NativeScreenFrameCrop.bounds(content, scale: 1, width: 200, height: 100)
        #expect(crop == CGRect(x: 0, y: 4, width: 200, height: 96))
        #expect(NativeScreenFrameCrop.bounds(content, scale: .nan, width: 200, height: 100) == nil)
        #expect(NativeScreenFrameCrop.bounds(.null, scale: 1, width: 200, height: 100) == nil)
    }
}
