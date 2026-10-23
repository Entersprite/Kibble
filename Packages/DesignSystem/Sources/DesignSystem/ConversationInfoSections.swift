import ChatKit
import Foundation

/// One page of the Conversation Info sheet, in sidebar order.
enum InfoSection: Hashable, CaseIterable {
    case people, details, settings, integrations

    var title: String {
        switch self {
        case .people: "People"
        case .details: "Details"
        case .settings: "Settings"
        case .integrations: "Integrations"
        }
    }

    var systemImage: String {
        switch self {
        case .people: "person.2"
        case .details: "info.circle"
        case .settings: "gearshape"
        case .integrations: "puzzlepiece.extension"
        }
    }
}

/// Which sections a conversation has. A section it doesn't have is absent,
/// never shown disabled. Kind and advertised capability are separate gates;
/// what the server allows is checked again by each section's controls.
enum ConversationInfoSections {
    /// - Parameter hasParticipants: whether a participant list is on its way or
    ///   loaded. Meet chats and app conversations list People only then.
    static func available(
        for details: ConversationDetails,
        capabilities: Capabilities,
        hasParticipants: Bool = true
    ) -> [InfoSection] {
        let integrations = capabilities.canManageConversationApps
            || capabilities.canManageConversationWebhooks
        var sections: [InfoSection]
        switch details.conversation.kind {
        case .space:
            sections = [.people, .details]
            if details.settings != nil {
                sections.append(.settings)
            }
        case .groupDirectMessage:
            sections = [.people, .details]
        case .directMessage:
            sections = [.people]
        default:
            sections = hasParticipants ? [.people, .details] : [.details]
        }
        if integrations {
            sections.append(.integrations)
        }
        return sections
    }
}

/// The sheet's one-draft rule: only the current section can hold unsaved
/// edits, and leaving it (another section, or closing) asks first.
struct InfoDraftState: Equatable {
    var dirtySection: InfoSection?
    /// What goes ahead once the alert's Save has landed and the section is clean.
    private(set) var afterSave: Request?
    private var saveStarted = false

    enum Request: Equatable {
        case switchTo(InfoSection)
        case close
    }

    init(dirtySection: InfoSection? = nil) {
        self.dirtySection = dirtySection
    }

    /// Whether `request` can go ahead now or must ask Save / Don't Save /
    /// Cancel. Asking changes nothing: the draft stays until its section
    /// saves or reverts it. A new request replaces one waiting on a save.
    mutating func request(_ request: Request) -> Decision {
        afterSave = nil
        guard let dirtySection else { return .proceed(request) }
        if case let .switchTo(section) = request, section == dirtySection {
            return .proceed(request)
        }
        return .askToSave(request)
    }

    /// The alert's Save was sent; `request` waits for the section to be clean.
    mutating func save(then request: Request) {
        afterSave = request
        saveStarted = false
    }

    /// The model started submitting.
    mutating func submissionStarted() {
        saveStarted = afterSave != nil
    }

    /// A moment after Save: a write the model refused never starts
    /// submitting, so nothing may keep waiting on it.
    mutating func saveMustHaveStarted() {
        if !saveStarted {
            afterSave = nil
        }
    }

    /// The save failed or the draft was reverted: stay where the sheet is.
    mutating func stopWaiting() {
        afterSave = nil
    }

    /// Records the section's report. Returns the request to go ahead with
    /// when a saved draft has become clean.
    mutating func report(dirty section: InfoSection?) -> Request? {
        dirtySection = section
        guard section == nil, let next = afterSave else { return nil }
        afterSave = nil
        return next
    }
}

enum Decision: Equatable {
    case proceed(InfoDraftState.Request)
    case askToSave(InfoDraftState.Request)
}
