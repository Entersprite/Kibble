import Foundation
import Testing
@testable import AppCore

/// `StagedFileCustody`: one start and one stop per staged file, held while
/// any composer has it staged or a read of it is in flight, and a pasted
/// picture's folder deleted at the same moment.
@MainActor
struct StagedFileCustodyTests {
    @MainActor
    final class Effects {
        var scoped = true
        var started: [String] = []
        var stopped: [String] = []
        var removed: [String] = []

        func custody() -> StagedFileCustody {
            StagedFileCustody(
                startAccess: { [self] url in
                    guard scoped else { return false }
                    started.append(url.lastPathComponent)
                    return true
                },
                stopAccess: { [self] in stopped.append($0.lastPathComponent) },
                removeItem: { [self] in removed.append($0.lastPathComponent) }
            )
        }
    }

    private let notes = URL(fileURLWithPath: "/files/notes.txt")
    private let photo = URL(fileURLWithPath: "/files/photo.png")

    @Test func aFileStagedTwiceIsStartedOnceAndStoppedOnce() {
        let effects = Effects()
        let custody = effects.custody()
        custody.access(notes, id: "notes")
        custody.access(notes, id: "notes")
        custody.release(keeping: ["notes"])
        #expect(effects.started == ["notes.txt"])
        #expect(effects.stopped.isEmpty)

        custody.release(keeping: [])
        custody.release(keeping: [])
        #expect(effects.stopped == ["notes.txt"])
    }

    /// A dropped file's URL is not scoped, so there is nothing to stop.
    @Test func aURLThatIsNotScopedIsNotHeld() {
        let effects = Effects()
        effects.scoped = false
        let custody = effects.custody()
        custody.access(notes, id: "notes")
        custody.release(keeping: [])
        #expect(custody.heldIDs.isEmpty)
        #expect(effects.stopped.isEmpty)
    }

    /// Removing one chip keeps the other file readable.
    @Test func onlyWhatLeftEveryComposerIsReleased() {
        let effects = Effects()
        let custody = effects.custody()
        custody.access(notes, id: "notes")
        custody.access(photo, id: "photo")
        custody.release(keeping: ["photo"])
        #expect(effects.stopped == ["notes.txt"])
        #expect(custody.heldIDs == ["photo"])
    }

    /// A sent picture's bytes are still being kept when the message posts
    /// and the file leaves the composer.
    @Test func aReadInFlightHoldsTheFilePastItsUnstaging() {
        let effects = Effects()
        let custody = effects.custody()
        custody.access(photo, id: "photo")
        custody.beginRead("photo")
        custody.release(keeping: [])
        #expect(effects.stopped.isEmpty)

        custody.endRead("photo")
        #expect(effects.stopped == ["photo.png"])
    }

    /// Staged again while the read ran: the read's end does not take it.
    @Test func aReadEndingAfterARestageKeepsTheFile() {
        let effects = Effects()
        let custody = effects.custody()
        custody.access(photo, id: "photo")
        custody.beginRead("photo")
        custody.release(keeping: [])
        custody.release(keeping: ["photo"])
        custody.endRead("photo")
        #expect(effects.stopped.isEmpty)
    }

    @Test func aPastedPicturesFolderIsDeletedWhenItIsReleased() {
        let effects = Effects()
        let custody = effects.custody()
        custody.own(URL(fileURLWithPath: "/tmp/Pasted Images/A"), id: "pasted")
        custody.release(keeping: ["pasted"])
        #expect(effects.removed.isEmpty)
        custody.release(keeping: [])
        #expect(effects.removed == ["A"])
        #expect(effects.stopped.isEmpty)
    }

    @Test func theSessionEndingReleasesEverythingReadsIncluded() {
        let effects = Effects()
        let custody = effects.custody()
        custody.access(notes, id: "notes")
        custody.own(URL(fileURLWithPath: "/tmp/Pasted Images/A"), id: "pasted")
        custody.beginRead("notes")
        custody.releaseAll()
        #expect(effects.stopped == ["notes.txt"])
        #expect(effects.removed == ["A"])
        #expect(custody.heldIDs.isEmpty)
        custody.endRead("notes")
        #expect(effects.stopped == ["notes.txt"])
    }
}
