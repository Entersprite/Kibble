/// Owned by the call view so closing a sheet preserves unsent content.
/// Ending or replacing the call discards the drafts with its meeting scope.
struct CallActivityDrafts {
    var message = ""
    var waitingRoomMessage = ""
    var question = ""
    var pollTitle = ""
    var pollOptions = ""
    var roomNames = ""
    var anonymous = false
}
