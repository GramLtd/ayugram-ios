import Foundation

// AYG: the App Group container, with a fallback for sideloaded builds.
//
// Telegram keeps its whole database in `group.<bundle id>`. Re-signing tools
// (Sideloadly, AltStore, free developer accounts) change the bundle id and either
// drop the app group or rename it, so `containerURL(forSecurityApplicationGroupIdentifier:)`
// returns nil. Upstream then gives up at launch ("Error 2", presented before the
// window is visible — a black screen).
//
// The main app falls back to a directory inside its own sandbox instead. Extensions
// get no fallback: they cannot see the app's sandbox, so pretending would only hand
// them an empty database; they keep failing gracefully as before.
public func aygAppGroupContainerURL(appGroupName: String) -> URL? {
    if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) {
        return url
    }
    if Bundle.main.bundleURL.pathExtension == "appex" {
        return nil
    }
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    let url = base.appendingPathComponent("AYGLocalAppGroup", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        return nil
    }
    return url
}
