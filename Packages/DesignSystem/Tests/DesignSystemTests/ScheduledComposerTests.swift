import AppKit
import ChatKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

struct ScheduledComposerTests {
    @MainActor
    @Test func fileOnlySchedulingRequiresTheCapabilityAndReadyFiles() {
        let file = ComposerAttachment(
            id: "upload", name: "File.pdf", byteSize: 100, isImage: false,
            file: URL(fileURLWithPath: "/Fixture/File.pdf")
        )
        func offers(_ attachment: ComposerAttachment, canSchedule: Bool) -> Bool {
            Composer(placeholder: "Message", attachments: [attachment], scheduling: ComposerScheduling(
                isSubmitting: false, receipt: nil, latestReceipt: { nil }, schedule: { _, _, _ in true },
                canScheduleAttachments: canSchedule
            ), send: { _ in }).offersScheduleSend
        }
        #expect(offers(file, canSchedule: true))
        #expect(!offers(file, canSchedule: false))
        var uploading = file
        uploading.state = .uploading(fraction: 0.5)
        #expect(!offers(uploading, canSchedule: true))
    }

    @MainActor
    @Test func scheduleSendIsAsSmallAsTheDictationGlyphBesideIt() {
        let schedule = NSHostingView(
            rootView: ComposerFieldButton(title: "Schedule Send…", systemImage: "clock") {}
        ).fittingSize
        let dictation = NSHostingView(rootView: ComposerDictationButton {}).fittingSize
        #expect(schedule.height == dictation.height)
        #expect(schedule.height == 16)
        #expect(schedule.width < ComposerLayout.lineHeight)
    }

    @MainActor
    @Test func theScheduledQueueUsesItsOwnSidebarSelectionAndTitle() {
        var opened = false
        var actions = ChatSceneActions()
        actions.scheduled = ScheduledMessagesActions(
            show: { opened = true }, refresh: {}, loadMore: {}, submit: { _, _, _, _ in false },
            latestReceipt: { _ in nil }, edit: { _, _, _ in false },
            reschedule: { _, _, _ in false }, cancel: { _ in }
        )
        var state = ChatSceneState(conversations: [])
        state.scheduled.showingList = true
        SidebarPinned.choose(SidebarPinned.pinnedSelection(state), actions: actions)
        #expect(opened)
        #expect(SidebarPinned.rows(actions).contains(.scheduled))
        #expect(ChatWindow(state: state, actions: actions).title == "Scheduled")
    }

    @Test func acknowledgementClearsOnlyTheExactDraft() {
        var draft = ComposerDraft()
        draft.edit("  Scheduled message  ")
        let offered = draft.scheduledComposition
        #expect(draft.composed().text == "Scheduled message")
        draft.edit("A later draft")
        draft.clearScheduledComposition(offered)
        #expect(draft.text == "A later draft")

        draft.edit(offered.text)
        draft.moveCaret(to: 0)
        draft.clearScheduledComposition(offered)
        #expect(draft.text.isEmpty)
    }

    @Test func confirmationDuringAnEditClearsOnlyTheSavedComposition() {
        var draft = ComposerDraft()
        draft.edit("Scheduled message")
        let offered = draft.scheduledComposition
        draft.beginEditing(.init("old"), with: ComposedMessage(text: "Edit in progress"))
        draft.clearScheduledComposition(offered)
        #expect(draft.text == "Edit in progress")
        #expect(draft.endEditing()?.message.text == "Edit in progress")
        #expect(draft.text.isEmpty)
    }
}
