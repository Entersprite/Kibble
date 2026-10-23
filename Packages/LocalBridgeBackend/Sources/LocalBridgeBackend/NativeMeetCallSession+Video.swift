import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func prepareOptionalMedia(_ offer: MeetVideoOffer?, configuration: Data) async throws {
        try await prepareOptionalVideo(offer, configuration: configuration)
        try await check()
        await preparePresentation()
    }

    func prepareOptionalVideo(_ offer: MeetVideoOffer?, configuration: Data) async throws {
        guard let offer else { return }
        do {
            try await prepareVideo(offer, configuration: configuration)
        } catch {
            try await check()
            await media.configureCamera(announce: nil)
            await media.reportVideoUnavailable()
            lines.append("Native video: camera registration unavailable; voice remains available")
            await startRemoteAudioPoll()
        }
    }

    func prepareVideo(_ offer: MeetVideoOffer, configuration: Data) async throws {
        try await check()
        guard let conference = await device.conferenceID else { throw CallMediaError.negotiationFailed }
        let context = try MeetVideoStreamWire.Context(
            mediaSession: mediaSessionName,
            conferenceID: conference
        )
        let id = nextStreamRequest()
        let request = try MeetVideoStreamWire.register(
            context: context,
            source: offer.source,
            requestID: id,
            header: client.streamControlHeader()
        )
        let reply = try await videoExchange(request, id: id)
        try MeetVideoStreamWire.confirm(
            from: reply,
            context: context,
            source: offer.source,
            muted: true,
            requestID: id
        )
        try await check()
        videoSource = offer.source
        videoContext = context
        videoConfiguration = configuration
        receivingVideoCapacity = offer.receivingCapacity
        await media.configureCamera { [weak self] enabled in
            guard let self else { throw CallMediaError.closed }
            try await announceCamera(enabled)
        }
        try await check()
        lines.append("Native video: camera stream registered; camera off")
        videoPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await refreshVideo()
            }
        }
    }

    private func announceCamera(_ enabled: Bool) async throws {
        try await check()
        guard ready, let context = videoContext else { throw CallMediaError.closed }
        let id = nextStreamRequest()
        let request = try MeetVideoStreamWire.mute(
            context: context,
            muted: !enabled,
            requestID: id,
            header: client.streamControlHeader()
        )
        let reply = try await videoExchange(request, id: id)
        try MeetVideoStreamWire.confirm(from: reply, context: context, muted: !enabled, requestID: id)
        try await check()
        cameraMuted = !enabled
    }

    func refreshVideo() async {
        guard ready, !closed, !isSuspended, disconnectedAt == nil,
              let context = videoContext, let configuration = videoConfiguration else { return }
        var searched = false
        do {
            try await check()
            let id = nextStreamRequest()
            let request = try MeetVideoStreamWire.search(
                context: context,
                requestID: id,
                header: client.streamControlHeader()
            )
            let reply = try await videoExchange(request, id: id)
            searched = true
            await recordRemoteAudio(reply, context: context, requestID: id)
            let streams = try MeetVideoStreamWire.downstreams(from: reply, context: context, requestID: id)
            let next = try await selectedRemoteVideos(streams)
            try await bindRemoteVideos(next, context: context, configuration: configuration)
            receivingVideos = next
            receivingVideo = next.compactMap(\.self).first
            for stream in next.compactMap(\.self) {
                try await requestVideoView(stream, context: context)
            }
            try await check()
            await media.showRemoteVideos(next.enumerated().compactMap { index, stream in
                stream.map { value in
                    CallRemoteVideoSlot(
                        index: index, isPresentation: !value.isCamera, isVisible: !value.muted,
                        participantID: value.deviceName.flatMap { participantHandles[$0] },
                        displayName: value.deviceName.flatMap { participantDevices[$0]?.displayName }
                    )
                }
            })
            recordVideoStatus("remote video slots: \(next.compactMap(\.self).count)")
        } catch {
            await media.cancelVideoOffer()
            guard !closed, !Task.isCancelled else { return }
            if !searched {
                await publishRemoteAudio(nil)
            }
            await media.showRemoteVideos([])
            recordVideoStatus("receiving unavailable; " + MeetDMCallTrial.errorDescription(error))
        }
    }

    private func bindRemoteVideos(
        _ next: [MeetVideoStreamWire.Downstream?], context: MeetVideoStreamWire.Context, configuration: Data
    ) async throws {
        if next.map({ $0?.source }) != receivingVideos.map({ $0?.source }) {
            await media.showRemoteVideos([])
            for previous in viewedVideos where !next.contains(where: { $0?.source == previous.source }) {
                // A stream which disappeared may reject modification. It
                // cannot block the remaining independent receivers.
                try? await stopVideoView(previous, context: context)
                try await check()
            }
            let local = try await media.renewVideoOffer()
            try await check()
            let offer = try MeetVideoOffer(sdp: local.sdp)
            guard offer.source == videoSource, offer.receivingCapacity == receivingVideoCapacity else {
                throw CallMediaError.negotiationFailed
            }
            let answer = try offer.answer(
                serverConfiguration: configuration, receivingSources: next.map { $0?.source }
            )
            try await media.applyVideoAnswer(answer)
            try await check()
            receivingVideos = next
            viewedVideos = []
        }
    }

    private func selectedRemoteVideos(_ streams: [MeetVideoStreamWire.Downstream]) async throws
        -> [MeetVideoStreamWire.Downstream?] {
        if let source = await presentation?.source {
            rememberPresentationSource(source)
        }
        try await check()
        let remote = streams
            .filter {
                $0.source != videoSource && !ownPresentationSources.contains($0.source) && !isOwnVideo($0)
            }
        if receivingVideoCapacity == 1 {
            return MeetVideoStreamWire.preferred(remote).map { [$0] } ?? []
        }
        let ranked = remote.sorted {
            let left = $0.muted ? 2 : ($0.isCamera ? 1 : 0)
            let right = $1.muted ? 2 : ($1.isCamera ? 1 : 0)
            return left == right ? $0.source.primary < $1.source.primary : left < right
        }
        let selected = Array(ranked.prefix(receivingVideoCapacity))
        var slots = [MeetVideoStreamWire.Downstream?](repeating: nil, count: receivingVideoCapacity)
        for (index, previous) in receivingVideos.enumerated() where slots.indices.contains(index) {
            if let previous, let current = selected.first(where: { $0.source == previous.source }) {
                slots[index] = current
            }
        }
        for stream in selected where !slots.contains(where: { $0?.source == stream.source }) {
            if let index = slots.firstIndex(where: { $0 == nil }) {
                slots[index] = stream
            }
        }
        return slots
    }

    private func isOwnVideo(_ stream: MeetVideoStreamWire.Downstream) -> Bool {
        guard let local = participantLocalDevice, let name = stream.deviceName else { return false }
        return name == local || participantDevices[name]?.primaryDevice == local
    }

    private func recordVideoStatus(_ status: String) {
        guard videoStatus != status else { return }
        videoStatus = status
        lines.append("Native video: " + status)
    }

    private func requestVideoView(
        _ next: MeetVideoStreamWire.Downstream?,
        context: MeetVideoStreamWire.Context
    ) async throws {
        if let next, !viewedVideos.contains(next) {
            let id = nextStreamRequest()
            let request = try MeetVideoStreamWire.view(
                context: context,
                stream: next,
                requestID: id,
                header: client.streamControlHeader()
            )
            let reply = try await videoExchange(request, id: id)
            try MeetVideoStreamWire.confirmView(
                from: reply,
                context: context,
                stream: next,
                requestID: id
            )
            viewedVideo = next
            viewedVideos.removeAll { $0.source == next.source }
            viewedVideos.append(next)
        }
    }

    private func stopVideoView(
        _ stream: MeetVideoStreamWire.Downstream, context: MeetVideoStreamWire.Context
    ) async throws {
        let id = nextStreamRequest()
        let request = try MeetVideoStreamWire.view(
            context: context, stream: stream, requestID: id,
            header: client.streamControlHeader(), enabled: false
        )
        let reply = try await videoExchange(request, id: id)
        try MeetVideoStreamWire.confirmView(from: reply, context: context, stream: stream, requestID: id)
    }

    private func videoExchange(_ request: Data, id: UInt64) async throws -> Data {
        let reply = try await media.exchangeStreamControl(
            request,
            matches: { MeetAudioStreamWire.matchesRequest(
                $0,
                requestID: id
            ) },
            timeout: .seconds(8)
        )
        try await check()
        return reply
    }
}
