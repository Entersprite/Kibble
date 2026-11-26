import SwiftUI

enum CallSelfViewSurface: Equatable {
    case hidden, grid, filmstrip, floating, minimized

    var isFloating: Bool {
        self == .floating || self == .minimized
    }
}

extension CallSelfViewPreferences.Placement {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .floating: "Floating"
        case .tile: "In a Tile"
        }
    }
}

extension CallSelfViewPreferences.Corner {
    var title: String {
        switch self {
        case .topTrailing: "Top Right"
        case .topLeading: "Top Left"
        case .bottomTrailing: "Bottom Right"
        case .bottomLeading: "Bottom Left"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topTrailing: .topTrailing
        case .topLeading: .topLeading
        case .bottomTrailing: .bottomTrailing
        case .bottomLeading: .bottomLeading
        }
    }

    static func nearest(to point: CGPoint, in size: CGSize) -> Self {
        let trailing = point.x >= size.width / 2
        if point.y < size.height / 2 {
            return trailing ? .topTrailing : .topLeading
        }
        return trailing ? .bottomTrailing : .bottomLeading
    }
}

struct CallSelfViewControls: View {
    @Binding var selection: CallStageSelection
    var save: ((CallLayoutPreferences) -> Void)?
    let isFloating: Bool

    var body: some View {
        // Where it sits is checked in place; the corner is a submenu, since
        // dragging the preview is the usual way to move it.
        Picker("Placement", selection: settings.selfView.placement) {
            ForEach(CallSelfViewPreferences.Placement.allCases, id: \.self) {
                Text($0.title).tag($0)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        if isFloating {
            Picker("Corner", selection: settings.selfView.corner) {
                ForEach(CallSelfViewPreferences.Corner.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.menu)
        }
        if isFloating || selection.supportsSelfCrop {
            Divider()
        }
        if isFloating {
            Button(
                selection.minimizesSelf ? "Restore Self View" : "Minimize Self View",
                systemImage: selection.minimizesSelf ? "arrow.up.left.and.arrow.down.right" : "minus"
            ) {
                selection.minimizesSelf.toggle()
            }
        }
        if selection.supportsSelfCrop {
            Toggle("Crop to Fill", isOn: settings.selfView.cropped)
        }
    }

    private var settings: Binding<CallLayoutPreferences> {
        Binding(get: { selection.layoutPreferences }, set: {
            selection.layoutPreferences = $0
            save?($0)
        })
    }
}

/// Keeps the floating preview, share preview and filmstrip in the existing
/// call window. A preview in the lower right leaves room at the strip's end.
struct CallVideoOverlays: View {
    static let coordinateSpace = "callVideoOverlays"
    static let minimizedSize: CGFloat = 38
    let selfPreview: AnyView?
    var ownHandRaised = false
    let share: CallSharingPreview?
    let alongside: [CallRemoteVideo]
    let roster: [CallRosterEntry]?
    let width: CGFloat
    @Binding var selection: CallStageSelection
    var saveLayout: ((CallLayoutPreferences) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let corner = selection.layoutPreferences.selfView.corner
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    if let selfPreview, corner == .topTrailing {
                        floating(selfPreview, in: proxy.size)
                    }
                    if let share {
                        share.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                    }
                    if !alongside.isEmpty {
                        CallVideoFilmstrip(
                            videos: alongside, roster: roster, width: width,
                            selection: $selection, saveLayout: saveLayout
                        )
                        .padding(.bottom, stripBottomInset)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.top, CallLayout.titlebarGap)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                if let selfPreview, corner != .topTrailing {
                    floating(selfPreview, in: proxy.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                        .padding(.horizontal, 16)
                        .padding(.top, 84)
                        .padding(.bottom, 88)
                }
            }
            .coordinateSpace(.named(Self.coordinateSpace))
        }
    }

    private var stripBottomInset: CGFloat {
        guard selfPreview != nil, selection.layoutPreferences.selfView.corner == .bottomTrailing
        else { return 88 }
        return 100 + (selection.minimizesSelf ? Self.minimizedSize : width * 9 / 16)
    }

    private func floating(_ preview: AnyView, in size: CGSize) -> some View {
        CallFloatingSelfView(
            content: preview, width: width, size: size, handRaised: ownHandRaised,
            selection: $selection, save: saveLayout
        )
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private struct CallFloatingSelfView: View {
    let content: AnyView
    let width: CGFloat
    let size: CGSize
    let handRaised: Bool
    @Binding var selection: CallStageSelection
    var save: ((CallLayoutPreferences) -> Void)?
    @GestureState private var translation = CGSize.zero

    var body: some View {
        Group {
            if selection.minimizesSelf {
                CallRoundButton(
                    title: "Restore Self View",
                    symbol: "video",
                    size: CallVideoOverlays.minimizedSize
                ) {
                    selection.minimizesSelf = false
                }
            } else {
                content
                    .allowsHitTesting(false)
                    .frame(width: width, height: (width * 9 / 16).rounded())
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if handRaised {
                            CallRaisedHandGlyph().padding(8)
                                .background(.black.opacity(0.65), in: .circle).padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                    .accessibilityElement()
                    .accessibilityLabel(handRaised ? "Your camera preview, hand raised" :
                        "Your camera preview")
            }
        }
        .contentShape(Rectangle())
        .offset(translation)
        .simultaneousGesture(
            DragGesture(coordinateSpace: .named(CallVideoOverlays.coordinateSpace))
                .updating($translation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    selection.layoutPreferences.selfView.corner = .nearest(to: value.location, in: size)
                    save?(selection.layoutPreferences)
                }
        )
        .contextMenu {
            CallSelfViewControls(selection: $selection, save: save, isFloating: true)
        }
    }
}
