#if os(macOS)
    import AppKit
    import Observation
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct CallMicrophoneLevelPopoverTests {
        @Test func muteDismissalAndAnInputChangeCancelTheCurrentRead() async {
            let meter = MeterFixture()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MeterAnchor(meter: meter))
            window.orderFront(nil)
            defer { window.close() }

            #expect(meter.reads == 0)
            meter.request = meter.id
            #expect(await eventually { meter.reads == 1 })
            meter.isMuted = true
            #expect(await eventually { meter.cancellations == 1 })
            #expect(meter.reads == 1)
            meter.isMuted = false
            #expect(await eventually { meter.reads == 2 })
            meter.request = nil
            #expect(await eventually { meter.cancellations == 2 })
            meter.request = meter.id
            #expect(await eventually { meter.reads == 3 })
            meter.id = UUID()
            #expect(await eventually { meter.cancellations == 3 })
            #expect(meter.reads == 3)
        }

        private func eventually(_ condition: () -> Bool) async -> Bool {
            for _ in 0 ..< 200 {
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
    }

    @MainActor
    @Observable
    private final class MeterFixture {
        var id = UUID()
        var request: UUID?
        var isMuted = false
        @ObservationIgnored var reads = 0
        @ObservationIgnored var cancellations = 0

        func read() async -> Double? {
            reads += 1
            do {
                try await Task.sleep(for: .seconds(8))
                return 0.3
            } catch {
                cancellations += 1
                return nil
            }
        }
    }

    private struct MeterAnchor: View {
        @Bindable var meter: MeterFixture

        var body: some View {
            Button("Microphone Level…") { meter.request = meter.id }
                .modifier(CallMicrophoneLevelPopover(
                    action: .init(id: meter.id, isMuted: meter.isMuted, read: meter.read),
                    request: $meter.request
                ))
                .padding(28)
        }
    }
#endif
