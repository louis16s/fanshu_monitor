import Foundation

actor CodexQuotaSampler {
    private let client = CodexUsageClient()
    private var refreshInterval: TimeInterval = 300
    private var cachedModule: MonitorModule?
    private var lastRefreshDate: Date?
    private var inFlightRefresh: (id: UUID, task: Task<MonitorModule, Never>)?

    func sample(previous: MonitorModule?, force: Bool = false) async -> MonitorModule {
        if let inFlightRefresh {
            return moduleWithHistory(await inFlightRefresh.task.value, previous: previous)
        }

        if !force, !shouldRefresh {
            return cachedModule ?? previous ?? Self.placeholderModule
        }

        let refreshID = UUID()
        let cachedModule = cachedModule ?? previous
        let client = client
        let task = Task {
            await Self.loadModule(client: client, cachedModule: cachedModule)
        }
        inFlightRefresh = (refreshID, task)

        let module = await task.value
        if inFlightRefresh?.id == refreshID {
            self.cachedModule = module
            lastRefreshDate = Date()
            inFlightRefresh = nil
        }
        return moduleWithHistory(module, previous: previous)
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = min(3600, max(60, interval))
    }

    func release() {
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        cachedModule = nil
        lastRefreshDate = nil
    }

    private var shouldRefresh: Bool {
        guard let lastRefreshDate else { return true }
        return Date().timeIntervalSince(lastRefreshDate) >= refreshInterval
    }

    private func moduleWithHistory(_ module: MonitorModule, previous: MonitorModule?) -> MonitorModule {
        guard let previous else { return module }
        var updated = module
        updated.samples = Array((previous.samples + [module.value]).suffix(MonitorConstants.sparklineMaxPoints))
        return updated
    }

    private static func loadModule(
        client: CodexUsageClient,
        cachedModule: MonitorModule?
    ) async -> MonitorModule {
        do {
            let report = try await client.load()
            CodexQuotaCache.save(report)
            return Self.module(from: report)
        } catch {
            return MonitorModule(
                kind: .codex,
                value: cachedModule?.value ?? 0,
                summary: "--",
                metrics: [
                    MonitorMetric(name: "plan", value: cachedMetric("plan", in: cachedModule)),
                    MonitorMetric(name: "five-hour", value: cachedMetric("five-hour", in: cachedModule)),
                    MonitorMetric(name: "weekly", value: cachedMetric("weekly", in: cachedModule)),
                    MonitorMetric(name: "five-hour-reset", value: cachedMetric("five-hour-reset", in: cachedModule)),
                    MonitorMetric(name: "weekly-reset", value: cachedMetric("weekly-reset", in: cachedModule)),
                    MonitorMetric(name: "reset-credits", value: cachedMetric("reset-credits", in: cachedModule)),
                    MonitorMetric(name: "status", value: error.localizedDescription)
                ],
                samples: cachedModule?.samples ?? seedSamples(0)
            )
        }
    }

    private static func cachedMetric(_ name: String, in module: MonitorModule?) -> String {
        module?.metrics.first { $0.name == name }?.value ?? "--"
    }

    private static let placeholderModule = MonitorModule(
        kind: .codex,
        value: 0,
        summary: "刷新中",
        metrics: [
            MonitorMetric(name: "plan", value: "--"),
            MonitorMetric(name: "five-hour", value: "--"),
            MonitorMetric(name: "weekly", value: "--"),
            MonitorMetric(name: "five-hour-reset", value: "--"),
            MonitorMetric(name: "weekly-reset", value: "--"),
            MonitorMetric(name: "reset-credits", value: "--")
        ],
        samples: seedSamples(0)
    )

    static func module(from report: CodexQuotaReport) -> MonitorModule {
        let fiveHour = report.periods.first { $0.id == "5h" }
        let weekly = report.periods.first { $0.id == "week" }
        let fiveHourRemainingValue = (fiveHour?.remainingRatio).map { $0 * 100 } ?? 0
        let fiveHourRemaining = percentText(fiveHour?.remainingRatio)
        let weeklyRemaining = percentText(weekly?.remainingRatio)
        let fiveHourResetText = formattedFiveHourReset(fiveHour?.resetAt)
        let weeklyResetText = formattedWeeklyReset(weekly?.resetAt)
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
                MonitorMetric(name: "weekly-reset", value: weeklyResetText),
                MonitorMetric(name: "reset-credits", value: resetCreditsText(report.resetCredits))
            ],
            samples: seedSamples(fiveHourRemainingValue)
        )
    }

    private static func percentText(_ ratio: Double?) -> String {
        guard let ratio else { return "--" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private static func formattedFiveHourReset(_ date: Date?) -> String {
        date.map { quotaTimeFormatter.string(from: $0) } ?? "--"
    }

    private static func formattedWeeklyReset(_ date: Date?) -> String {
        date.map { quotaDateFormatter.string(from: $0) } ?? "--"
    }

    private static func resetCreditsText(_ count: Int?) -> String {
        guard let count else { return "--" }
        return "\(max(0, count)) 张"
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

nonisolated private let quotaTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter
}()

nonisolated private let quotaDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy.M.d"
    return formatter
}()

nonisolated enum CodexUsageError: LocalizedError, Equatable {
    case missingAuthFile(String)
    case missingAccessToken
    case invalidAuthFile
    case invalidResponse(Int)
    case networkTimedOut
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
        case .networkTimedOut:
            return "连接超时"
        case .networkFailed:
            return "网络请求失败"
        case .invalidPayload:
            return "数据无法解析"
        }
    }
}

