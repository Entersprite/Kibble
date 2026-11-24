/// Owned by the call view so closing a sheet preserves unsent content.
/// Ending or replacing the call discards the drafts with its meeting scope.
struct CallActivityDrafts {
    /// A poll needs two answers, so it starts with two fields.
    static let emptyPollOptions = ["", ""]
    static let emptyRoomNames = [""]
    /// The most answers a poll, or rooms a meeting, can be given at once.
    static let lineLimit = 10

    var message = ""
    var waitingRoomMessage = ""
    var question = ""
    var pollTitle = ""
    var pollOptions = CallActivityDrafts.emptyPollOptions
    var roomNames = CallActivityDrafts.emptyRoomNames
    var anonymous = false
}
