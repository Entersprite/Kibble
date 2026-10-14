import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioCallSessionRestartTests {
    @MainActor
    private struct Account {
        let me: Member.ID
        let peer: Member
        let conversation: Conversation
        let backend = FakeLaunchBackend()
        let audio: RecordingAudioService

        init(_ key: String) {
            me = Member.ID("self-\(key)")
            peer = Member(id: Member.ID("peer-\(key)"), kind: .human, displayName: "Person")
            conversation = Conversation(
                id: Conversation.ID("opaque-dm-\(key)"), kind: .directMessage, members: [me, peer.id]
            )
            audio = RecordingAudioService(recipient: AudioCallRecipient(
                conversationID: conversation.id, memberID: peer.id, displayName: "Person"
            ))
        }

        var selection: SessionSelection {
            SessionSelection(backend: backend, me: me, audioCalls: audio)
        }

        func publishWorld() {
            backend.emit(.selfIdentified(Member(id: me, kind: .human, displayName: "Account")))
            backend.emit(.conversationsChanged([conversation]))
            backend.emit(.membersChanged(
                conversationID: conversation.id, members: [Member(id: me, kind: .human), peer]
            ))
        }
    }

    private func ready(_ environment: AppEnvironment, account: Account) async {
        account.publishWorld()
        #expect(await eventually {
            environment.sceneState.callableConversations == [account.conversation.id]
                && account.audio.listenCount == 1
        })
    }

    @Test func logoutAndLoginWithSameAccountCreatesFreshCallAndBackendOwners() async throws {
        let first = Account("same")
        let second = Account("same")
        let services = try FakeLaunchServices()
        services.sessionSelections = [first.selection, second.selection]
        let environment = AppEnvironment(services: services)
        await environment.start()
        await ready(environment, account: first)
        environment.actions.call?(first.conversation.id)
        #expect(await eventually { first.audio.operations == ["outgoing"] })
        let firstCall = try #require(environment.calls.call)

        await environment.signOut()
        #expect(first.audio.stopCount == 1)
        #expect(first.backend.disconnectCount == 1)
        #expect(environment.calls.call == nil)
        #expect(environment.sceneState.callableConversations.isEmpty)
        #expect(try services.store.conversations().isEmpty)
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected sign-in after all old owners settled")
            return
        }

        await environment.signedIn()
        await ready(environment, account: second)
        #expect(first.audio.listenCount == 1)
        #expect(second.audio.stopCount == 0)
        environment.actions.call?(second.conversation.id)
        #expect(await eventually { second.audio.operations == ["outgoing"] })
        #expect(environment.calls.call?.id != firstCall.id)
        #expect(environment.calls.call?.phase == .connecting)
        #expect(environment.sceneState.lastError == nil)
        await environment.signOut()
        #expect(second.audio.stopCount == 1)
        #expect(second.backend.disconnectCount == 1)
    }

    @Test func accountReplacementWaitsForOldCleanupAndRejectsOldAvailabilityAndCalls() async throws {
        let first = Account("old")
        let second = Account("new")
        let services = try FakeLaunchServices()
        services.sessionSelections = [first.selection, second.selection]
        let environment = AppEnvironment(services: services)
        await environment.start()
        await ready(environment, account: first)
        first.audio.emit(first.audio.snapshot(phase: .incoming, direction: .incoming))
        #expect(await eventually { environment.calls.call?.phase == .incoming })
        first.audio.suspendAccept = true
        environment.calls.accept()
        #expect(await eventually { first.audio.acceptContinuation != nil })
        first.audio.suspendStop = true
        let logout = Task { await environment.signOut() }
        #expect(await eventually { first.audio.stopContinuation != nil })
        #expect(environment.calls.call == nil)
        #expect(!environment.calls.isAvailable)
        #expect(first.backend.disconnectCount == 0)
        guard case .running = environment.phase else {
            Issue.record("login must remain unavailable while old audio cleanup is pending")
            return
        }
        first.audio.stopContinuation?.resume()
        first.audio.stopContinuation = nil
        await logout.value
        await environment.signedIn()
        await ready(environment, account: second)
        first.audio.acceptContinuation?.resume()
        first.audio.acceptContinuation = nil
        first.audio.continuation.yield(.recipientsChanged([first.audio.recipient]))
        first.audio.continuation.yield(.listenerChanged(isListening: false))
        first.audio.emit(first.audio.snapshot(phase: .incoming, direction: .incoming))
        let incoming = second.audio.snapshot(phase: .incoming, direction: .incoming)
        second.audio.emit(incoming)
        #expect(await eventually { environment.calls.call?.id == incoming.id })
        #expect(environment.calls.listenerFailure == nil)
        #expect(environment.sceneState.callableConversations == [second.conversation.id])
        #expect(second.audio.stopCount == 0)
        environment.calls.accept()
        #expect(await eventually { second.audio.operations == ["accept"] })
        #expect(environment.calls.call?.phase == .connecting)
        await environment.signOut()
    }

    @Test func autosaveStyleSignInTaskSurvivesRemovalOfTheLoginViewTask() async throws {
        let first = Account("same")
        let second = Account("same")
        second.backend.connectChecksCancellation = true
        second.backend.holdConnect()
        let services = try FakeLaunchServices()
        services.sessionSelections = [first.selection, second.selection]
        let environment = AppEnvironment(services: services)
        await environment.start()
        await ready(environment, account: first)
        await environment.signOut()
        // CookieCaptureModel.attemptAutoSave owns an unstructured task. Removing
        // CookieCaptureView cancels its view task, not this saved-sign-in callback.
        let loginViewTask = Task {
            let savedCallback = Task { await environment.signedIn() }
            await savedCallback.value
        }
        #expect(await eventually { second.backend.connectEntered })
        loginViewTask.cancel()
        second.backend.releaseConnect()
        await loginViewTask.value
        guard case .running = environment.phase else {
            Issue.record("saved sign-in should survive cancellation of the removed view's task")
            return
        }
        await ready(environment, account: second)
        environment.actions.call?(second.conversation.id)
        #expect(await eventually { second.audio.operations == ["outgoing"] })
        #expect(environment.sceneState.lastError == nil)
        await environment.signOut()
    }
}