nonisolated struct CodexUsageClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let requestTimeout: TimeInterval = 12

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let liveTransport: Transport = { request in
        let (data, response) = try await liveSession.data(for: request)
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
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }

        guard response.statusCode == 200 else {
            throw CodexUsageError.invalidResponse(response.statusCode)
        }

        return try Self.parseUsage(data)
    }

    static func mapTransportError(_ error: Error) -> CodexUsageError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .networkTimedOut
        }
        return .networkFailed(error.localizedDescription)
    }

    static func parseUsage(_ data: Data) throws -> CodexQuotaReport {
        do {
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let windows = [
                (response.rateLimit?.primaryWindow, "5h", "5H"),
                (response.rateLimit?.secondaryWindow, "week", "一周")
            ]
            var snapshots: [String: CodexQuotaSnapshot] = [:]
            for (window, fallbackID, fallbackLabel) in windows {
                guard let window else { continue }
                let identity = window.periodIdentity(fallbackID: fallbackID, fallbackLabel: fallbackLabel)
                snapshots[identity.id] = window.snapshot(id: identity.id, label: identity.label)
            }
            let periods = ["5h", "week"].compactMap { snapshots[$0] }

            return CodexQuotaReport(
                planType: response.planType,
                periods: periods,
                resetCredits: response.rateLimitResetCredits?.availableCount
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

nonisolated struct CodexQuotaReport: Codable, Equatable, Sendable {
    var planType: String?
    var periods: [CodexQuotaSnapshot]
    var resetCredits: Int?
}

nonisolated struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
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

nonisolated enum CodexQuotaCache {
    private static let key = "codex.quota.lastSuccessfulReport"

    static func loadModule(defaults: UserDefaults = .standard) -> MonitorModule? {
        guard let data = defaults.data(forKey: key),
              let report = try? JSONDecoder().decode(CodexQuotaReport.self, from: data)
        else {
            return nil
        }
        return CodexQuotaSampler.module(from: report)
    }

    static func save(_ report: CodexQuotaReport, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(report) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

nonisolated private struct CodexAuth: Decodable {
    var tokens: Tokens?

    struct Tokens: Decodable {
        var accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

nonisolated private struct CodexUsageResponse: Decodable {
    var planType: String?
    var rateLimit: RateLimit?
    var rateLimitResetCredits: RateLimitResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    struct RateLimitResetCredits: Decodable {
        var availableCount: Int?

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
        }
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
        var limitWindowSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        func periodIdentity(fallbackID: String, fallbackLabel: String) -> (id: String, label: String) {
            guard let limitWindowSeconds else { return (fallbackID, fallbackLabel) }
            return limitWindowSeconds <= 24 * 60 * 60
                ? ("5h", "5H")
                : ("week", "一周")
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
