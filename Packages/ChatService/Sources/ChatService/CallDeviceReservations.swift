import ChatAPI
import Foundation

/// Shared across accounts; each principal/device has an independent media lease.
actor CallDeviceReservations {
    struct Device: Hashable, Sendable {
        let principal: ServicePrincipalID
        let device: ServiceDeviceID
    }

    struct Owner: Equatable, Sendable {
        let runtime: UUID
        let call: UUID
    }

    private var owners: [Device: Owner] = [:]

    func acquire(_ device: Device, owner: Owner) throws {
        if let current = owners[device] {
            guard current == owner else { throw ServiceFailure.deviceBusy }
            return
        }
        guard owners.count < 1024 else { throw ServiceFailure.overloaded }
        owners[device] = owner
    }

    func release(_ device: Device, owner: Owner) {
        guard owners[device] == owner else { return }
        owners[device] = nil
    }
}
