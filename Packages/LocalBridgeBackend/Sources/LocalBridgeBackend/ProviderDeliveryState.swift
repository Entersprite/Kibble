import ChatKit
import Foundation
import GChatBridgeCore

struct PendingProviderBatch: Sendable {
    var events: [ChatEvent] = []
    var directory: ConversationSnapshot?
    var invalidatesHistory = false
    var directoryReadBegan = false
    var patch = ProviderCursorPatch()
    var live = false
    var completion: CheckedContinuation<Bool, Never>?
}

struct ProviderDeliveryState {
    var epoch = UUID()
    var running = false
    var cursor = GoogleProviderCursor()
    var checkpoint: Data?
    var queue: [PendingProviderBatch] = []
    var pump: Task<Void, Never>?
    var batchID: String?
    var acknowledgement: CheckedContinuation<Bool, Never>?
    var recovery: Task<Void, Never>?
    var blocksAll = true
    var blocksUser = true
    var reactionGroups: [ChatKit.Message.ID: String] = [:]
    var deferredRevisions: [String: Int64] = [:]
    var blockedGroups: Set<String> = []
    var recovering = false
    var recoveryIncomplete = false
    var recoveryFailures = 0
    var rebasedRecovery = false
    var notificationFloor = Date.distantFuture
    var retry: Task<Void, Never>?
    var recoveryRequested = false
    var buffered: [ChannelEvent] = []
    var bufferedBytes = 0
    var overflowed = false
    var directory: ConversationSnapshot?
}
