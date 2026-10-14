import ChatKit
import Foundation

/// Paging uses visible stable IDs rather than the lazy stack's estimated offset.
/// Visibility changes caused by initial placement or search do not request pages.
@MainActor
final class TranscriptPaging {
    enum Page: Equatable {
        case older
        case newer
    }

    // Visibility delivery can trail the end of a gesture. Keep its intent until
    // a programmatic position, window change or resize establishes a new baseline.
    var hasUserIntent = false
    private var visibleIDs: Set<Message.ID> = []

    func update(visibleIDs ids: [Message.ID], messages: [Message]) -> Page? {
        let previous = visibleIDs
        visibleIDs = Set(ids)
        guard hasUserIntent else { return nil }
        let indices = messages.indices.filter { visibleIDs.contains(messages[$0].id) }
        let oldIndices = messages.indices.filter { previous.contains(messages[$0].id) }
        guard let first = indices.first, let last = indices.last,
              let oldFirst = oldIndices.first, let oldLast = oldIndices.last else { return nil }
        if first < oldFirst, first < 5 {
            return .older
        }
        if last > oldLast, last >= messages.count - 5 {
            return .newer
        }
        return nil
    }
}
