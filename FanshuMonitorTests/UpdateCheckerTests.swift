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

    private func isolatedDefaults(_ suffix: String) -> UserDefaults {
        let suiteName = "FanshuMonitorTests.UpdateChecker.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
