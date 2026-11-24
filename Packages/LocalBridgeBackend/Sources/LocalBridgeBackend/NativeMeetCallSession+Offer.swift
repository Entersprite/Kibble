import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func prepareInitialMicrophone() async {
        if desiredMuted {
            await media.prepareMutedMeetingJoin()
        } else if staysWhenAlone {
            await media.setMuted(true)
        }
    }

    func finishConnect(_ offer: MeetAudioOffer, streamControl: Bool) async throws {
        lines.append("UpdateMeetingDevice: JOINED accepted")
        if streamControl {
            await registerAudioStream(offer)
            try await check()
            guard audioStream != nil else { throw CallMediaError.outgoingAudioUnconfirmed }
        }
        if staysWhenAlone {
            try await check()
            await media.setMuted(desiredMuted)
            try await check()
        }
        ready = true
        if case .awaitingAdmission = state {
            await publish(.ready)
        }
    }

    static func suite(_ profile: CallSRTPProfile) -> MeetAudioOffer.SRTPSuite {
        switch profile {
        case .aes128SHA180: .aes128SHA180
        case .aeadAES128GCM: .aeadAES128GCM
        case .aeadAES256GCM: .aeadAES256GCM
        }
    }

    func reportOffer(_ local: CallAudioOffer) {
        lines.append("Native audio: local offer prepared (SDP withheld)")
        lines.append("Native audio codecs: Opus with optional RED; legacy codecs excluded")
        lines.append("Native control: server-created collections channel; protobuf; uncompressed")
        lines.append("Native audio config: DTLS selector 1; media selector 2; audio output enabled; SRTP "
            + local.srtpProfile.rawValue)
    }

    func serverAnswer(_ offer: MeetAudioOffer, configuration: Data) throws -> String {
        do {
            return try offer.answer(serverConfiguration: configuration)
        } catch {
            if let failure = error as? MeetAudioOffer.AnswerFailure, failure == .ice {
                lines += MeetAudioOffer.iceDiagnostics(serverConfiguration: configuration)
            }
            throw error
        }
    }
}
