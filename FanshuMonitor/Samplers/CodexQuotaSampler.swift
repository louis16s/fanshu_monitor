import Foundation

final class CodexQuotaSampler: MonitorSampler {
    var kind: MonitorKind { .codex }

    private let client = CodexUsageClient()
    private var refreshInterval: TimeInterval = 300
    private var cachedModule: MonitorModule?
    private var lastRefreshDate: Date?
    private var isRefreshing = false

    func sample(previous: MonitorModule?) -> MonitorModule {
        if shouldRefresh {
            startRefresh()
        }

        if let cachedModule {
            return cachedModule
        }

        if let previous, previous.kind == .codex {
            return previous
        }

        return MonitorModule(
            kind: .codex,
            value: 0,
            summary: "刷新中",
            metrics: [
                MonitorMetric(name: "plan", value: "--"),
                MonitorMetric(name: "five-hour", value: "--"),
                MonitorMetric(name: "weekly", value: "--"),
                MonitorMetric(name: "five-hour-reset", value: "--"),
                MonitorMetric(name: "weekly-reset", value: "--")
            ],
            samples: seedSamples(0)
        )
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = min(3600, max(60, interval))
    }

    func forceRefresh(previous: MonitorModule?, completion: @escaping (MonitorModule) -> Void) {
        startRefresh(previous: previous, completion: completion)
    }

    private var shouldRefresh: Bool {
        guard !isRefreshing else { return false }
        guard let lastRefreshDate else { return true }
        return Date().timeIntervalSince(lastRefreshDate) >= refreshInterval
    }

    private func startRefresh() {
        startRefresh(previous: nil, completion: nil)
    }

    private func startRefresh(previous: MonitorModule?, completion: ((MonitorModule) -> Void)?) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let module = await self.loadModule()
            self.cachedModule = module
            self.lastRefreshDate = Date()
            self.isRefreshing = false
            let completedModule: MonitorModule
            if let previous {
                var updated = module
                updated.samples = Array((previous.samples + [module.value]).suffix(MonitorConstants.sparklineMaxPoints))
                completedModule = updated
            } else {
                completedModule = module
            }
            await MainActor.run {
                completion?(completedModule)
            }
        }
    }

    private func loadModule() async -> MonitorModule {
        do {
            let report = try await client.load()
            return Self.module(from: report)
        } catch {
            return MonitorModule(
                kind: .codex,
                value: cachedModule?.value ?? 0,
                summary: "--",
                metrics: [
                    MonitorMetric(name: "plan", value: cachedMetric("plan")),
                    MonitorMetric(name: "five-hour", value: cachedMetric("five-hour")),
                    MonitorMetric(name: "weekly", value: cachedMetric("weekly")),
                    MonitorMetric(name: "five-hour-reset", value: cachedMetric("five-hour-reset")),
                    MonitorMetric(name: "weekly-reset", value: cachedMetric("weekly-reset")),
                    MonitorMetric(name: "status", value: error.localizedDescription)
                ],
                samples: cachedModule?.samples ?? seedSamples(0)
            )
        }
    }

    private func cachedMetric(_ name: String) -> String {
        cachedModule?.metrics.first { $0.name == name }?.value ?? "--"
    }

    static func module(from report: CodexQuotaReport) -> MonitorModule {
        let fiveHour = report.periods.first { $0.id == "5h" }
        let weekly = report.periods.first { $0.id == "week" }
        let fiveHourRemainingValue = (fiveHour?.remainingRatio).map { $0 * 100 } ?? 0
        let fiveHourRemaining = percentText(fiveHour?.remainingRatio)
        let weeklyRemaining = percentText(weekly?.remainingRatio)
        let fiveHourResetText = resetText(fiveHour?.resetAt)
        let weeklyResetText = resetText(weekly?.resetAt)
        let planName = normalizedPlanName(report.planType)

        return MonitorModule(
            kind: .codex,
            value: fiveHourRemainingValue,
            summary: planName,
            metrics: [
                MonitorMetric(name: "plan", value: planName),
                MonitorMetric(name: "five-hour", value: fiveHourRemaining),
                MonitorMetric(name: "weekly", value: weeklyRemaining),
                MonitorMetric(name: "five-hour-reset", value: fiveHourResetText),
                MonitorMetric(name: "weekly-reset", value: weeklyResetText)
            ],
            samples: seedSamples(fiveHourRemainingValue)
        )
    }

    private static func usedPercent(from snapshot: CodexQuotaSnapshot?) -> Double? {
        guard let remainingRatio = snapshot?.remainingRatio else { return nil }
        return 100 - remainingRatio * 100
    }

    private static func percentText(_ ratio: Double?) -> String {
        guard let ratio else { return "--" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private static func resetText(_ date: Date?) -> String {
        date.map { quotaDateFormatter.string(from: $0) } ?? "--"
    }

    private static func normalizedPlanName(_ planType: String?) -> String {
        guard let planType else { return "Free" }
        switch planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free":
            return "Free"
        case "plus", "pro":
            return "Plus"
        case "team", "teams", "business":
            return "Team"
        default:
            return planType.prefix(1).uppercased() + planType.dropFirst().lowercased()
        }
    }
}

