import Foundation
import Testing
@testable import FanshuMonitor

struct CodexQuotaSamplerRetryTests {
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
