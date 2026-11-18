import Foundation

/// `existingMacs`: whether this Mac was set up before Intune Onboard arrived.
///
/// Decided once, before the daemon's first run, and then kept in
/// `DeviceState.skippedAsExisting`. Deciding again later would turn a new
/// Mac into an existing one once enough time has passed.
public enum ExistingMac {
    /// Written when Setup Assistant finishes.
    public static let setupDoneURL = URL(filePath: "/var/db/.AppleSetupDone")

    /// When Setup Assistant finished; nil while it has not.
    public static func setupCompletedAt(url: URL = setupDoneURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// - Parameter deviceState: nil when the daemon has never saved state,
    ///   which is the only time a Mac can still be classified as existing.
    public static func applies(
        configuration: Configuration?,
        deviceState: DeviceState?,
        setupCompletedAt: Date?,
        now: Date = .now
    ) -> Bool {
        guard let rule = configuration?.existingMacs, rule.skip,
              configuration?.dryRun != true,
              deviceState == nil,
              let setupCompletedAt
        else { return false }
        return now.timeIntervalSince(setupCompletedAt) >= TimeInterval(rule.setupOlderThanHours) * 3600
    }

    /// Records onboarding as done for the current user, once.
    public static func recordUserSkipped(store: StateStore = .forCurrentUser()) {
        guard ((try? store.loadUserState()) ?? nil) == nil else { return }
        do {
            try store.saveUserState(UserState(completedAt: .now))
            OnboardLog.app.notice("existing Mac: onboarding recorded as done for this user")
        } catch {
            OnboardLog.app.error("existing Mac: could not record onboarding: \(error.localizedDescription, privacy: .public)")
        }
    }
}
