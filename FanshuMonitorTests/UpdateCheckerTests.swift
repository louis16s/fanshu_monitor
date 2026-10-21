import Foundation
import Testing
@testable import FanshuMonitor

struct VersionParserTests {

    // MARK: - normalize

    @Test func normalizeStripsVPrefix() {
        #expect(VersionParser.normalize("v1.2.3") == "1.2.3")
    }

    @Test func normalizeStripsUpperVPrefix() {
        #expect(VersionParser.normalize("V1.2.3") == "1.2.3")
    }

    @Test func normalizeKeepsPlainVersion() {
        #expect(VersionParser.normalize("1.2.3") == "1.2.3")
    }

    @Test func normalizeTrimsWhitespace() {
        #expect(VersionParser.normalize("  v1.2.3  ") == "1.2.3")
    }

    @Test func normalizeStripsBuildMetadata() {
        #expect(VersionParser.normalize("v1.2.3+45") == "1.2.3")
    }

    @Test func normalizeStripsPrereleaseSuffix() {
        #expect(VersionParser.normalize("v1.2.3-beta.1") == "1.2.3")
    }

    // MARK: - isNewer

    @Test func newerVersionDetected() {
        #expect(VersionParser.isNewer("1.1.0", than: "1.0.0"))
    }

    @Test func olderVersionNotNewer() {
        #expect(!VersionParser.isNewer("1.0.0", than: "1.1.0"))
    }

    @Test func sameVersionNotNewer() {
        #expect(!VersionParser.isNewer("1.0.0", than: "1.0.0"))
    }

    @Test func sameVersionWithVPrefixNotNewer() {
        #expect(!VersionParser.isNewer("v1.0.0", than: "1.0.0"))
    }

    @Test func sameVersionWithBuildMetadataNotNewer() {
        #expect(!VersionParser.isNewer("v1.0.0+2", than: "1.0.0"))
        #expect(!VersionParser.isNewer("1.0.0", than: "v1.0.0+2"))
    }

    @Test func multiDigitComponents() {
        #expect(VersionParser.isNewer("1.10.0", than: "1.9.0"))
    }

    @Test func differentMajorVersion() {
        #expect(VersionParser.isNewer("2.0.0", than: "1.9.9"))
    }

    @Test func twoPartVersion() {
        #expect(VersionParser.isNewer("1.2", than: "1.1"))
    }

    @Test func unequalComponentCount() {
        #expect(VersionParser.isNewer("1.2.1", than: "1.2"))
    }
}

struct GitHubReleaseDecodingTests {

