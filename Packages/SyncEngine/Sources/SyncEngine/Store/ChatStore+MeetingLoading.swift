import ChatRules
import GRDB

public extension ChatStore {
    func observeMeetingMetadataLoading() -> AsyncValueObservation<Bool> {
        ValueObservation.tracking { db in
            try Bool.fetchOne(db, sql: "SELECT meetingMetadataLoading FROM syncState WHERE id = 1") ?? false
        }.values(in: database)
    }
}