private let quotaDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter
}()

enum CodexUsageError: LocalizedError, Equatable {
    case missingAuthFile(String)
    case missingAccessToken
    case invalidAuthFile
    case invalidResponse(Int)
    case networkFailed(String)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "未登录 Codex"
        case .missingAccessToken:
            return "缺少访问令牌"
        case .invalidAuthFile:
            return "登录文件无效"
        case .invalidResponse(let status):
            return "接口返回 \(status)"
        case .networkFailed:
            return "网络请求失败"
        case .invalidPayload:
            return "数据无法解析"
        }
    }
}

struct CodexUsageClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let liveTransport: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20

        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexUsageError.invalidResponse(-1)
        }
        return (data, httpResponse)
    }

    var authFileURL: URL
    var usageURL: URL
    private let transport: Transport

    init(
        authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"),
        usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        transport: @escaping Transport = CodexUsageClient.liveTransport
    ) {
        self.authFileURL = authFileURL
        self.usageURL = usageURL
        self.transport = transport
    }

    func load() async throws -> CodexQuotaReport {
        let accessToken = try loadAccessToken()
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("番薯Monitor/0.2.4", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.networkFailed(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            throw CodexUsageError.invalidResponse(response.statusCode)
        }

        return try Self.parseUsage(data)
    }

    static func parseUsage(_ data: Data) throws -> CodexQuotaReport {
        do {
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            var periods: [CodexQuotaSnapshot] = []

            if let primary = response.rateLimit?.primaryWindow {
                periods.append(primary.snapshot(id: "5h", label: "5H"))
            }

            if let secondary = response.rateLimit?.secondaryWindow {
                periods.append(secondary.snapshot(id: "week", label: "一周"))
            }

            return CodexQuotaReport(
                planType: response.planType,
                periods: periods
            )
        } catch {
            throw CodexUsageError.invalidPayload
        }
    }

    private func loadAccessToken() throws -> String {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw CodexUsageError.missingAuthFile(authFileURL.path)
        }

        do {
            let data = try Data(contentsOf: authFileURL)
            let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
            guard let token = auth.tokens?.accessToken, !token.isEmpty else {
                throw CodexUsageError.missingAccessToken
            }
            return token
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.invalidAuthFile
        }
    }
}

struct CodexQuotaReport: Equatable, Sendable {
    var planType: String?
    var periods: [CodexQuotaSnapshot]
}

struct CodexQuotaSnapshot: Equatable, Sendable {
    var id: String
    var label: String
    var remaining: Double
    var limit: Double
    var usedPercent: Double
    var resetAt: Date?

    var remainingRatio: Double? {
        guard limit > 0 else { return nil }
        return max(0, min(1, remaining / limit))
    }
}

private struct CodexAuth: Decodable {
    var tokens: Tokens?

    struct Tokens: Decodable {
        var accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

private struct CodexUsageResponse: Decodable {
    var planType: String?
    var rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        var primaryWindow: Window?
        var secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        var usedPercent: Double
        var resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
        }

        func snapshot(id: String, label: String) -> CodexQuotaSnapshot {
            let used = max(0, min(100, usedPercent))
            return CodexQuotaSnapshot(
                id: id,
                label: label,
                remaining: 100 - used,
                limit: 100,
                usedPercent: used,
                resetAt: resetAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }
}
