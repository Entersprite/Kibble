import ChatKit
import SwiftUI

/// Who is calling, as the incoming call panel shows it. `name` and `person`
/// are absent when the conversation's notifications hide previews.
public struct IncomingCallPanelContent: Equatable, Sendable {
    public let callID: UUID
    public let memberID: Member.ID
    public var name: String?
    public var person: Member?
    /// Which account is being called, while several are connected.
    public var accountLabel: String?
    /// Another account's call holds this Mac's microphone and speaker:
    /// answering ends it, and the panel says so.
    public var endsOtherCall: Bool
    /// Why the last answer or decline did not go through, while the call
    /// still rings: the panel is often all the person can see of it.
    public var problem: String?

    public init(
        callID: UUID, memberID: Member.ID, name: String?, person: Member?, accountLabel: String? = nil,
        endsOtherCall: Bool = false, problem: String? = nil
    ) {
        self.callID = callID
        self.memberID = memberID
        self.name = name
        self.person = person
        self.accountLabel = accountLabel
        self.endsOtherCall = endsOtherCall
        self.problem = problem
    }
}

/// The panel's size, which the host's window takes, with room around the
/// glass for its shadow and the close button that sits on its corner.
public enum IncomingCallPanelLayout {
    public static let panel = CGSize(width: 356, height: 70)
    public static let margin: CGFloat = 10
    public static var window: CGSize {
        CGSize(width: panel.width + margin * 2, height: panel.height + margin * 2)
    }
}

/// An incoming call in the top-right corner, over whatever the person is
/// doing: who is calling, Decline and Accept. The macOS take on the banner
/// FaceTime and Phone use, which CallKit does not offer Mac apps.
///
/// The host reports hover, because SwiftUI's own hover tracking follows the
/// key window, and this panel never becomes key in an app that is not active.
public struct IncomingCallPanelView: View {
    private let imageLoader: SceneImageLoader?
    private let content: IncomingCallPanelContent
    private let isHovering: Bool
    private let accept: () -> Void
    private let decline: () -> Void
    private let open: () -> Void
    private let dismiss: () -> Void

    public init(
        content: IncomingCallPanelContent, isHovering: Bool,
        accept: @escaping () -> Void, decline: @escaping () -> Void,
        open: @escaping () -> Void, dismiss: @escaping () -> Void, imageLoader: SceneImageLoader? = nil
    ) {
        self.imageLoader = imageLoader
        self.content = content
        self.isHovering = isHovering
        self.accept = accept
        self.decline = decline
        self.open = open
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            caller
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                CallRoundButton(
                    title: "Decline", symbol: "phone.down.fill", tone: .end, size: 38, action: decline
                )
                CallRoundButton(
                    title: content.endsOtherCall ? "End Call and Answer" : "Accept",
                    symbol: "phone.fill", tone: .accept, size: 38, rings: true, action: accept
                )
            }
        }
        .padding(.horizontal, 14)
        .frame(width: IncomingCallPanelLayout.panel.width, height: IncomingCallPanelLayout.panel.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topLeading) {
            if isHovering {
                Button(action: dismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss without declining")
                .offset(x: -6, y: -6)
                .transition(.opacity)
            }
        }
        .environment(\.sceneImageLoader, imageLoader)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .padding(IncomingCallPanelLayout.margin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.name.map { "Incoming call from \($0)" } ?? "Incoming call")
    }

    /// Clicking who is calling opens the call window, as a notification's
    /// body does. A plain button, so the whole area, gaps included, takes the
    /// first click the host lets through.
    ///
    /// The last line can take two lines: the panel cannot grow, and a
    /// failure such as "Another call is already using this device." needs
    /// more than this column's width. A long account name gives up its own
    /// middle instead, keeping both of its ends and all of "Kibble call".
    private var caller: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.name ?? "Incoming call")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text(content.name == nil ? "Kibble" : "Kibble call")
                            .fixedSize()
                        if let account = content.accountLabel {
                            Text(" · \(account)")
                                .truncationMode(.middle)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let problem = content.problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if content.endsOtherCall {
                        Text("Answering ends your other call")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAction(named: "Show Call", open)
    }

    @ViewBuilder private var avatar: some View {
        if let name = content.name {
            let directory = [
                content.memberID: content.person ?? Member(
                    id: content.memberID,
                    kind: .human,
                    displayName: name
                )
            ]
            Avatar(member: content.memberID, directory: directory, size: 42)
                .accessibilityHidden(true)
        } else {
            UnknownPersonGlyph(size: 42)
                .accessibilityHidden(true)
        }
    }
}
