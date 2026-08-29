import Foundation
import OSLog

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
        guard totalSteps > 0 else { return String(localized: "codex.task.running") }
        return "\(completedSteps)/\(totalSteps)"
    }
}

actor CodexTaskProgressReader {
    private struct RolloutState {
        var offset: UInt64 = 0
        var remainder = Data()
        var isDroppingLeadingPartialLine = false
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
    private var sessionIndexOffset: UInt64 = 0
    private var sessionIndexRemainder = Data()

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
        updateSessionTitles()

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
            // Keep the last known task during transient filesystem failures. The
            // next discovery pass removes files that are genuinely gone.
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
        if initialRead && readOffset > 0 {
            state.isDroppingLeadingPartialLine = true
        }
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            state.offset = try handle.offset()
            process(data: data, state: &state)
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

    private func process(data: Data, state: inout RolloutState) {
        var appendedData = data
        if state.isDroppingLeadingPartialLine {
            guard let newline = appendedData.firstIndex(of: 0x0A) else { return }
            appendedData = Data(appendedData[appendedData.index(after: newline)...])
            state.isDroppingLeadingPartialLine = false
        }

        var bufferedData = state.remainder
        bufferedData.append(appendedData)
        var lineStart = bufferedData.startIndex

        while let lineEnd = bufferedData[lineStart...].firstIndex(of: 0x0A) {
            let line = bufferedData[lineStart..<lineEnd]
            if !line.isEmpty, let text = String(data: line, encoding: .utf8) {
                process(line: text, state: &state)
            }
            lineStart = bufferedData.index(after: lineEnd)
        }
        state.remainder = Data(bufferedData[lineStart...])
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
              let input = planInput(payload: payload, payloadType: payloadType) else {
            return
        }
        applyPlan(from: input, state: &state)
    }

    private func planInput(payload: [String: Any], payloadType: String) -> String? {
        if payloadType == "function_call",
           payload["name"] as? String == "update_plan" {
            return payload["arguments"] as? String
        }
        if payloadType == "custom_tool_call",
           let input = payload["input"] as? String,
           payload["name"] as? String == "update_plan" || input.contains("update_plan") {
            return input
        }
        return nil
    }

    private func applyPlan(from input: String, state: inout RolloutState) {
        if let data = input.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plan = root["plan"] as? [[String: Any]] {
            let entries = plan.compactMap { item -> (step: String, status: String)? in
                guard let step = item["step"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return (step, status)
            }
            if !entries.isEmpty {
                applyPlanEntries(entries, state: &state)
                return
            }
        }

        let pattern = #"step\s*:\s*\"((?:\\.|[^\"])*)\"\s*,\s*status\s*:\s*\"(pending|in_progress|completed)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: range)
        guard !matches.isEmpty else { return }

        var entries: [(step: String, status: String)] = []
        for match in matches {
            guard let stepRange = Range(match.range(at: 1), in: input),
                  let statusRange = Range(match.range(at: 2), in: input)
            else {
                continue
            }
            let step = String(input[stepRange]).replacingOccurrences(of: #"\""#, with: "\"")
            entries.append((step, String(input[statusRange])))
        }
        applyPlanEntries(entries, state: &state)
    }

    private func applyPlanEntries(
        _ entries: [(step: String, status: String)],
        state: inout RolloutState
    ) {
        state.totalSteps = entries.count
        let completed = entries.lazy.filter { $0.status == "completed" }.count
        state.completedSteps = min(completed, state.totalSteps)
        state.activeStep = entries.first { $0.status == "in_progress" }?.step
    }

    private func updateSessionTitles() {
        let fileSize: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: sessionIndexURL.path)
            guard let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
            fileSize = size
        } catch {
            AppLogger.codex.debug("Session index unavailable: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return
        }

        if fileSize < sessionIndexOffset {
            sessionIndexOffset = 0
            sessionIndexRemainder.removeAll(keepingCapacity: true)
            titleByThreadID.removeAll(keepingCapacity: true)
        }
        guard fileSize > sessionIndexOffset else { return }

        do {
            let handle = try FileHandle(forReadingFrom: sessionIndexURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: sessionIndexOffset)
            let appendedData = try handle.readToEnd() ?? Data()
            sessionIndexOffset = try handle.offset()
            processSessionIndex(data: appendedData)
        } catch {
            AppLogger.codex.error("Unable to update session index: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }

    private func processSessionIndex(data: Data) {
        var bufferedData = sessionIndexRemainder
        bufferedData.append(data)
        let newline = Data([0x0A])
        var lineStart = bufferedData.startIndex

        while let lineEnd = bufferedData[lineStart...].firstRange(of: newline)?.lowerBound {
            parseSessionIndexLine(bufferedData[lineStart..<lineEnd])
            lineStart = bufferedData.index(after: lineEnd)
        }
        sessionIndexRemainder = Data(bufferedData[lineStart...])
    }

    private func parseSessionIndexLine(_ line: Data.SubSequence) {
        guard !line.isEmpty,
              let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let id = record["id"] as? String,
              let title = record["thread_name"] as? String,
              !title.isEmpty
        else {
            return
        }
        titleByThreadID[id] = title
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
