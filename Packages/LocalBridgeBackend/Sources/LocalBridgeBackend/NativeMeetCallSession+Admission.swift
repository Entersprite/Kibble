import ChatKit
import Foundation
import GChatBridgeCore

enum NativeMeetAdmissionError: Error, Equatable {
    case denied, full, timedOut, unavailable

    var message: String {
        switch self {
        case .denied: "The host declined your request to join."
        case .full: "The meeting is full."
        case .timedOut: "Your request to join expired."
        case .unavailable: "Your request to join could not be checked."
        }
    }
}

extension NativeMeetCallSession {
    func joinDevice() async throws {
        await reportAdmission(stage: "registered")
        await updateDeviceCaptionLanguages(device.localCaptionLanguages)
        for attempt in 0 ..< 5 {
            try await check()
            lines.append("UpdateMeetingDevice: JOINED requested")
            do { try await device.join() } catch {
                await reportAdmission(stage: "join reply or failure")
                guard error as? MeetDeviceSessionError == .notJoined else { throw error }
            }
            try await waitForHostIfNeeded()
            if await device.admissionState?.joinState == 9, attempt < 4 {
                try await acknowledgeAdmission()
                try await waitForHostIfNeeded()
            }
            switch await device.admissionState?.joinState {
            case 1:
                guard await device.admissionState?.isDeleted == false else {
                    throw MeetDeviceSessionError.notJoined
                }
                await confirmJoinedDevice()
                return
            case 4 where staysWhenAlone: throw NativeMeetAdmissionError.denied
            case 11 where staysWhenAlone: throw NativeMeetAdmissionError.full
            case 9 where attempt < 4: continue
            default: throw MeetDeviceSessionError.notJoined
            }
        }
    }

    private func confirmJoinedDevice() async {
        await reportAdmission(stage: "join confirmed")
        await updateDeviceCaptionLanguages(device.localCaptionLanguages)
    }

    func setAdmissionHandler(
        _ receive: (@Sendable (MeetNativeCallState) async -> Void)?,
        waitingRoomMessages: (@Sendable ([CallMeetingMessage]) async -> Void)? = nil
    ) {
        receiveState = receive
        receiveWaitingRoomMessages = waitingRoomMessages
    }

    private func waitForHostIfNeeded() async throws {
        guard staysWhenAlone else { return }
        let started = now()
        var missedReads = 0
        var messageVersion: UInt64?
        defer { clearWaitingRoomMessages() }
        while let deviceState = await device.admissionState, [3, 13].contains(deviceState.joinState),
              !deviceState.isDeleted {
            try await check()
            let knocking = deviceState.joinState == 3
            if knocking, messageVersion != nil {
                messageVersion = nil
                clearWaitingRoomMessages()
            }
            let deadline = started + .seconds(600)
            guard !knocking || now() < deadline else { throw NativeMeetAdmissionError.timedOut }
            let waiting = MeetNativeCallState.awaitingAdmission(knocking ? .requestPending : .waitingRoom)
            await publish(waiting)
            try await admissionSleep(knocking ? min(.seconds(5), deadline - now()) : .seconds(5))
            try await check()
            guard !knocking || now() < deadline else { throw NativeMeetAdmissionError.timedOut }
            if await !media.isConnected {
                try await media.waitUntilConnected(timeout: .seconds(15))
                try await check()
            }
            var observed = false
            if !knocking, receiveWaitingRoomMessages != nil,
               let read = try? await device.refreshWaitingAdmission(includingMessages: true) {
                try await check()
                observed = read.observed
                if let version = read.messageVersion, let messages = read.messages,
                   messageVersion.map({ version > $0 }) ?? true {
                    messageVersion = version
                    mergeWaitingRoomMessages(messages, replacing: true)
                    await receiveWaitingRoomMessages?(activities.waitingRoomMessages ?? [])
                }
            } else {
                try await check()
                observed = try await readWaitingDevice()
            }
            missedReads = observed ? 0 : missedReads + 1
            guard missedReads < 4 else { throw NativeMeetAdmissionError.unavailable }
        }
    }

    private func readWaitingDevice() async throws -> Bool {
        do {
            return try await device.refreshWaitingAdmission()
        } catch {
            try await check()
            if case let MeetCallClientError.httpStatus(status, _) = error,
               [401, 403, 404].contains(status) {
                throw error
            }
            return false
        }
    }

    private func acknowledgeAdmission() async throws {
        try await device.refreshAdmission()
        try await check()
        if await device.admissionState?.joinState == 1 {
            return
        }
        let pending = await device.pendingAdmissionAcknowledgements
        let types: [UInt64: CallAdmissionNotice] = [
            1: .recording, 2: .organizationLiveStream, 3: .transcription, 4: .publicLiveStream,
            5: .notes, 8: .watermark, 9: .mediaAccess, 10: .automatedParticipant
        ]
        let notices = pending.compactMap { types[$0.type] }
        guard !pending.isEmpty, notices.count == pending.count else {
            lines.append("Native device admission: required notice is unavailable or unsupported")
            throw MeetDeviceSessionError.notJoined
        }
        lines.append("Native device admission: awaiting notice confirmation; count=" + String(notices.count))
        guard await media.confirmAdmission(notices) else { throw CancellationError() }
        try await check()
        guard await media.isConnected else { throw CallMediaError.connectionFailed }
        try await device.acknowledgeAdmission(pending)
        try await check()
        lines.append("Native device admission: notice acknowledged; continuing Join")
    }

    private func reportAdmission(stage: String) async {
        guard let status = await device.admissionState else { return }
        let state = status.joinState <= 15 ? String(status.joinState) : "unknown"
        let transfer = status.transfer <= 3 ? String(status.transfer) : "unknown"
        lines.append("Native device admission: " + stage + "; join state=" + state
            + "; transfer=" + transfer + "; deleted=" + String(status.isDeleted))
    }
}
