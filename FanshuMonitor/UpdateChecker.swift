import Foundation

nonisolated private enum UpdateTransport {
    static let requestTimeout: TimeInterval = 15

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

@MainActor
@Observable
final class UpdateChecker {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    private(set) var state: UpdateCheckState = .idle
    private(set) var lastError: String?

    private let latestReleaseURL: URL
    private let currentVersionProvider: () -> String
    private let dataLoader: DataLoader
    private let defaults: UserDefaults
    private let now: () -> Date
    private var lastStableState: UpdateCheckState?

    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    private static let releaseSourceKey = "updates.releaseSource"
    private static let lastAutomaticCheckKey = "updates.lastAutomaticCheckAt"
    private static let releaseETagKey = "updates.releaseETag"
    private static let releasePayloadKey = "updates.releasePayload"

    init(
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest")!,
        currentVersionProvider: @escaping () -> String = {
            AppVersion.current
        },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        dataLoader: @escaping DataLoader = { request in
            try await UpdateTransport.load(request)
        }
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.currentVersionProvider = currentVersionProvider
        self.defaults = defaults
        self.now = now
        self.dataLoader = dataLoader
        prepareCacheForCurrentSource()
        restoreCachedReleaseIfAvailable()
    }

    var currentVersion: String {
        currentVersionProvider()
    }

    func checkForUpdates() async {
        _ = await performCheck()
    }

    func checkAutomaticallyIfNeeded(enabled: Bool) async {
        guard enabled else { return }
        let currentDate = now()
        if let lastCheck = defaults.object(forKey: Self.lastAutomaticCheckKey) as? Date,
           currentDate.timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
            return
        }
        if await performCheck() {
            defaults.set(currentDate, forKey: Self.lastAutomaticCheckKey)
        }
    }

    private func performCheck() async -> Bool {
        guard !state.isChecking else { return false }
        state = .checking
        lastError = nil

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FanshuMonitor", forHTTPHeaderField: "User-Agent")
        if let etag = defaults.string(forKey: Self.releaseETagKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.timeoutInterval = UpdateTransport.requestTimeout

        do {
            for attempt in 0...1 {
                let (data, response) = try await dataLoader(request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    reportFailure(String(localized: "update.temp-unavailable"))
                    return false
                }

                let releaseData: Data
                if httpResponse.statusCode == 304 {
                    guard let cachedData = defaults.data(forKey: Self.releasePayloadKey),
                          (try? validatedState(from: cachedData)) != nil else {
                        defaults.removeObject(forKey: Self.releasePayloadKey)
                        defaults.removeObject(forKey: Self.releaseETagKey)
                        defaults.removeObject(forKey: Self.lastAutomaticCheckKey)
                        if attempt == 0 {
                            request.setValue(nil, forHTTPHeaderField: "If-None-Match")
                            continue
                        }
                        reportFailure(String(localized: "update.parse-failed"))
                        return false
                    }
                    releaseData = cachedData
                } else if (200...299).contains(httpResponse.statusCode) {
                    releaseData = data
                } else {
                    reportFailure(failureMessage(for: response, data: data))
                    return false
                }

                let newState: UpdateCheckState
                do {
                    newState = try validatedState(from: releaseData)
                } catch ValidationError.invalidVersion {
                    reportFailure(String(localized: "update.version-parse-failed"))
                    return false
                } catch {
                    reportFailure(String(localized: "update.parse-failed"))
                    return false
                }
                if httpResponse.statusCode != 304 {
                    defaults.set(releaseData, forKey: Self.releasePayloadKey)
                    if let etag = httpResponse.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                        defaults.set(etag, forKey: Self.releaseETagKey)
                    } else {
                        defaults.removeObject(forKey: Self.releaseETagKey)
                    }
                }
                setStableState(newState)
                return true
            }
            return false
        } catch {
            reportFailure(String(localized: "update.network-error"))
            return false
        }
    }

    func reset() {
        state = .idle
        lastError = nil
    }

    private func setStableState(_ newState: UpdateCheckState) {
        lastStableState = newState
        lastError = nil
        state = newState
    }

    private func reportFailure(_ message: String) {
        lastError = message
        state = lastStableState ?? .failed(message)
    }

    private func restoreCachedReleaseIfAvailable() {
        guard let data = defaults.data(forKey: Self.releasePayloadKey),
              let restoredState = try? validatedState(from: data) else {
            return
        }
        setStableState(restoredState)
    }

    private enum ValidationError: Error {
        case invalidVersion
        case invalidDownloadURL
    }

    private func validatedState(from data: Data) throws -> UpdateCheckState {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latestVersion = VersionParser.normalize(release.tagName)
        let components = latestVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
                && Int(component) != nil
        }) else { throw ValidationError.invalidVersion }
        guard let downloadURL = Self.resolveDownloadURL(from: release) else {
            throw ValidationError.invalidDownloadURL
        }

        if VersionParser.isNewer(latestVersion, than: currentVersion) {
            return .updateAvailable(
                latestVersion: latestVersion,
                publishedAt: release.publishedAt,
                downloadURL: downloadURL,
                releaseNotes: release.body
            )
        }
        return .upToDate
    }

    private func prepareCacheForCurrentSource() {
        let source = latestReleaseURL.absoluteString
        guard defaults.string(forKey: Self.releaseSourceKey) != source else { return }

        defaults.removeObject(forKey: Self.lastAutomaticCheckKey)
        defaults.removeObject(forKey: Self.releaseETagKey)
        defaults.removeObject(forKey: Self.releasePayloadKey)
        defaults.set(source, forKey: Self.releaseSourceKey)
    }

    static func resolveDownloadURL(from release: GitHubRelease) -> URL? {
        if let assets = release.assets {
            for asset in assets {
                let name = asset.name.lowercased()
                if name.hasSuffix(".dmg") || name.hasSuffix(".zip") {
                    return isOfficialReleaseURL(asset.browserDownloadURL, asset: true)
                        ? asset.browserDownloadURL : nil
                }
            }
        }
        return isOfficialReleaseURL(release.htmlURL, asset: false) ? release.htmlURL : nil
    }

    private static func isOfficialReleaseURL(_ url: URL, asset: Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil else { return false }
        let encodedPath = components.percentEncodedPath.lowercased()
        guard !encodedPath.contains("%2f"), !encodedPath.contains("%5c") else { return false }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == (asset ? 7 : 6), parts[0].isEmpty,
              parts[1] == "louis16s", parts[2] == "fanshu_monitor", parts[3] == "releases",
              parts[4] == (asset ? "download" : "tag"),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            return false
        }
        return true
    }

    private func failureMessage(for response: URLResponse, data: Data) -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            return String(localized: "update.temp-unavailable")
        }

        switch httpResponse.statusCode {
        case 403, 429:
            return String(localized: "update.rate-limited")
        case 404:
            return String(localized: "update.no-release")
        case 500...599:
            return String(localized: "update.github-unavailable")
        default:
            if let githubError = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data),
               let message = githubError.message,
               !message.isEmpty {
                return String(localized: "update.check-failed") + "\(message)"
            }
            return String(localized: "update.temp-unavailable")
        }
    }
}

enum VersionParser {
    static func normalize(_ tag: String) -> String {
        var result = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("v") || result.hasPrefix("V") {
            result.removeFirst()
        }
        if let metadataIndex = result.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            result = String(result[..<metadataIndex])
        }
        return result
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let lhsParts = parse(normalize(lhs))
        let rhsParts = parse(normalize(rhs))
        guard !lhsParts.isEmpty, !rhsParts.isEmpty else { return false }
        let count = max(lhsParts.count, rhsParts.count)

        for i in 0..<count {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l > r { return true }
            if l < r { return false }
        }
        return false
    }

    private static func parse(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
