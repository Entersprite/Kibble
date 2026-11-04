import GChatBridgeCore

extension NativeMeetCallSession {
    func joinDevice() async throws {
        await reportAdmission(stage: "registered")
        for attempt in 0 ..< 5 {
            try await check()
            lines.append("UpdateMeetingDevice: JOINED requested")
            do {
                try await device.join()
                await reportAdmission(stage: "join confirmed")
                return
            } catch {
                await reportAdmission(stage: "join reply or failure")
                guard error as? MeetDeviceSessionError == .notJoined, attempt < 4,
                      await device.admissionState?.joinState == 9 else { throw error }
                try await acknowledgeAdmission()
                if await device.admissionState?.joinState == 1 {
                    await reportAdmission(stage: "join confirmed")
                    return
                }
            }
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
