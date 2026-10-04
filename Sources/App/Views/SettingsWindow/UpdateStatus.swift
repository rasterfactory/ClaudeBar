import Foundation

/// What Settings says about updates: the version you're on, and the one ready
/// to install. The Updates page and the sidebar footer print this, so they
/// never disagree.
struct UpdateStatus: Equatable {
    let currentVersion: String
    /// The update Sparkle found — `nil` when none was found.
    let availableVersion: String?

    /// The Updates page's subtitle.
    var summary: String {
        guard let availableVersion else { return "You're on version \(currentVersion)." }
        return "You're on version \(currentVersion). Version \(availableVersion) is ready to install."
    }

    /// The sidebar footer.
    var footer: String {
        guard let availableVersion else { return "v\(currentVersion) · up to date" }
        return "v\(currentVersion) · \(availableVersion) available"
    }

    /// The title of the card that checks or installs.
    var actionTitle: String {
        guard let availableVersion else { return "Check for Updates" }
        return "Version \(availableVersion) is available"
    }

    /// Its button.
    var buttonTitle: String { availableVersion == nil ? "Check Now" : "Install Update" }
}

extension UpdateStatus {
    /// The version this app is.
    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// No updater (a build without Sparkle): only the version you're on.
    static var installed: UpdateStatus { UpdateStatus(currentVersion: installedVersion, availableVersion: nil) }
}

#if ENABLE_SPARKLE
extension UpdateStatus {
    /// What the updater found.
    @MainActor
    init(updater: SparkleUpdater?) {
        self.init(currentVersion: Self.installedVersion,
                  availableVersion: updater?.isUpdateAvailable == true ? updater?.availableVersion : nil)
    }
}
#endif
