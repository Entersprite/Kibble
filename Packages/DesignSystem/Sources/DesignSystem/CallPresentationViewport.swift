import SwiftUI

/// Zoom and pan within the received presentation. The normalized offset keeps
/// its bounds when the user resizes the call window or reveals the filmstrip.
struct CallPresentationViewportState {
    static let maximumScale: CGFloat = 4
    static let zoomStep: CGFloat = 1.25
    private(set) var scale: CGFloat = 1
    private var centerOffset = CGSize.zero

    var isZoomed: Bool {
        scale > 1
    }

    mutating func zoom(by factor: CGFloat, around anchor: UnitPoint = .center) {
        guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
        let next = min(Self.maximumScale, max(1, scale * factor))
        let ratio = next / scale
        let origin = UnitPoint(x: anchor.x - 0.5, y: anchor.y - 0.5)
        scale = next
        centerOffset = bounded(
            width: (centerOffset.width - origin.x) * ratio + origin.x,
            height: (centerOffset.height - origin.y) * ratio + origin.y
        )
    }

    mutating func pan(by translation: CGSize, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pan(horizontal: translation.width / size.width, vertical: translation.height / size.height)
    }

    mutating func pan(horizontal: CGFloat, vertical: CGFloat) {
        guard horizontal.isFinite, vertical.isFinite else { return }
        centerOffset = bounded(width: centerOffset.width + horizontal, height: centerOffset.height + vertical)
    }

    func offset(in size: CGSize) -> CGSize {
        CGSize(width: centerOffset.width * size.width, height: centerOffset.height * size.height)
    }

    private func bounded(width: CGFloat, height: CGFloat) -> CGSize {
        let limit = (scale - 1) / 2
        return CGSize(width: min(limit, max(-limit, width)), height: min(limit, max(-limit, height)))
    }
}

struct CallPresentationViewport: View {
    let video: CallRemoteVideo
    @Binding var selection: CallStageSelection
    @State var viewport = CallPresentationViewportState()
    @GestureState private var magnification: MagnifyGesture.Value?
    @GestureState private var translation = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let displayed = displayedViewport(in: size)
            ZStack {
                Color.black
                video.content
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(displayed.scale)
                    .offset(displayed.offset(in: size))
                    .allowsHitTesting(false)
                if viewport.isZoomed {
                    Color.clear.contentShape(Rectangle()).gesture(drag(in: size))
                } else {
                    Color.clear.contentShape(Rectangle()).windowDragArea()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .simultaneousGesture(pinch)
            .overlay(alignment: .topLeading) {
                controls.padding(.leading, 16).padding(.top, 44)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private var controls: some View {
        Menu {
            CallEnlargePresentationButton(video: video, selection: $selection)
            Divider()
            Text("Zoom \(Int((viewport.scale * 100).rounded()))%")
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                viewport.zoom(by: CallPresentationViewportState.zoomStep)
            }
            .disabled(viewport.scale >= CallPresentationViewportState.maximumScale)
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                viewport.zoom(by: 1 / CallPresentationViewportState.zoomStep)
            }
            .disabled(!viewport.isZoomed)
            Button("Actual Size", systemImage: "arrow.counterclockwise") {
                viewport = CallPresentationViewportState()
            }
            .disabled(!viewport.isZoomed)
            if viewport.isZoomed {
                Menu("Pan") {
                    Button("Left", systemImage: "arrow.left") { viewport.pan(horizontal: 0.25, vertical: 0) }
                    Button("Right", systemImage: "arrow.right") {
                        viewport.pan(horizontal: -0.25, vertical: 0)
                    }
                    Button("Up", systemImage: "arrow.up") { viewport.pan(horizontal: 0, vertical: 0.25) }
                    Button("Down", systemImage: "arrow.down") { viewport.pan(horizontal: 0, vertical: -0.25) }
                }
            }
        } label: {
            CallRoundFace(title: "Presentation View", symbol: "magnifyingglass", tone: .plain, size: 34)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Presentation View")
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, state, _ in state = value }
            .onEnded { value in viewport.zoom(by: value.magnification, around: value.startAnchor) }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in viewport.pan(by: value.translation, in: size) }
    }

    private func displayedViewport(in size: CGSize) -> CallPresentationViewportState {
        var result = viewport
        if let magnification {
            result.zoom(by: magnification.magnification, around: magnification.startAnchor)
        }
        result.pan(by: translation, in: size)
        return result
    }
}
