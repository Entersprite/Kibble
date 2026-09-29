import ChatKit
import SwiftUI

/// The whole window: sidebar, transcript, composer.
///
/// Everything it draws arrives in `state`, and everything it wants arrives back
/// through `actions`. It has never heard of a database or a backend, which is
/// what makes the same view work against a fixture, a live bridge, or a server.
public struct ChatWindow: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    public init(state: ChatSceneState, actions: ChatSceneActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        NavigationSplitView {
            ConversationList(state: state, actions: actions)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                StatusStrip(state: state, actions: actions)
                if state.showingMentions {
                    MentionsPane(items: state.mentions, status: state.mentionsStatus, me: state.me) {
                        actions.openMention?($0, $1)
                    }
                } else if let conversation = state.selectedConversation {
                    // `safeAreaInset`, so the transcript scrolls under the
                    // composer rather than being hidden behind it the way an
                    // `overlay` would leave it.
                    //
                    // **A gradient, not a material.** Messages does not blur
                    // behind its field - it fades the transcript into the
                    // window's own background. Two earlier attempts got this
                    // wrong from opposite directions: `.bar` drew a flat grey
                    // slab, and `safeAreaBar` brought the system's blurred
                    // backdrop. `ComposerScrim` is the fade itself.
                    MessageList(state: state)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 0) {
                                TypingStrip(state: state)
                                composer(for: conversation)
                            }
                            .background(alignment: .bottom) { ComposerScrim() }
                        }
                } else {
                    ContentUnavailableView(
                        "Pick a conversation",
                        systemImage: "sidebar.left",
                        description: Text("Choose one from the sidebar to read it.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
    }

    /// The bar's content: the field, or why there isn't one.
    @ViewBuilder private func composer(for conversation: Conversation) -> some View {
        if state.capabilities.canSendMessages {
            Composer(
                placeholder: Display.title(
                    of: conversation,
                    directory: state.directory,
                    me: state.me
                ),
                restoring: state.failedDraft,
                onRestored: actions.draftRestored,
                send: actions.send
            )
            // The draft belongs to the conversation it was typed in. Without
            // this the branch keeps its identity across a selection change,
            // `@State draft` survives, and a half-typed line addressed to one
            // person posts to whoever was opened next. Cheap to miss,
            // expensive to send.
            .id(conversation.id)
        } else {
            // Not a disabled field: a greyed-out composer invites the user to
            // keep clicking it. Saying why is kinder.
            Text("This backend cannot send messages yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    private var title: String {
        if state.showingMentions {
            return "Mentions"
        }
        guard let conversation = state.selectedConversation else { return "GChat" }
        return Display.title(of: conversation, directory: state.directory, me: state.me)
    }

    private var subtitle: String {
        // An empty subtitle draws nothing, which is the answer when there is
        // no count worth showing.
        guard !state.showingMentions, let conversation = state.selectedConversation else { return "" }
        return Display.memberCountLabel(of: conversation) ?? ""
    }
}

/// The wash behind the composer - what Messages has instead of a blurred bar.
///
/// The window's own background, ramping from nothing to 75%, so the transcript
/// settles toward the ground it sits on rather than being brightened by a
/// white overlay.
///
/// **What this can and cannot do.** Painting the background over its own ground
/// is invisible by construction - the empty part of the transcript will not
/// change at any opacity. The only thing this affects is *content*: message
/// bubbles passing behind the composer fade toward the background. That is the
/// whole effect, and it is why very low values read as nothing happening. A
/// visible band, as opposed to a fade, needs a colour that differs from the
/// background - a white lift or a black shadow - not the background itself.
///
/// A mask rather than colours in the gradient, because the semantic
/// `.background` is a `ShapeStyle` and cannot be a `LinearGradient` stop. The
/// mask's alpha is the fill's opacity, so `.black.opacity(0.75)` paints the
/// background at 75% - and it follows the appearance, which a literal colour
/// would not. This package builds for iOS too.
///
/// `alignment: .bottom` plus `ignoresSafeArea(edges: .bottom)` at the call site
/// carries it into the window's bottom safe area, so the wash reaches the edge
/// rather than stopping at the composer's own bounds.
struct ComposerScrim: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.30), location: 0.55),
                        .init(color: .black.opacity(0.75), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
    }
}

/// Connection and errors, read from the store like everything else - which is
/// why a view can show them without ever touching a backend.
struct StatusStrip: View {
    let state: ChatSceneState
    /// Required rather than defaulted: a defaulted `ChatSceneActions()` has no
    /// `signIn`, so a call site that forgot it would silently draw a banner
    /// with no way out - which is the bug this parameter exists to fix.
    let actions: ChatSceneActions

    var body: some View {
        // `banner` (a real problem) takes priority over `notice` (a clean
        // diagnostic run that merely finished) - nothing sets both at once
        // today, but a warning worth acting on must never be the one that
        // loses if that ever changes.
        if let message = banner {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                    Spacer()
                    // Drawn only where the host offered one, and only once
                    // `ConnectionBanner.offersReconnect` says the wait has
                    // earned it - see `ChatSceneActions.reconnect`.
                    if canReconnect, let reconnect = actions.reconnect {
                        Button("Reconnect now", action: reconnect)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    // Drawn only where the host offered one. A window with no
                    // route back to sign-in is a window a person can only
                    // escape by editing their Keychain - see
                    // `ChatSceneActions.signIn`.
                    if let signIn = actions.signIn {
                        Button("Sign in again", action: signIn)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                // Secondary, never the headline - diagnostic only (spec §8).
                // Drawn only when there is one, so the banner's height is
                // unchanged whenever there is nothing to add.
                if let detail = bannerDetail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.yellow.opacity(0.22))
        } else if let notice = state.notice {
            // Neither the triangle nor the yellow wash: this is what closes
            // the finding that a clean `--probe=keychain` run drew exactly
            // like a failure. A different icon and background are the whole
            // fix - the words already said "written to a file", not "wrong".
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text(notice)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.12))
        }
    }

    private var banner: String? {
        // A real error outranks a connection state: `lastError` is what a
        // client can act on (sign in again, retry a send), and a connection
        // banner under it would be true but beside the point.
        if let error = state.lastError {
            return description(of: error)
        }
        return ConnectionBanner.text(for: state.connection)
    }

    /// Same precedence as `banner`: a real error's own description already
    /// carries everything relevant (a status code, a capability name), so
    /// there is no separate diagnostic line to add underneath it.
    private var bannerDetail: String? {
        guard state.lastError == nil else { return nil }
        return ConnectionBanner.detail(for: state.connection)
    }

    private var canReconnect: Bool {
        ConnectionBanner.offersReconnect(for: state.connection)
    }

    /// Rendered here rather than stored as a string, because the store keeps
    /// the error typed so a client can tell "sign in again" from a hiccup.
    private func description(of error: ChatError) -> String {
        switch error {
        case .notAuthenticated, .sessionExpired: "Signed out. Sign in again to keep syncing."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Rate limited. Retrying in \($0)." } ?? "Rate limited."
        case let .unsupported(capability): "This backend cannot \(capability)."
        case let .transport(message): "Connection problem: \(message)"
        case let .decoding(message): "Could not read a message: \(message)"
        case let .server(status, message): "Server error \(status): \(message)"
        case let .unknown(message): message
        }
    }
}

struct TypingStrip: View {
    let state: ChatSceneState

    var body: some View {
        if !state.typing.isEmpty {
            let names = state.typing.map { Display.name(of: $0, in: state.directory) }
            Text(names.count == 1 ? "\(names[0]) is typing…" : "\(names.count) people are typing…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }
}
