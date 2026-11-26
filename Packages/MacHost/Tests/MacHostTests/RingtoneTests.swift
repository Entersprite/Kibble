import AVFoundation
import DesignSystem
import Foundation
import Testing
@testable import MacHost

@MainActor
struct RingtoneTests {
    @Test func bundledRingtonesDecodeTheirCompleteBars() throws {
        let bars: [(URL?, AVAudioFrameCount)] = [(Ringtone.bundled, 100_174), (Ringtone.alternate, 200_347)]
        for (url, frames) in bars {
            let buffer = try Ringtone.decode(#require(url))
            #expect(buffer.format.sampleRate == 48000)
            #expect(buffer.format.channelCount == 2)
            #expect(buffer.frameLength == frames)
        }
    }

    @Test func everyBundledCueIsDecodableAndShortEnoughForNotificationCenter() throws {
        for sound in AppSound.allCases {
            let buffer = try Ringtone.decode(#require(sound.url))
            #expect(buffer.frameLength > 0)
            #expect(Double(buffer.frameLength) / buffer.format.sampleRate < 30)
        }
    }

    @Test func alternateRingtoneIsPreviewedAndKeptAcrossReloads() throws {
        let place = try RingtonePlace()
        defer { place.remove() }
        let model = place.model()
        var preview: URL?
        model.previewRingtone = { preview = $0 }
        model.setRingtone(.kibbleAlt)
        #expect(model.state.ringtone == .kibbleAlt)
        #expect(preview == Ringtone.alternate)
        #expect(place.model().ringtoneURL == Ringtone.alternate)
        #expect(place.model().state.ringtone == .kibbleAlt)
        model.setRingtone(.kibble)
        #expect(place.model().state.ringtone == .kibble)
    }

    @Test func decodingRefusesLongEmptyAndNonAudioFiles() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let long = directory.appendingPathComponent("long.caf")
        try Self.writeTone(seconds: Ringtone.maximumDuration + 1, to: long)
        #expect(throws: Ringtone.Failure.tooLong) { try Ringtone.decode(long) }

        let empty = directory.appendingPathComponent("empty.caf")
        try Self.writeTone(seconds: 0, to: empty)
        #expect(throws: Ringtone.Failure.empty) { try Ringtone.decode(empty) }

        let text = directory.appendingPathComponent("notes.mp3")
        try Data("not audio".utf8).write(to: text)
        #expect(throws: Ringtone.Failure.unreadable) { try Ringtone.decode(text) }

        let short = directory.appendingPathComponent("short.caf")
        try Self.writeTone(seconds: 1, to: short)
        let decoded = try Ringtone.decode(short)
        #expect(decoded.frameLength == 44100)
    }

    @Test func theRingerLoopsTheRingtoneUntilStopped() {
        let player = FakeRingtonePlayer()
        let chosen = URL(fileURLWithPath: "/tmp/chosen.aif")
        let ringer = CallRinger(player: player) { chosen }
        ringer.start()
        ringer.start()
        #expect(player.plays == [FakeRingtonePlayer.Play(url: chosen, loops: true)])
        #expect(ringer.isRinging)
        ringer.stop()
        ringer.stop()
        #expect(player.stops == 1)
        #expect(!ringer.isRinging)
    }

    @Test func aChosenFileThatCannotPlayRingsWithKibblesOwn() throws {
        let player = FakeRingtonePlayer()
        let broken = URL(fileURLWithPath: "/tmp/broken.aif")
        player.failing = [broken]
        let ringer = CallRinger(player: player) { broken }
        ringer.start()
        let bundled = try #require(Ringtone.bundled)
        #expect(player.plays.map(\.url) == [broken, bundled])
        #expect(player.plays.last?.loops == true)
    }

    @Test func aPreviewNeverPlaysOverARingingCall() {
        let player = FakeRingtonePlayer()
        let ringer = CallRinger(player: player) { URL(fileURLWithPath: "/tmp/ring.aif") }
        let preview = URL(fileURLWithPath: "/tmp/preview.aif")
        ringer.start()
        ringer.preview(preview)
        #expect(player.plays.count == 1)
        ringer.stop()
        ringer.preview(preview)
        #expect(player.plays.last == FakeRingtonePlayer.Play(url: preview, loops: false))
    }

    @Test func aChosenRingtoneIsCopiedKeptAndPreviewed() throws {
        let place = try RingtonePlace()
        defer { place.remove() }
        let model = place.model()
        var previews: [URL] = []
        model.previewRingtone = { previews.append($0) }
        #expect(model.state.ringtone == .kibble)
        #expect(model.state.customRingtoneName == nil)
        #expect(model.ringtoneURL == Ringtone.bundled)

        let original = place.directory.appendingPathComponent("Doorbell.caf")
        try Self.writeTone(seconds: 1, to: original)
        model.importRingtone(from: original)
        #expect(model.state.ringtone == .custom)
        #expect(model.state.customRingtoneName == "Doorbell")
        let copy = try #require(model.ringtoneURL)
        #expect(copy.deletingLastPathComponent().standardizedFileURL == place.ringtones.standardizedFileURL)
        #expect(copy.pathExtension == "caf")
        #expect(previews == [copy])

        // The copy rings even after the original is gone.
        try FileManager.default.removeItem(at: original)
        let reloaded = place.model()
        #expect(reloaded.state.ringtone == .custom)
        #expect(reloaded.state.customRingtoneName == "Doorbell")
        #expect(reloaded.ringtoneURL == copy)

        // A file that cannot be used leaves the current one, with a reason.
        let long = place.directory.appendingPathComponent("Song.caf")
        try Self.writeTone(seconds: Ringtone.maximumDuration + 1, to: long)
        model.importRingtone(from: long)
        #expect(model.state.customRingtoneName == "Doorbell")
        #expect(model.state.ringtoneNotice == CallSettingsModel.notice(for: .tooLong, file: "Song.caf"))
        #expect(model.ringtoneURL == copy)
    }

    @Test func aNewChoiceReplacesTheCopyAndAGoneCopyIsForgotten() throws {
        let place = try RingtonePlace()
        defer { place.remove() }
        let model = place.model()
        var previews: [URL] = []
        model.previewRingtone = { previews.append($0) }
        let first = place.directory.appendingPathComponent("Doorbell.caf")
        try Self.writeTone(seconds: 1, to: first)
        model.importRingtone(from: first)
        let firstCopy = try #require(model.ringtoneURL)

        let second = place.directory.appendingPathComponent("Chime.caf")
        try Self.writeTone(seconds: 2, to: second)
        model.importRingtone(from: second)
        #expect(model.state.customRingtoneName == "Chime")
        #expect(!FileManager.default.fileExists(atPath: firstCopy.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.ringtones.path).count == 1)

        // Back to Kibble's own keeps the chosen file in the menu.
        model.setRingtone(.kibble)
        #expect(model.state.ringtone == .kibble)
        #expect(model.state.customRingtoneName == "Chime")
        #expect(previews.last == Ringtone.bundled)
        model.setRingtone(.custom)
        #expect(model.state.ringtone == .custom)

        let secondCopy = try #require(model.ringtoneURL)
        try FileManager.default.removeItem(at: secondCopy)
        let cleared = place.model()
        #expect(cleared.state.ringtone == .kibble)
        #expect(cleared.state.customRingtoneName == nil)
        #expect(cleared.ringtoneURL == Ringtone.bundled)
        cleared.setRingtone(.custom)
        #expect(cleared.state.ringtone == .kibble)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RingtoneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A quiet 440 Hz tone, mono, 44.1 kHz.
    private static func writeTone(seconds: TimeInterval, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { file.close() }
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard frames > 0 else { return }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0 ..< Int(frames) {
            samples[frame] = 0.1 * sin(2 * .pi * 440 * Float(frame) / 44100)
        }
        try file.write(from: buffer)
    }
}

/// A temporary folder and defaults suite for one test's settings.
@MainActor
private struct RingtonePlace {
    let directory: URL
    let ringtones: URL
    let suite = "RingtoneTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RingtoneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ringtones = directory.appendingPathComponent("Ringtones")
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func model() -> CallSettingsModel {
        CallSettingsModel(defaults: defaults, focusStatus: QuietFocus(), ringtoneDirectory: ringtones)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FakeRingtonePlayer: RingtonePlaying {
    struct Play: Equatable {
        let url: URL
        let loops: Bool
    }

    struct Failure: Error {}

    var plays: [Play] = []
    var stops = 0
    var failing: Set<URL> = []

    func play(_ url: URL, loops: Bool) throws {
        plays.append(Play(url: url, loops: loops))
        if failing.contains(url) {
            throw Failure()
        }
    }

    func stop() {
        stops += 1
    }
}

@MainActor
private final class QuietFocus: FocusStatusReading {
    var access: CallFocusAccess {
        .notDetermined
    }

    var isFocused: Bool? {
        nil
    }

    func requestAccess() async -> CallFocusAccess {
        .notDetermined
    }
}
