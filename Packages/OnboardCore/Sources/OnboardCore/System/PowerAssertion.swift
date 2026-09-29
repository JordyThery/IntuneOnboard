import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while provisioning runs (replaces the script's caffeinate).
/// Released on deinit or explicit release().
public final class PowerAssertion: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var active = false
    private let lock = NSLock()

    public init(reason: String = "Intune Onboard provisioning in progress") {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        active = result == kIOReturnSuccess
        if active {
            OnboardLog.daemon.info("power assertion acquired (\(self.assertionID))")
        } else {
            OnboardLog.daemon.error("power assertion failed: \(result)")
        }
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        if active {
            IOPMAssertionRelease(assertionID)
            active = false
        }
    }

    deinit {
        release()
    }
}
