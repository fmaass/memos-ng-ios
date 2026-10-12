import Foundation
import MemosOutbox

/// The device's preferences, now that they live in the phone's Settings app.
///
/// The Settings app shows `Settings.bundle/Root.plist` and writes what is chosen there into the
/// domain the pane's root names: the app group (`ApplicationGroupContainerIdentifier`). So the
/// mobile-data choice lands in the very suite the outbox and the share extension read at the
/// moment of use, with no copy in between for a process that never comes to the front to miss.
/// It does nothing else: it registers no defaults (a pane never opened has written nothing, so the
/// app would read nil where the pane shows its default), it cannot run code (so the version it
/// shows is whatever the app last wrote), and it tells no running process what changed. Each of
/// those gaps is one function here, and the app target only composes them: `launch` once,
/// `activate` on every return to the front.
@MainActor
public enum SettingsBundleSync {
    /// The read-only Version row's key. Written by the app; the pane only displays it.
    public static let versionKey = "settings.version"

    /// The one suite the pane writes and the app reads the pane's keys from: the app group's,
    /// falling back to the app's own when the group is unreachable — the outbox's own degradation
    /// (`UploadPreferences.live`), so the two still agree on one suite.
    public static var paneDefaults: UserDefaults {
        UserDefaults(suiteName: OutboxDefaults.appGroup) ?? .standard
    }

    /// The pane's own file inside a built bundle, or nil when that bundle carries none.
    public static func rootPlist(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "Root", withExtension: "plist", subdirectory: "Settings.bundle")
    }

    /// The pane's rows, in the order the Settings app shows them; empty when the file is missing
    /// or is not the dictionary the Settings app reads.
    public static func specifiers(in plist: URL) -> [[String: Any]] {
        root(of: plist)?["PreferenceSpecifiers"] as? [[String: Any]] ?? []
    }

    /// The app group the pane's root names as the domain the Settings app writes, or nil when it
    /// names none — and the Settings app then writes the app's own defaults, which neither the
    /// outbox nor the share extension reads.
    public static func paneGroup(in plist: URL) -> String? {
        root(of: plist)?["ApplicationGroupContainerIdentifier"] as? String
    }

    private static func root(of plist: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: plist),
            let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return parsed as? [String: Any]
    }

    /// Every row that has a key, its default registered — the registration domain, so nothing is
    /// written and a later choice in the pane still wins.
    public static func registerDefaults(from plist: URL, into defaults: UserDefaults) {
        var registered: [String: Any] = [:]
        for row in specifiers(in: plist) {
            guard let key = row["Key"] as? String, let value = row["DefaultValue"] else { continue }
            registered[key] = value
        }
        defaults.register(defaults: registered)
    }

    public static func writeVersion(_ line: String, into defaults: UserDefaults) {
        defaults.set(line, forKey: versionKey)
    }

    /// The one-time move of the appearance into the pane's suite.
    ///
    /// Builds before this one kept it in the app's own defaults, where the Settings app no longer
    /// looks, so the first launch of this build would show "System" to someone who chose Dark —
    /// unless it is carried across first. Only a group holding no appearance of its own is seeded,
    /// so it happens once, and a choice made in the pane afterwards is never undone.
    ///
    /// Both suites are asked through their persistent domains, never `object(forKey:)`: the
    /// registration domain is shared by every defaults object in the process, so once launch has
    /// registered the pane's "system" each answers it for a key nobody saved there. Key PRESENCE
    /// decides, so a saved "system" is carried like any other choice.
    /// - Parameters:
    ///   - domain: `standard`'s persistent domain — the bundle identifier for the app's own
    ///     defaults, the suite name for a scratch suite.
    ///   - groupDomain: `group`'s persistent domain — the app group's identifier in the app, the
    ///     suite name for a scratch suite.
    public static func seedAppearance(
        standard: UserDefaults, domain: String, group: UserDefaults, groupDomain: String
    ) {
        let key = AppSettings.appearanceKey
        guard group.persistentDomain(forName: groupDomain)?[key] == nil,
            let saved = standard.persistentDomain(forName: domain)?[key] as? String
        else { return }
        group.set(saved, forKey: key)
    }

    /// Everything launch has to do before the first read of either preference, all into the
    /// pane's suite: the defaults the pane shows, an appearance an earlier build saved carried
    /// across, the version the pane displays.
    /// - Parameter group: the pane's suite — `paneDefaults` in the app.
    public static func launch(
        from bundle: Bundle, standard: UserDefaults, domain: String, group: UserDefaults,
        groupDomain: String
    ) {
        if let plist = rootPlist(in: bundle) {
            registerDefaults(from: plist, into: group)
        }
        seedAppearance(standard: standard, domain: domain, group: group, groupDomain: groupDomain)
        writeVersion(AboutInfo.versionLine(from: bundle), into: group)
    }

    /// The app is in front again, and the Settings app may have changed either choice meanwhile.
    ///
    /// The pane wrote the group itself, so every reader at the moment of use already has it; what
    /// has not seen it is this process's state in memory. One synchronous path, in this order:
    /// re-read the appearance; bring the switch's model to the group's value, whose apply tells
    /// the outbox synchronously so the verdict it shows is the new one; and only then open
    /// scheduling and drain, so that drain reads the new answer. An unchanged choice writes and
    /// tells nothing.
    /// - Returns: the foreground drain `Outbox.appBecameActive` started, if there is an outbox.
    @discardableResult
    public static func activate(
        settings: AppSettings,
        uploads: UploadSettings?,
        outbox: Outbox?
    ) -> Task<Void, Never>? {
        settings.reload()
        uploads?.reload()
        return outbox?.appBecameActive()
    }
}
