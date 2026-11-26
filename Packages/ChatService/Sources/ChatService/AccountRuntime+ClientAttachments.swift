import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchClientAttachment(
        _ request: ServiceRequest,
        context: ServiceSessionContext
    ) throws -> JSONValue {
        let key = ClientInterestKey(context)
        let now = ContinuousClock.now
        expireClientInterests(at: now)
        switch request.operation {
        case AttachAccountClient.operation:
            return try attachClient(request, key: key, now: now)
        case DetachAccountClient.operation:
            let payload = try request.decodePayload(DetachAccountClient.self)
            if let lease = clientInterests[key]?.lease, lease.id == payload.attachmentID {
                clientInterests[key]?.lease = nil
                clientInterests[key]?.retainedUntil = now + .seconds(120)
                closeAttachmentSubscriptions(lease.id)
                clientInterestsChanged()
            }
            return try ServiceCodec.value(ServiceUnit())
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    private func attachClient(
        _ request: ServiceRequest, key: ClientInterestKey, now: ContinuousClock.Instant
    ) throws -> JSONValue {
        guard interestRevision < UInt64.max else {
            clientInterestsChanged(); throw ServiceFailure.overloaded
        }
        let payload = try request.decodePayload(AttachAccountClient.self)
        guard let deadline = request.header.deadline,
              deadline.timeIntervalSinceNow > 0, deadline.timeIntervalSinceNow <= 60,
              let generation = UInt64(payload.generation), generation > 0,
              String(generation) == payload.generation else { throw ServiceFailure.invalidRequest }
        if let current = clientInterests[key] {
            guard generation >= current.generation else { throw ServiceFailure.clientAttachmentExpired }
            if generation == current.generation {
                guard var lease = current.lease else { throw ServiceFailure.clientAttachmentExpired }
                lease.expires = now + .seconds(60)
                clientInterests[key]?.lease = lease
                clientInterests[key]?.retainedUntil = now + .seconds(120)
                return try attachmentValue(lease.id)
            }
            if let previous = current.lease {
                closeAttachmentSubscriptions(previous.id)
            }
        } else {
            guard clientInterests.count < 256 else { throw ServiceFailure.overloaded }
        }
        guard clientInterests[key]?.lease != nil || clientInterests.values
            .count(where: { $0.lease != nil }) < 64
        else { throw ServiceFailure.overloaded }
        let lease = ClientInterestLease(
            id: ClientAttachmentID(UUID().uuidString),
            expires: now + .seconds(60)
        )
        clientInterests[key] = ClientInterestSlot(
            generation: generation, retainedUntil: now + .seconds(120), lease: lease
        )
        clientInterestsChanged()
        startInterestSweep()
        return try attachmentValue(lease.id)
    }

    func validateAttachment(
        _ id: ClientAttachmentID?, context: ServiceSessionContext
    ) throws -> ClientInterestKey {
        let key = ClientInterestKey(context)
        guard let id, let lease = clientInterests[key]?.lease,
              lease.id == id, lease.expires > .now else { throw ServiceFailure.clientAttachmentExpired }
        return key
    }

    func closeAttachmentSubscriptions(_ attachment: ClientAttachmentID) {
        for (id, owner) in subscriberAttachments where owner == attachment {
            subscribers.removeValue(forKey: id)?.finish(throwing: ServiceFailure.clientAttachmentExpired)
            subscriberAttachments[id] = nil
        }
    }

    func expireClientInterests(at now: ContinuousClock.Instant) {
        var changed = false
        for (key, var slot) in clientInterests {
            if var lease = slot.lease {
                if lease.expires <= now {
                    slot.lease = nil
                    closeAttachmentSubscriptions(lease.id)
                    changed = true
                } else {
                    let before = lease.typing.count
                    lease.typing = lease.typing.filter {
                        $0.value > now && (try? authorizePrivacy($0.key.command(active: true))) != nil
                    }
                    changed = changed || before != lease.typing.count
                    lease.hints = lease.hints.filter { $0.value.retainUntil > now }
                    slot.lease = lease
                }
            }
            clientInterests[key] = slot.lease == nil && slot.retainedUntil <= now ? nil : slot
        }
        if changed {
            clientInterestsChanged()
        }
    }

    private func attachmentValue(_ id: ClientAttachmentID) throws -> JSONValue {
        try ServiceCodec.value(ClientAttachment(id: id, expiresAt: Date().addingTimeInterval(60)))
    }

    private func startInterestSweep() {
        guard interestSweep == nil else { return }
        interestSweep = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard await self?.sweepInterestTick() == true else { return }
            }
        }
    }

    private func sweepInterestTick() -> Bool {
        expireClientInterests(at: .now)
        if clientInterests.isEmpty {
            interestSweep = nil; return false
        }
        return true
    }
}
