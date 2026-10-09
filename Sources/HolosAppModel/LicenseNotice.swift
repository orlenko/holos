import Foundation

/// The license notice the About panel shows (GPLv3 §5(d)). The license and trademark terms ship in the app's
/// `Contents/Resources`; the web links are secondary. A release build records its git tag in `Info.plist`
/// (`VoiceIsLocalSourceTag`, set by scripts/release-app.sh), so its links name the exact source it was built from.
public enum LicenseNotice {
    public static let repositoryURL = "https://github.com/orlenko/holos"
    /// The `Info.plist` key that holds the release tag of the source the app was built from.
    public static let sourceTagInfoKey = "VoiceIsLocalSourceTag"

    /// The tag, when it looks like a release tag (`v` and dot-separated integers, as scripts/release-app.sh makes);
    /// nil otherwise, so a missing or malformed value falls back to the `main` branch.
    public static func releaseTag(_ value: String?) -> String? {
        guard let value, value.hasPrefix("v") else { return nil }
        let parts = value.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return value
    }

    /// Where the source of this build is: the release tag when known, else the repository.
    public static func sourceURL(tag: String?) -> String {
        releaseTag(tag).map { "\(repositoryURL)/tree/\($0)" } ?? repositoryURL
    }

    /// A file of the repository at the release tag when known, else on `main`.
    public static func fileURL(_ path: String, tag: String?) -> String {
        "\(repositoryURL)/blob/\(releaseTag(tag) ?? "main")/\(path)"
    }

    /// - Parameters:
    ///   - bundleName: the app bundle's file name, such as `VoiceIsLocal.app`.
    ///   - sourceTag: the `VoiceIsLocalSourceTag` value from `Info.plist`, if any.
    public static func text(bundleName: String, sourceTag: String?) -> String {
        let resources = "\(bundleName)/Contents/Resources"
        return """
            Copyright © 2026 Vlad Orlenko. Voice is Local is free software: you may redistribute and modify it \
            under the GNU General Public License, version 3 or later. It comes with no warranty. The license is in \
            \(resources)/LICENSE.txt and at https://www.gnu.org/licenses/gpl-3.0.html. Source code: \
            \(sourceURL(tag: sourceTag)).

            The name Voice is Local and the app icon are not covered by the license. Bjola Software Inc. owns the \
            trademarks and the icon copyright and grants the permissions in \(resources)/TRADEMARKS.md (also at \
            \(fileURL("TRADEMARKS.md", tag: sourceTag))).
            """
    }
}
