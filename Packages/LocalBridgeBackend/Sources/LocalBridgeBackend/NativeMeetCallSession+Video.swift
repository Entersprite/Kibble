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
            let next = try await selectedRemoteVideo(streams)
            if next?.source != receivingVideo?.source {
                await media.showRemoteVideo(false)
                let local = try await media.renewVideoOffer()
                try await check()
                let offer = try MeetVideoOffer(sdp: local.sdp)
                guard offer.source == videoSource else { throw CallMediaError.negotiationFailed }
                let answer = try offer.answer(serverConfiguration: configuration, receiving: next?.source)
                try await media.applyVideoAnswer(answer)
                try await check()
                receivingVideo = next
                viewedVideo = nil
            }
            receivingVideo = next
            try await requestVideoView(next, context: context)
            try await check()
            await media.showRemotePresentation(next.map { !$0.isCamera && !$0.muted } ?? false)
            await media.showRemoteVideo(next.map { !$0.muted } ?? false)
            recordVideoStatus(next
                .map {
                    $0
                        .muted ? "remote video off" :
                        ($0.isCamera ? "remote camera selected" : "remote presentation selected")
                } ??
                "no remote camera")
        } catch {
            await media.cancelVideoOffer()
            guard !closed, !Task.isCancelled else { return }
            if !searched {
                await publishRemoteAudio(nil)
            }
            await media.showRemoteVideo(false)
            await media.showRemotePresentation(false)
            recordVideoStatus("receiving unavailable; " + MeetDMCallTrial.errorDescription(error))
        }
    }

    private func selectedRemoteVideo(_ streams: [MeetVideoStreamWire.Downstream]) async throws
        -> MeetVideoStreamWire.Downstream? {
        if let source = await presentation?.source {
            rememberPresentationSource(source)
        }
        try await check()
        let remote = streams.filter { $0.isCamera || !ownPresentationSources.contains($0.source) }
        // The receiving slot prioritizes a unique active presentation, then camera.
        return MeetVideoStreamWire.preferred(remote)
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
        if let next, viewedVideo != next {
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
        }
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
