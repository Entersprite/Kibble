import ChatKit
import SwiftUI

public struct ScheduledMessagesScene: Sendable, Equatable {
    public var showingList = false
    public var canScheduleAttachments = false
    public var messages: [ScheduledMessage] = []
    public var pending: Set<ScheduledMessageAddress> = []
    public var submissions: Set<ComposerDraftAddress> = []
    public var receipts: [ComposerDraftAddress: ComposerScheduleReceipt] = [:]
    public var isLoading = false
    public var readFailed = false
    public var hasMore = false

    public init() {}
}

@MainActor
public struct ScheduledMessagesActions {
    public typealias Completion = @MainActor (Bool) -> Void
    public var show: () -> Void
    public var refresh: () -> Void
    public var loadMore: () -> Void
    let submit: (ComposerDraftAddress, ComposedMessage, ComposedMessage, Date) -> Bool
    let latestReceipt: (ComposerDraftAddress) -> ComposerScheduleReceipt?
    let edit: (ScheduledMessageAddress, ComposedMessage, @escaping Completion) -> Bool
    let reschedule: (ScheduledMessageAddress, Date, @escaping Completion) -> Bool
    let cancel: (ScheduledMessageAddress) -> Void
    let sendNow: ((ScheduledMessageAddress) -> Void)?

    public init(
        show: @escaping () -> Void,
        refresh: @escaping () -> Void,
        loadMore: @escaping () -> Void,
        submit: @escaping (ComposerDraftAddress, ComposedMessage, ComposedMessage, Date) -> Bool,
        latestReceipt: @escaping (ComposerDraftAddress) -> ComposerScheduleReceipt?,
        edit: @escaping (ScheduledMessageAddress, ComposedMessage, @escaping Completion) -> Bool,
        reschedule: @escaping (ScheduledMessageAddress, Date, @escaping Completion) -> Bool,
        cancel: @escaping (ScheduledMessageAddress) -> Void,
        sendNow: ((ScheduledMessageAddress) -> Void)? = nil
    ) {
        self.show = show
        self.refresh = refresh
        self.loadMore = loadMore
        self.submit = submit
        self.latestReceipt = latestReceipt
        self.edit = edit
        self.reschedule = reschedule
        self.cancel = cancel
        self.sendNow = sendNow
    }

    func composer(at address: ComposerDraftAddress, scene: ScheduledMessagesScene) -> ComposerScheduling {
        ComposerScheduling(
            isSubmitting: scene.submissions.contains(address),
            receipt: scene.receipts[address],
            latestReceipt: { latestReceipt(address) },
            schedule: { submit(address, $0, $1, $2) },
            canScheduleAttachments: scene.canScheduleAttachments
        )
    }
}
