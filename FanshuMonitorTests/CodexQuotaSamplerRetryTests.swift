import Foundation
import Testing
@testable import FanshuMonitor

struct CodexQuotaSamplerRetryTests {
    @Test func accountSelectionAndFailedResetUseExistingBackoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"test","account_id":"selected-account"}}"#.utf8).write(to: auth)
        let clock = CodexRetryClock()
        let counter = CodexRetryCounter()
        let client = CodexUsageClient(authFileURL: auth, transport: { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "selected-account")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            if counter.increment() > 1 { throw URLError(.timedOut) }
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"reset_at":1055,"limit_window_seconds":18000}}}"#.utf8), response)
        })
        let sampler = CodexQuotaSampler(client: client, now: clock.now)
        let original = await sampler.sample(previous: nil)
        #expect(await sampler.scheduledResetRefreshDate() == Date(timeIntervalSince1970: 1080))
        clock.advance(by: 80)
        let failed = await sampler.sample(previous: original, force: true)
        #expect(await sampler.scheduledResetRefreshDate() == nil)
        #expect(failed.value == original.value)
        _ = await sampler.sample(previous: failed)
        #expect(counter.value == 2)
        clock.advance(by: 15.1)
        _ = await sampler.sample(previous: failed)
        #expect(counter.value == 3)
    }

    @Test func quotaRemainingIsClampedAndIndependentOfWindowOrder() throws {
        let data = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":110,"limit_window_seconds":604800},"secondary_window":{"used_percent":-5,"limit_window_seconds":18000}}}"#.utf8)
        let report = try CodexUsageClient.parseUsage(data)
        let module = CodexQuotaSampler.module(from: report)
        #expect(module.summary == "Pro")
        #expect(module.metrics.first { $0.name == "five-hour" }?.value == "100%")
        #expect(module.metrics.first { $0.name == "weekly" }?.value == "0%")
        #expect(report.periods.first { $0.id == "week" }?.label == "WEEK")
        #expect(report.fetchedAt != nil)
    }

    @Test func schedulesTheEarlierQuotaResetAtTheNextMinute() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fiveHourReset = Date(timeIntervalSince1970: 1_055)
        let weeklyReset = Date(timeIntervalSince1970: 1_181)

        #expect(
            CodexQuotaRefreshSchedule.nextRefreshDate(
                resetDates: [weeklyReset, fiveHourReset],
                now: now
            ) == Date(timeIntervalSince1970: 1_080)
        )
        #expect(
            CodexQuotaRefreshSchedule.nextRefreshDate(
                resetDates: [Date(timeIntervalSince1970: 999)],
                now: now
            ) == nil
        )
    }

    @Test func failedRefreshRetriesBeforeTheNormalRefreshInterval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"test-token"}}"#.utf8).write(to: authURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = CodexRetryClock()
        let counter = CodexRetryCounter()
        let responseData = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8)
        let client = CodexUsageClient(
            authFileURL: authURL,
            usageURL: try #require(URL(string: "https://example.com/usage")),
            transport: { request in
                let attempt = counter.increment()
                if attempt == 1 {
                    throw URLError(.timedOut)
                }
                return (
                    responseData,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let sampler = CodexQuotaSampler(client: client, now: clock.now)

        let failure = await sampler.sample(previous: nil)
        #expect(counter.value == 1)
        #expect(failure.metrics.first { $0.name == "status" }?.value == "连接超时")

        _ = await sampler.sample(previous: failure)
        #expect(counter.value == 1)

        clock.advance(by: 15.1)
        let recovered = await sampler.sample(previous: failure)
        #expect(counter.value == 2)
        #expect(recovered.summary == "Plus")

        clock.advance(by: 61)
        _ = await sampler.sample(previous: recovered, refreshInterval: 600)
        #expect(counter.value == 2)

        // A changed interval takes effect on the next request, without a setter task.
        _ = await sampler.sample(previous: recovered, refreshInterval: 60)
        #expect(counter.value == 3)

        _ = await sampler.sample(previous: recovered, force: true, refreshInterval: 600)
        #expect(counter.value == 4)
    }

    @Test func quotaDecreaseTemporarilyUsesFastRefreshUntilTwoUnchangedResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"test-token"}}"#.utf8).write(to: authURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = CodexRetryCounter()
        let responses = [
            #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000},"secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}"#,
            #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000},"secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}"#,
            #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000},"secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}"#,
            #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000},"secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}"#
        ].map { Data($0.utf8) }
        let client = CodexUsageClient(
            authFileURL: authURL,
            transport: { request in
                let index = min(counter.increment() - 1, responses.count - 1)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (responses[index], response)
            }
        )
        let sampler = CodexQuotaSampler(client: client)

        _ = await sampler.sample(previous: nil, force: true, refreshInterval: 300, adaptiveRefreshInterval: 60)
        #expect(await sampler.effectiveRefreshInterval(defaultInterval: 300, adaptiveInterval: 60) == 300)

        _ = await sampler.sample(previous: nil, force: true, refreshInterval: 300, adaptiveRefreshInterval: 60)
        #expect(await sampler.effectiveRefreshInterval(defaultInterval: 300, adaptiveInterval: 60) == 60)

        _ = await sampler.sample(previous: nil, force: true, refreshInterval: 300, adaptiveRefreshInterval: 60)
        #expect(await sampler.effectiveRefreshInterval(defaultInterval: 300, adaptiveInterval: 60) == 60)

        _ = await sampler.sample(previous: nil, force: true, refreshInterval: 300, adaptiveRefreshInterval: 60)
        #expect(await sampler.effectiveRefreshInterval(defaultInterval: 300, adaptiveInterval: 60) == 300)
    }
}

private final class CodexRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

private final class CodexRetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
