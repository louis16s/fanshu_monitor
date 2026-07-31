import Foundation

nonisolated struct CodexTaskProgress: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let completedSteps: Int
    let totalSteps: Int
    let activeStep: String?

    var percent: Double? {
        guard totalSteps > 0 else { return nil }
        return Double(completedSteps) / Double(totalSteps) * 100
    }

    var countText: String {
        guard totalSteps > 0 else { return "执行中" }
        return "\(completedSteps)/\(totalSteps)"
    }
}

actor CodexTaskProgressReader {
    private struct RolloutState {
        var offset: UInt64 = 0
        var currentTurnID: String?
        var isTaskActive = false
        var completedSteps = 0
        var totalSteps = 0
        var activeStep: String?

        mutating func resetTask() {
            currentTurnID = nil
            isTaskActive = false
            completedSteps = 0
            totalSteps = 0
            activeStep = nil
        }
    }

    private struct RolloutCandidate {
        let url: URL
        let threadID: String
        let modifiedAt: Date
    }

    private let sessionsRoot: URL
    private let sessionIndexURL: URL
    private var candidates: [RolloutCandidate] = []
    private var statesByURL: [URL: RolloutState] = [:]
    private var titleByThreadID: [String: String] = [:]
    private var lastDiscovery = Date.distantPast

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        sessionIndexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    ) {
        self.sessionsRoot = sessionsRoot
        self.sessionIndexURL = sessionIndexURL
    }

    func load(now: Date = Date()) -> [CodexTaskProgress] {
        if candidates.isEmpty || now.timeIntervalSince(lastDiscovery) >= 30 {
            discoverRecentRollouts(now: now)
        }

        var result: [CodexTaskProgress] = []
        for candidate in candidates {
            var state = statesByURL[candidate.url] ?? RolloutState()
            update(candidate: candidate, state: &state)
            statesByURL[candidate.url] = state
            guard state.isTaskActive else { continue }

            result.append(
                CodexTaskProgress(
                    id: candidate.threadID,
                    title: compactTitle(titleByThreadID[candidate.threadID] ?? "Codex 任务"),
                    completedSteps: state.completedSteps,
                    totalSteps: state.totalSteps,
                    activeStep: state.activeStep
                )
            )
        }
        return result
    }

    private func discoverRecentRollouts(now: Date) {
        lastDiscovery = now
        titleByThreadID = loadSessionTitles()

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            candidates = []
            statesByURL = [:]
            return
        }

        var discovered: [RolloutCandidate] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  let threadID = threadID(from: url)
            else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modifiedAt = values?.contentModificationDate else {
                continue
            }
            discovered.append(RolloutCandidate(url: url, threadID: threadID, modifiedAt: modifiedAt))
        }

        candidates = Array(discovered.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(12))
        let retainedURLs = Set(candidates.map(\.url))
        statesByURL = statesByURL.filter { retainedURLs.contains($0.key) }
    }

    private func update(candidate: RolloutCandidate, state: inout RolloutState) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            state = RolloutState()
            return
        }

        if fileSize < state.offset {
            state = RolloutState()
        }
        guard fileSize > state.offset else { return }

        let initialRead = state.offset == 0
        let readOffset = initialRead
            ? initialReadOffset(url: candidate.url, fileSize: fileSize)
            : state.offset
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            state.offset = fileSize
            process(
                data: data,
                dropsLeadingPartialLine: readOffset > 0 && initialRead,
                state: &state
            )
        } catch {
            return
        }
    }

    private func initialReadOffset(url: URL, fileSize: UInt64) -> UInt64 {
        let chunkSize: UInt64 = 1_024 * 1_024
        let maximumSearchBytes: UInt64 = 16 * chunkSize
        let lowerBound = fileSize > maximumSearchBytes ? fileSize - maximumSearchBytes : 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return max(lowerBound, fileSize > 2 * chunkSize ? fileSize - 2 * chunkSize : 0)
        }
        defer { try? handle.close() }

        var chunkEnd = fileSize
        while chunkEnd > lowerBound {
            let chunkStart = max(lowerBound, chunkEnd > chunkSize ? chunkEnd - chunkSize : 0)
            do {
                try handle.seek(toOffset: chunkStart)
                let data = try handle.read(upToCount: Int(chunkEnd - chunkStart)) ?? Data()
                if data.range(of: Data(#"\"type\":\"task_started\""#.utf8)) != nil
                    || data.range(of: Data(#"\"type\":\"task_complete\""#.utf8)) != nil {
                    return chunkStart
                }
            } catch {
                break
            }
            chunkEnd = chunkStart
        }
        return lowerBound
    }

    private func process(data: Data, dropsLeadingPartialLine: Bool, state: inout RolloutState) {
        guard var text = String(data: data, encoding: .utf8) else { return }
        if dropsLeadingPartialLine, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            process(line: String(line), state: &state)
        }
    }

    private func process(line: String, state: inout RolloutState) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else {
            return
        }

        if root["type"] as? String == "event_msg" {
            switch payloadType {
            case "task_started":
                state.resetTask()
                state.isTaskActive = true
                state.currentTurnID = payload["turn_id"] as? String
            case "task_complete":
                let completedTurnID = payload["turn_id"] as? String
                if state.currentTurnID == nil || completedTurnID == state.currentTurnID {
                    state.isTaskActive = false
                }
            default:
                break
            }
            return
        }

        guard state.isTaskActive,
              root["type"] as? String == "response_item",
              payloadType == "custom_tool_call",
              let input = payload["input"] as? String,
              input.contains("update_plan")
        else {
            return
        }
        applyPlan(from: input, state: &state)
    }

    private func applyPlan(from input: String, state: inout RolloutState) {
        let pattern = #"step\s*:\s*\"((?:\\.|[^\"])*)\"\s*,\s*status\s*:\s*\"(pending|in_progress|completed)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: range)
        guard !matches.isEmpty else { return }

        var completed = 0
        var active: String?
        for match in matches {
            guard let stepRange = Range(match.range(at: 1), in: input),
                  let statusRange = Range(match.range(at: 2), in: input)
            else {
                continue
            }
            let step = String(input[stepRange]).replacingOccurrences(of: #"\""#, with: "\"")
            switch input[statusRange] {
            case "completed": completed += 1
            case "in_progress": active = step
            default: break
            }
        }
        state.totalSteps = matches.count
        state.completedSteps = min(completed, state.totalSteps)
        state.activeStep = active
    }

    private func loadSessionTitles() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionIndexURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return titleByThreadID
        }

        var titles: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = record["id"] as? String,
                  let title = record["thread_name"] as? String,
                  !title.isEmpty
            else {
                continue
            }
            titles[id] = title
        }
        return titles
    }

    private func threadID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let pattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem)
        else {
            return nil
        }
        return String(stem[range])
    }

    private func compactTitle(_ title: String) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 24 else { return value }
        return String(value.prefix(23)) + "…"
    }
}