    @Test func decodeMinimalRelease() throws {
        let json = """
        {
            "tag_name": "v1.0.0",
            "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.0.0",
            "published_at": "2026-06-07T12:00:00Z",
            "name": "v1.0.0",
            "body": "First release",
            "assets": [
                {
                    "name": "番薯Monitor.dmg",
                    "browser_download_url": "https://github.com/louis16s/fanshu_monitor/releases/download/v1.0.0/番薯Monitor.dmg"
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v1.0.0")
        #expect(release.htmlURL.absoluteString.contains("v1.0.0"))
        #expect(release.name == "v1.0.0")
        #expect(release.body == "First release")
        #expect(release.assets?.count == 1)
        #expect(release.assets?.first?.name == "番薯Monitor.dmg")
    }

    @Test func decodeReleaseWithoutOptionalFields() throws {
        let json = """
        {
            "tag_name": "v0.1.0",
            "html_url": "https://github.com/test/test/releases/tag/v0.1.0"
        }
        """
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v0.1.0")
        #expect(release.publishedAt == nil)
        #expect(release.body == nil)
        #expect(release.assets == nil)
    }
}

@MainActor
struct UpdateCheckerTests {

    @Test func automaticChecksAreThrottledForOneDay() async {
        let suiteName = "FanshuMonitorTests.UpdateChecker.throttle"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersionProvider: { "1.0.0" },
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            dataLoader: { request in
                requestCount += 1
                let json = """
                {
                    "tag_name": "v1.0.0",
                    "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.0.0"
                }
                """
                return (
                    Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        await checker.checkAutomaticallyIfNeeded(enabled: true)
        await checker.checkAutomaticallyIfNeeded(enabled: true)

        #expect(requestCount == 1)
        #expect(checker.state == .upToDate)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func failedAutomaticCheckCanRetryWithoutWaitingOneDay() async {
        let suiteName = "FanshuMonitorTests.UpdateChecker.failureRetry"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersionProvider: { "1.0.0" },
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            dataLoader: { request in
                requestCount += 1
                if requestCount == 1 { throw URLError(.notConnectedToInternet) }
                let json = """
                {
                    "tag_name": "v1.0.0",
                    "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.0.0"
                }
                """
                return (
                    Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        await checker.checkAutomaticallyIfNeeded(enabled: true)
        await checker.checkAutomaticallyIfNeeded(enabled: true)

        #expect(requestCount == 2)
        #expect(checker.state == .upToDate)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func cachedReleaseIsUsedForNotModifiedResponse() async {
        let suiteName = "FanshuMonitorTests.UpdateChecker.etag"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersionProvider: { "1.0.0" },
            defaults: defaults,
            dataLoader: { request in
                requestCount += 1
                if requestCount == 1 {
                    let json = """
                    {
                        "tag_name": "v1.1.0",
                        "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0"
                    }
                    """
                    return (
                        Data(json.utf8),
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["ETag": "release-v1"]
                        )!
                    )
                }

                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "release-v1")
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        await checker.checkForUpdates()
        await checker.checkForUpdates()

        #expect(requestCount == 2)
        guard case .updateAvailable(let latestVersion, _, _, _) = checker.state else {
            Issue.record("Expected cached update state")
            return
        }
        #expect(latestVersion == "1.1.0")
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func cachedReleaseRestoresStatusBeforeTheNextAutomaticCheck() {
        let suiteName = "FanshuMonitorTests.UpdateChecker.restore"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("""
        {
            "tag_name": "v1.1.0",
            "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0"
        }
        """.utf8), forKey: "updates.releasePayload")
        defaults.set(
            "https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest",
            forKey: "updates.releaseSource"
        )
        defaults.set(Date(), forKey: "updates.releaseFetchedAt")

        let checker = UpdateChecker(
            currentVersionProvider: { "1.0.0" },
            defaults: defaults
        )

        guard case .updateAvailable(let latestVersion, _, _, _) = checker.state else {
            Issue.record("Expected cached update state")
            return
        }
        #expect(latestVersion == "1.1.0")
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func expiredCachedReleaseIsDiscardedAndCurrentGitHubReleaseWins() async {
        let suiteName = "FanshuMonitorTests.UpdateChecker.expiredRelease"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let source = "https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(source, forKey: "updates.releaseSource")
        defaults.set("stale-v1", forKey: "updates.releaseETag")
        defaults.set(now.addingTimeInterval(-48 * 60 * 60), forKey: "updates.releaseFetchedAt")
        defaults.set(Data("""
        {
            "tag_name": "v1.1.0",
            "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0"
        }
        """.utf8), forKey: "updates.releasePayload")

        let checker = UpdateChecker(
            currentVersionProvider: { "0.3.3" },
            defaults: defaults,
            now: { now },
            dataLoader: { request in
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
                let json = """
                {
                    "tag_name": "v0.3.3",
                    "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v0.3.3"
                }
                """
                return (
                    Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        #expect(checker.state == .idle)
        #expect(defaults.data(forKey: "updates.releasePayload") == nil)
        #expect(defaults.string(forKey: "updates.releaseETag") == nil)

        await checker.checkAutomaticallyIfNeeded(enabled: true)

        #expect(checker.state == .upToDate)
        #expect(defaults.object(forKey: "updates.releaseFetchedAt") as? Date == now)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func legacyCacheWithoutMatchingSourceIsDiscarded() {
        let suiteName = "FanshuMonitorTests.UpdateChecker.legacyCache"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("""
        {
            "tag_name": "v1.1.0",
            "html_url": "https://github.com/example/test/releases/tag/v1.1.0"
        }
        """.utf8), forKey: "updates.releasePayload")
        defaults.set("test-etag", forKey: "updates.releaseETag")

        let checker = UpdateChecker(
            currentVersionProvider: { "0.3.0" },
            defaults: defaults
        )

        #expect(checker.state == .idle)
        #expect(defaults.data(forKey: "updates.releasePayload") == nil)
        #expect(defaults.string(forKey: "updates.releaseETag") == nil)
        #expect(
            defaults.string(forKey: "updates.releaseSource")
                == "https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest"
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func checkForUpdatesReportsAvailableRelease() async throws {
        let releaseURL = URL(string: "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0")!
        let assetURL = URL(string: "https://github.com/louis16s/fanshu_monitor/releases/download/v1.1.0/番薯Monitor.dmg")!
        let checker = UpdateChecker(
            currentVersionProvider: { "1.0.0" },
            dataLoader: { request in
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "FanshuMonitor")
                let json = """
                {
                    "tag_name": "v1.1.0",
                    "html_url": "\(releaseURL.absoluteString)",
                    "published_at": "2026-06-07T15:38:02Z",
                    "assets": [
                        {
                            "name": "番薯Monitor.dmg",
                            "browser_download_url": "\(assetURL.absoluteString)"
                        }
                    ]
                }
                """
                return (
                    json.data(using: .utf8)!,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        await checker.checkForUpdates()

        #expect(checker.state == .updateAvailable(
            latestVersion: "1.1.0",
            publishedAt: "2026-06-07T15:38:02Z",
            downloadURL: assetURL,
            releaseNotes: nil
        ))
    }

    @Test func checkForUpdatesReportsUpToDate() async {
        let checker = UpdateChecker(
            currentVersionProvider: { "1.1.0" },
            dataLoader: { request in
                let json = """
                {
                    "tag_name": "v1.1.0",
                    "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0"
                }
                """
                return (
                    json.data(using: .utf8)!,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        await checker.checkForUpdates()

        #expect(checker.state == .upToDate)
    }

    @Test func checkForUpdatesDoesNotReportSameVersionWithPrefix() async {
        let checker = UpdateChecker(
            currentVersionProvider: { "0.2.6" },
            dataLoader: { request in
                let json = """
                {
                    "tag_name": "v0.2.6",
                    "html_url": "https://github.com/louis16s/fanshu_monitor/releases/tag/v0.2.6"
                }
                """
                return (
                    json.data(using: .utf8)!,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        await checker.checkForUpdates()

        #expect(checker.state == .upToDate)
    }

    @Test func checkForUpdatesMapsRateLimitToFriendlyMessage() async {
        let defaults = isolatedDefaults("rateLimit")
        let checker = UpdateChecker(
            defaults: defaults,
            dataLoader: { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 403,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        await checker.checkForUpdates()

        #expect(checker.state == .failed(String(localized: "update.rate-limited")))
        defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.rateLimit")
    }

    @Test func checkForUpdatesMapsMissingReleaseToFriendlyMessage() async {
        let defaults = isolatedDefaults("missingRelease")
        let checker = UpdateChecker(
            defaults: defaults,
            dataLoader: { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        await checker.checkForUpdates()

        #expect(checker.state == .failed(String(localized: "update.no-release")))
        defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.missingRelease")
    }

    @Test func checkForUpdatesHandlesDecodeFailure() async {
        let defaults = isolatedDefaults("decodeFailure")
        let checker = UpdateChecker(
            defaults: defaults,
            dataLoader: { request in
                (
                    Data("{}".utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        await checker.checkForUpdates()

        #expect(checker.state == .failed(String(localized: "update.parse-failed")))
        defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.decodeFailure")
    }

    @Test func resolveDownloadURLFallsBackToReleasePage() throws {
        let releaseURL = URL(string: "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.0.0")!
        let json = """
        {
            "tag_name": "v1.0.0",
            "html_url": "\(releaseURL.absoluteString)",
            "assets": [
                {
                    "name": "checksums.txt",
                    "browser_download_url": "https://github.com/louis16s/fanshu_monitor/releases/download/v1.0.0/checksums.txt"
                }
            ]
        }
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))

        #expect(UpdateChecker.resolveDownloadURL(from: release) == releaseURL)
    }

    @Test func validOfficialAssetAfterAnUntrustedCandidateIsStillFound() throws {
        let data = Data(#"{"tag_name":"v1.1.0","html_url":"https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0","assets":[{"name":"first.zip","browser_download_url":"https://example.com/first.zip"},{"name":"FanshuMonitor.zip","browser_download_url":"https://github.com/louis16s/fanshu_monitor/releases/download/v1.1.0/FanshuMonitor.zip"}]}"#.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        #expect(UpdateChecker.resolveDownloadURL(from: release)?.host == "github.com")
        #expect(UpdateChecker.resolveDownloadURL(from: release)?.lastPathComponent == "FanshuMonitor.zip")
    }

    @Test func expiredPayloadDoesNotEraseAutomaticCheckThrottle() async {
        let suffix = "expiredPayloadThrottle"
        let defaults = isolatedDefaults(suffix)
        defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastCheck = now.addingTimeInterval(-60)
        defaults.set("https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest", forKey: "updates.releaseSource")
        defaults.set(releaseData(), forKey: "updates.releasePayload")
        defaults.set(now.addingTimeInterval(-172_800), forKey: "updates.releaseFetchedAt")
        defaults.set(lastCheck, forKey: "updates.lastAutomaticCheckAt")
        var requests = 0
        let checker = UpdateChecker(defaults: defaults, now: { now }, dataLoader: { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        })

        await checker.checkAutomaticallyIfNeeded(enabled: true)

        #expect(defaults.data(forKey: "updates.releasePayload") == nil)
        #expect(defaults.object(forKey: "updates.lastAutomaticCheckAt") as? Date == lastCheck)
        #expect(requests == 0)
    }

    @Test(arguments: ["{}", "invalid", "1..2", "1.2oops", "999999999999999999999999"])
    func invalidResponsePreservesValidCacheThenUses304(_ invalidVersion: String) async {
        let suffix = "preserveCache.\(invalidVersion)"
        let defaults = isolatedDefaults(suffix)
        defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
        let valid = releaseData()
        let invalid = invalidVersion == "{}" ? Data("{}".utf8) : releaseData(version: invalidVersion)
        var count = 0
        let checker = UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults, dataLoader: { request in
            count += 1
            if count > 1 {
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "good")
            }
            return (
                count == 1 ? valid : (count == 2 ? invalid : Data()),
                HTTPURLResponse(url: request.url!, statusCode: count == 3 ? 304 : 200,
                                httpVersion: nil, headerFields: ["ETag": count == 1 ? "good" : "bad"])!
            )
        })
        await checker.checkForUpdates()
        let stable = checker.state
        await checker.checkForUpdates()
        #expect(checker.lastError != nil)
        #expect(defaults.data(forKey: "updates.releasePayload") == valid)
        #expect(defaults.string(forKey: "updates.releaseETag") == "good")
        await checker.checkForUpdates()
        #expect(count == 3)
        #expect(checker.state == stable)
        #expect(checker.lastError == nil)
        #expect(UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults).state == stable)
    }

    @Test func successfulResponseWithoutETagRemovesOldConditionalHeader() async {
        let suffix = "removeETag"
        let defaults = isolatedDefaults(suffix)
        defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
        var count = 0
        let checker = UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults, dataLoader: { request in
            count += 1
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == (count == 2 ? "old" : nil))
            return (releaseData(version: count == 1 ? "v1.1.0" : "v1.2.0"),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: count == 1 ? ["ETag": "old"] : nil)!)
        })
        await checker.checkForUpdates()
        await checker.checkForUpdates()
        #expect(defaults.string(forKey: "updates.releaseETag") == nil)
        #expect(defaults.data(forKey: "updates.releasePayload") == releaseData(version: "v1.2.0"))
        await checker.checkForUpdates()
        #expect(count == 3)
    }

    @Test(arguments: ["missing", "decode", "version", "url"])
    func invalid304CacheRetriesUnconditionallyOnce(_ kind: String) async {
        let suffix = "retry304.\(kind)"
        let defaults = isolatedDefaults(suffix)
        defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
        defaults.set("https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest", forKey: "updates.releaseSource")
        defaults.set("stale", forKey: "updates.releaseETag")
        defaults.set(Date(), forKey: "updates.releaseFetchedAt")
        switch kind {
        case "decode": defaults.set(Data("{}".utf8), forKey: "updates.releasePayload")
        case "version": defaults.set(releaseData(version: "invalid"), forKey: "updates.releasePayload")
        case "url": defaults.set(releaseData(url: "file:///tmp/update.zip"), forKey: "updates.releasePayload")
        default: break
        }
        var count = 0
        let checker = UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults, dataLoader: { request in
            count += 1
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == (count == 1 ? "stale" : nil))
            return (count == 1 ? Data() : releaseData(),
                    HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 304 : 200,
                                    httpVersion: nil, headerFields: ["ETag": "fresh"])!)
        })
        #expect(checker.state == .idle)
        await checker.checkForUpdates()
        #expect(count == 2)
        #expect(checker.lastError == nil)
        #expect(defaults.string(forKey: "updates.releaseETag") == "fresh")
        #expect(defaults.data(forKey: "updates.releasePayload") == releaseData())
    }

    @Test func repeated304StopsAfterOneUnconditionalRetry() async {
        let suffix = "bounded304"
        let defaults = isolatedDefaults(suffix)
        defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
        var count = 0
        let checker = UpdateChecker(defaults: defaults, dataLoader: { request in
            count += 1
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!)
        })
        await checker.checkForUpdates()
        #expect(count == 2)
        #expect(checker.state == .failed(String(localized: "update.parse-failed")))
    }

    @Test(arguments: [
        "file:///tmp/update.zip",
        "http://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0",
        "custom://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0",
        "https://github.com/test/test/releases/tag/v1.1.0",
        "https://github.com/louis16s/fanshu_monitor-other/releases/tag/v1.1.0",
        "https://github.com.evil.example/louis16s/fanshu_monitor/releases/tag/v1.1.0",
        "https://user@github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0",
        "https://github.com/louis16s/fanshu_monitor/releases/tag/%2e%2e",
        "https://github.com/louis16s/fanshu_monitor/releases/tag/v1%2fother"
    ])
    func unsafeDownloadLinksAreRejectedByNetworkAndCache(_ url: String) async {
        for asset in [false, true] {
            let suffix = "unsafeURL.\(url.hashValue).\(asset)"
            let defaults = isolatedDefaults(suffix)
            defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
            let data = releaseData(url: url, asset: asset)
            let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
            #expect(release != nil)
            if let release { #expect(UpdateChecker.resolveDownloadURL(from: release) == nil) }
            defaults.set("https://api.github.com/repos/louis16s/fanshu_monitor/releases/latest", forKey: "updates.releaseSource")
            defaults.set(data, forKey: "updates.releasePayload")
            let checker = UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults, dataLoader: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "unsafe"])!)
            })
            #expect(checker.state == .idle)
            defaults.removeObject(forKey: "updates.releasePayload")
            await checker.checkForUpdates()
            #expect(checker.state == .failed(String(localized: "update.parse-failed")))
            #expect(defaults.data(forKey: "updates.releasePayload") == nil)
            #expect(defaults.string(forKey: "updates.releaseETag") == nil)
        }
    }

    @Test(arguments: [false, true])
    func officialDownloadLinksSurviveNetworkCheckAndCacheRestore(_ asset: Bool) async {
        let suffix = "officialURL.\(asset)"
        let defaults = isolatedDefaults(suffix)
        defer { defaults.removePersistentDomain(forName: "FanshuMonitorTests.UpdateChecker.\(suffix)") }
        let data = releaseData(asset: asset)
        let checker = UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults, dataLoader: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await checker.checkForUpdates()
        let expectedURL = URL(string: asset
            ? "https://github.com/louis16s/fanshu_monitor/releases/download/v1.1.0/FanshuMonitor.zip"
            : "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0")!
        #expect(checker.state == .updateAvailable(latestVersion: "1.1.0", publishedAt: nil,
                                                downloadURL: expectedURL, releaseNotes: nil))
        #expect(UpdateChecker(currentVersionProvider: { "1.0.0" }, defaults: defaults).state == checker.state)
    }

    private func releaseData(version: String = "v1.1.0", url: String? = nil, asset: Bool = false) -> Data {
        let page = "https://github.com/louis16s/fanshu_monitor/releases/tag/v1.1.0"
        var payload: [String: Any] = ["tag_name": version, "html_url": asset ? page : (url ?? page)]
        if asset {
            payload["assets"] = [["name": "FanshuMonitor.zip", "browser_download_url": url ??
                "https://github.com/louis16s/fanshu_monitor/releases/download/v1.1.0/FanshuMonitor.zip"]]
        }
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func isolatedDefaults(_ suffix: String) -> UserDefaults {
        let suiteName = "FanshuMonitorTests.UpdateChecker.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
