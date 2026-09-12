import Foundation

/// The contract between the iOS Share Extension and the containing app
/// (docs/PLAN.md §Phase 3B, docs/ADR-0017).
///
/// Two processes have to agree on three things and nothing more: **where** the
/// picked image is written (a directory in the shared App Group container),
/// **how** the extension tells the app about it (a custom URL scheme opened with
/// `NSExtensionContext.open(_:completionHandler:)`), and **what** a legal
/// payload looks like. All three live here, in the bottom package, because the
/// extension target and the app target have no other code in common — a
/// constant duplicated in two targets is exactly the kind of thing that drifts
/// and then fails only on a real device.
///
/// **The parameter is a file *name*, never a path.** Any app on the phone can
/// open `retouchpro://`, so the URL is untrusted input. The app never uses the
/// string as a location: it sanitises it (``isSafeFileName(_:)``) and then
/// resolves it *inside* our own inbox directory (``resolve(_:inboxURL:)``), so
/// the worst a hostile caller can do is name a file that does not exist.
public enum ShareHandoff: Sendable {
    /// The App Group both targets are entitled to. Must match the
    /// `com.apple.security.application-groups` array in
    /// `App/RetouchPro.entitlements` **and**
    /// `ShareExtension/RetouchProShareExtension.entitlements`.
    public static let appGroupIdentifier = "group.com.duynguyen.RetouchPro"

    /// Registered by the app in `Config/RetouchPro-Info.plist` (`CFBundleURLTypes`).
    public static let urlScheme = "retouchpro"

    /// `retouchpro://open?…` — the only host the app answers.
    public static let openHost = "open"

    /// Repeated once per image: `?file=IMG_0042.HEIC`.
    public static let fileQueryName = "file"

    /// Bumped if the payload shape ever changes; the app refuses what it does
    /// not understand rather than guessing.
    public static let versionQueryName = "v"
    public static let version = 1

    /// Sub-directory of the App Group container the extension writes into.
    public static let inboxDirectoryName = "ShareInbox"

    /// What one `retouchpro://open` URL asked for.
    public struct OpenRequest: Sendable, Hashable {
        /// Sanitised file names, in the order they appeared in the URL.
        public var fileNames: [String]

        public init(fileNames: [String]) {
            self.fileNames = fileNames
        }
    }

    // MARK: - Container

