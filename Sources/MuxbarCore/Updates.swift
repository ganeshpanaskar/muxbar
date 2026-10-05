import Foundation

/// A `major.minor.patch` version, as in release tags (`v1.2.3`) and CFBundleShortVersionString.
public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major, minor, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// Parses "1.2.3", "v1.2" or "1.2.3-beta" (pre-release suffixes are ignored).
    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let core = t.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? t
        let parts = core.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let n = parts.map { $0! } + [0, 0]
        self.init(n[0], n[1], n[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The newest published release, from GitHub's `releases/latest` API.
public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var version: SemVer
    public var notes: String
    public var url: String

    public init(tag: String, version: SemVer, notes: String, url: String) {
        self.tag = tag; self.version = version; self.notes = notes; self.url = url
    }
}

public enum Updates {
    /// Canonical repository updates come from (forks still update from upstream releases).
    public static let repo = "ganeshpanaskar/muxbar"
    public static let repoURL = "https://github.com/\(repo).git"
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// How often a running app re-checks.
    public static let interval: TimeInterval = 24 * 3600

    public enum Decision: Equatable, Sendable {
        case upToDate
        /// Same major version: installed without asking.
        case automatic(ReleaseInfo)
        /// New major version: may break things, so the user is asked first.
        case askFirst(ReleaseInfo)
    }

    public static func decide(current: SemVer, latest: ReleaseInfo?) -> Decision {
        guard let latest, latest.version > current else { return .upToDate }
        return latest.version.major > current.major ? .askFirst(latest) : .automatic(latest)
    }

    /// Parses the `releases/latest` JSON. Drafts, pre-releases and non-semver tags are ignored.
    public static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, let v = SemVer(tag),
              (o["draft"] as? Bool) != true, (o["prerelease"] as? Bool) != true else { return nil }
        return ReleaseInfo(tag: tag, version: v, notes: (o["body"] as? String) ?? "",
                           url: (o["html_url"] as? String) ?? "https://github.com/\(repo)/releases")
    }

    /// Tags are passed to git and the shell, so only plain version tags are accepted.
    public static func isSafeTag(_ tag: String) -> Bool {
        tag.range(of: #"^v?[0-9]+(\.[0-9]+){0,2}([-+][A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil
    }

    /// `src=…` (the source checkout install.sh ran from) in `~/.muxbar/install.conf`.
    public static func sourceDir(conf text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("src=") {
                let v = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Script that moves the checkout to release `tag` and reinstalls (install.sh quits and
    /// relaunches the app). It refuses to touch a checkout with local changes or commits that
    /// aren't in the release, so contributors' work is never overwritten.
    public static func updateScript(sourceDir: String, tag: String) -> String {
        """
        set -e
        cd \(shellQuote(sourceDir))
        [ -x ./install.sh ] || { echo "not a Muxbar checkout: $(pwd)" >&2; exit 3; }
        [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "the checkout isn't on main" >&2; exit 6; }
        [ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "the checkout has local changes" >&2; exit 4; }
        git fetch --quiet --force \(shellQuote(repoURL)) "refs/tags/\(tag):refs/tags/\(tag)"
        git merge --ff-only --quiet \(shellQuote("refs/tags/" + tag)) || { echo "local commits aren't in \(tag); update by hand" >&2; exit 5; }
        ./install.sh </dev/null
        """
    }
}
