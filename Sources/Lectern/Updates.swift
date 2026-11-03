import AppKit
import Sparkle

/// Software updates through Sparkle. Nothing is checked until the user agrees: Sparkle asks on the
/// second launch, and Lectern ▸ Check for Updates Automatically changes the answer later.
/// The feed is appcast.xml on the latest GitHub release (SUFeedURL in Info.plist), and each update
/// must be signed with the EdDSA key whose public half is SUPublicEDKey.
enum Updates {
    /// nil when running outside an app bundle (`swift run`), where Sparkle has nothing to update.
    private static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    static func start() {
        _ = controller
    }

    static var isAvailable: Bool { controller != nil }

    static var canCheck: Bool { controller?.updater.canCheckForUpdates == true }

    static func checkNow() {
        controller?.checkForUpdates(nil)
    }

    static var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates == true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