    /// `<App Group container>/ShareInbox`, or `nil` when this process is not
    /// entitled to the group.
    ///
    /// `nil` is a real, reportable state and not a crash: a build signed without
    /// the entitlement (or a unit test running outside a container) gets it, and
    /// both sides log it instead of trapping.
    public static func inboxURL(
        appGroupIdentifier: String = ShareHandoff.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    /// Same directory, created if missing. The extension calls this before it
    /// writes; the app only reads.
    public static func createInbox(
        appGroupIdentifier: String = ShareHandoff.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let url = inboxURL(appGroupIdentifier: appGroupIdentifier, fileManager: fileManager)
        else { throw ShareHandoffError.appGroupUnavailable(appGroupIdentifier) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Names

    /// Whether a string may be used as a file name inside the inbox.
    ///
    /// Rejects anything that could escape the directory or address something
    /// other than one importable image: separators, `..`, dot-files, empty
    /// names, and extensions outside `ProjectBundle.importableExtensions`.
    public static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard !name.hasPrefix(".") else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        guard name != ".", name != ".." else { return false }
        // `lastPathComponent` of a name with no separators is the name itself;
        // if it is not, something path-like slipped through the checks above.
        guard (name as NSString).lastPathComponent == name else { return false }
        return ProjectBundle.isImportableExtension((name as NSString).pathExtension)
    }

    /// Turns a provider's suggested name into one that is safe **and** free
    /// inside `directory`, keeping the human-readable stem when it can.
    ///
    /// The stem matters: `ShotIngestor` stores the file name as
    /// `Shot.originalFileName`, which is what the filmstrip shows — a UUID there
    /// would be a regression against every other import path.
    public static func uniqueFileName(
        suggested: String?,
        fallbackExtension: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> String {
        let ext = normalisedExtension(
            of: suggested.map { ($0 as NSString).pathExtension } ?? "",
            fallback: fallbackExtension)
        var stem = suggested.map { ($0 as NSString).deletingPathExtension } ?? ""
        stem = stem.components(separatedBy: unsafeNameCharacters).joined()
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty || stem.hasPrefix(".") { stem = "Shared" }
        if stem.count > 120 { stem = String(stem.prefix(120)) }

        var candidate = "\(stem).\(ext)"
        var attempt = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path),
            attempt < 1000
        {
            candidate = "\(stem)-\(attempt).\(ext)"
            attempt += 1
        }
        return candidate
    }

    /// Lower-cased `ext` when it is an importable one, else `fallback` (itself
    /// checked, else `jpg`). Keeps HEIC/ARW as-is: nothing in this path
    /// re-encodes, same rule as `ImportOptions` (docs/ADR-0003).
    public static func normalisedExtension(of ext: String, fallback: String) -> String {
        let lowered = ext.lowercased()
        if ProjectBundle.isImportableExtension(lowered) { return lowered }
        let loweredFallback = fallback.lowercased()
        if ProjectBundle.isImportableExtension(loweredFallback) { return loweredFallback }
        return "jpg"
    }

    private static let unsafeNameCharacters = CharacterSet(charactersIn: "/\\:\0\n\r\t")

    // MARK: - URL

    /// `retouchpro://open?v=1&file=…` for the names the extension just wrote.
    ///
    /// Returns `nil` rather than a half-formed URL when every name was rejected,
    /// so the extension reports "nothing to hand over" instead of launching the
    /// app with an empty request.
    public static func makeOpenURL(fileNames: [String]) -> URL? {
        let safe = fileNames.filter(isSafeFileName)
        guard !safe.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = openHost
        components.queryItems =
            [URLQueryItem(name: versionQueryName, value: String(version))]
            + safe.map { URLQueryItem(name: fileQueryName, value: $0) }
        return components.url
    }

    /// Parses a URL the system handed the app. `nil` for anything that is not
    /// one of ours, is a version we do not know, or carries no usable name.
    public static func parse(_ url: URL) -> OpenRequest? {
        guard url.scheme?.lowercased() == urlScheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard (components.host ?? "").lowercased() == openHost else { return nil }
        let items = components.queryItems ?? []
        if let raw = items.first(where: { $0.name == versionQueryName })?.value {
            guard Int(raw) == version else { return nil }
        }
        let names = items
            .filter { $0.name == fileQueryName }
            .compactMap(\.value)
            .filter(isSafeFileName)
        guard !names.isEmpty else { return nil }
        return OpenRequest(fileNames: names)
    }

    /// The files a request points at, as absolute URLs inside the inbox,
    /// dropping any that are not actually there.
    public static func resolve(
        _ request: OpenRequest,
        inboxURL: URL?,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let inboxURL else { return [] }
        return request.fileNames
            .filter(isSafeFileName)
            .map { inboxURL.appendingPathComponent($0, isDirectory: false) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Deletes a handed-over file once the app has copied it into a project.
    ///
    /// The inbox is a hand-off buffer, not storage: the image already lives in
    /// the user's Photos library and, after ingest, in `originals/` as well.
    /// Failures are ignored on purpose — a file left behind costs disk, a thrown
    /// error would cost the user their editor.
    public static func discard(_ urls: [URL], fileManager: FileManager = .default) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }
}

public enum ShareHandoffError: Error, Equatable, CustomStringConvertible {
    case appGroupUnavailable(String)
    case noImageInShareItem
    case couldNotWriteToInbox(String)

    public var description: String {
        switch self {
        case .appGroupUnavailable(let id):
            "This build is not entitled to the App Group \(id)."
        case .noImageInShareItem:
            "The shared item carried no image this app can read."
        case .couldNotWriteToInbox(let reason):
            "Could not write the shared image into the App Group inbox: \(reason)"
        }
    }
}
