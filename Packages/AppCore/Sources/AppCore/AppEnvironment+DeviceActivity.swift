import Foundation

/// Whether this Mac is in use - awake, displays on, unlocked - so the backend
/// can keep you shown as active (active-presence spec §5). Reported by the
/// host, the only layer that can see the Mac: `MacHost`'s
/// `DeviceActivityMonitor`.
public extension AppEnvironment {
    /// Held while no session runs and sent once one does, after it connects;
    /// every change is sent while one runs. A hint: a backend that cannot keep
    /// you active ignores it.
    func setDeviceActive(_ active: Bool) {
        deviceInUse = active
        runningModel?.reportActivity(active)
    }
}
