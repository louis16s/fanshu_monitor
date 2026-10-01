import Foundation
import OSLog
import Darwin

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
    // A rollout can survive an interrupted Codex process without receiving a
    // terminal event. Keep the fallback long enough for quiet tool calls, but
    // never let an abandoned task remain visible indefinitely.
    static let staleTaskTimeout: TimeInterval = 120
    private static let readChunkBytes = 256 * 1_024
    private static let maximumRecordBytes = 1_024 * 1_024
    private static let maximumCandidates = 12
    private static let maximumCachedTitles = 256

    private struct JSONLineBuffer {
        var remainder = Data()
        var isDroppingPartialLine = false

        mutating func consume(_ data: Data, processLine: (Data.SubSequence) -> Void) {
            var appendedData = data
            if isDroppingPartialLine {
                guard let newline = appendedData.firstIndex(of: 0x0A) else { return }
                appendedData = Data(appendedData[appendedData.index(after: newline)...])
                isDroppingPartialLine = false
            }

            var bufferedData = remainder
            bufferedData.append(appendedData)
            var lineStart = bufferedData.startIndex
            while let lineEnd = bufferedData[lineStart...].firstIndex(of: 0x0A) {
                let line = bufferedData[lineStart..<lineEnd]
                if !line.isEmpty, line.count <= CodexTaskProgressReader.maximumRecordBytes {
                    autoreleasepool { processLine(line) }
                }
                lineStart = bufferedData.index(after: lineEnd)
            }
            if bufferedData.count - lineStart > CodexTaskProgressReader.maximumRecordBytes {
                // Large image/tool payloads are irrelevant to task status. Resume
                // at the next record instead of retaining an unbounded partial line.
                remainder = Data()
                isDroppingPartialLine = true
            } else {
                remainder = Data(bufferedData[lineStart...])
            }
        }
    }

    private struct RolloutState {
        var offset: UInt64 = 0
        var lines = JSONLineBuffer()
        var currentTurnID: String?
        var isTaskActive = false
        var completedSteps = 0
        var totalSteps = 0
        var activeStep: String?
        var lastActivityAt: Date?

        mutating func resetTask() {
            currentTurnID = nil
            isTaskActive = false
            completedSteps = 0
            totalSteps = 0
            activeStep = nil
            lastActivityAt = nil
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
    private var titleOrderByThreadID: [String: UInt64] = [:]
    private var titleOrder: UInt64 = 0
    private var missingTitleIDs: Set<String> = []
    private var lastDiscovery = Date.distantPast
    private var sessionIndexOffset: UInt64 = 0
    private var sessionIndexLines = JSONLineBuffer()

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
        guard !Task.isCancelled else { return [] }
        if now.timeIntervalSince(lastDiscovery) >= 30 {
            discoverRecentRollouts(now: now)
        }
        guard !Task.isCancelled else {
            lastDiscovery = .distantPast
            return []
        }

        var result: [CodexTaskProgress] = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            var state = statesByURL[candidate.url] ?? RolloutState()
            update(candidate: candidate, state: &state, now: now)
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

    #if DEBUG
    func retainedStateCounts() -> (candidates: Int, titles: Int, bufferedBytes: Int) {
        (
            candidates.count,
            titleByThreadID.count,
            sessionIndexLines.remainder.count + statesByURL.values.reduce(0) { $0 + $1.lines.remainder.count }
        )
    }
    #endif

    private func discoverRecentRollouts(now: Date) {
        lastDiscovery = now

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            let status = sessionsRoot.path.withCString { Darwin.access($0, F_OK) }
            if status == -1, errno == ENOENT {
                candidates.removeAll(keepingCapacity: true)
                statesByURL.removeAll(keepingCapacity: true)
            } else {
                AppLogger.codex.debug("Session directory temporarily unavailable; keeping current task state")
            }
            return
        }

        var discovered: [RolloutCandidate] = []
        discovered.reserveCapacity(Self.maximumCandidates + 1)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard !Task.isCancelled else { return }
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  let threadID = threadID(from: url)
            else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modifiedAt = values?.contentModificationDate else {
                continue
            }
            let candidate = RolloutCandidate(url: url, threadID: threadID, modifiedAt: modifiedAt)
            let insertionIndex = discovered.firstIndex {
                candidate.modifiedAt > $0.modifiedAt
                    || (candidate.modifiedAt == $0.modifiedAt && candidate.url.path < $0.url.path)
            } ?? discovered.endIndex
            if insertionIndex < Self.maximumCandidates {
                discovered.insert(candidate, at: insertionIndex)
                if discovered.count > Self.maximumCandidates {
                    discovered.removeLast()
                }
            }
        }

        candidates = discovered
        let retainedURLs = Set(candidates.map(\.url))
        statesByURL = statesByURL.filter { retainedURLs.contains($0.key) }
        missingTitleIDs.formIntersection(Set(candidates.map(\.threadID)))
        let readWholeIndex = updateSessionTitles()
        recoverMissingTitles(indexWasFullyRead: readWholeIndex)
    }

    private func update(candidate: RolloutCandidate, state: inout RolloutState, now: Date) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            // Keep the last known task during transient filesystem failures. The
            // next discovery pass removes files that are genuinely gone.
            expireIfStale(state: &state, now: now)
            return
        }

        if let modifiedAt = attributes[.modificationDate] as? Date,
           state.isTaskActive,
           now.timeIntervalSince(modifiedAt) >= Self.staleTaskTimeout {
            state.resetTask()
            return
        }

        if fileSize < state.offset {
            state = RolloutState()
        }
        guard fileSize > state.offset else {
            expireIfStale(state: &state, now: now)
            return
        }

        let initialRead = state.offset == 0
        let readOffset = initialRead
            ? initialReadOffset(url: candidate.url, fileSize: fileSize)
            : state.offset
        if initialRead && readOffset > 0 {
            state.lines.isDroppingPartialLine = true
        }
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            _ = try readChunks(handle: handle, fileSize: fileSize) { data, offset in
                var lines = state.lines
                lines.consume(data) { line in
                    process(line: line, state: &state, now: now)
                }
                state.lines = lines
                state.offset = offset
            }
        } catch {
            expireIfStale(state: &state, now: now)
            return
        }

        expireIfStale(state: &state, now: now)
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
                let containsLifecycle = try autoreleasepool {
                    try handle.seek(toOffset: chunkStart)
                    let data = try handle.read(upToCount: Int(chunkEnd - chunkStart)) ?? Data()
                    return Self.lifecycleEventTypes.contains { eventType in
                        data.range(of: Data((#"\"type\":\""# + eventType + #"\""#).utf8)) != nil
                    }
                }
                if containsLifecycle {
                    return chunkStart
                }
            } catch {
                break
            }
            chunkEnd = chunkStart
        }
        return lowerBound
    }

    private func process(line: Data.SubSequence, state: inout RolloutState, now: Date) {
        guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else {
            return
        }

        if state.isTaskActive {
            // Any valid rollout record means the task is still making
            // progress, even when the record is not a plan update.
            state.lastActivityAt = now
        }

        if root["type"] as? String == "event_msg" {
            switch payloadType {
            case "task_started":
                state.resetTask()
                state.isTaskActive = true
                state.currentTurnID = payload["turn_id"] as? String
                state.lastActivityAt = now
            case let type where Self.terminalTaskEventTypes.contains(type):
                let completedTurnID = payload["turn_id"] as? String
                if state.currentTurnID == nil || completedTurnID == state.currentTurnID {
                    state.resetTask()
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
        state.lastActivityAt = now
        applyPlan(from: input, state: &state)
    }

    private func expireIfStale(state: inout RolloutState, now: Date) {
        guard state.isTaskActive,
              let lastActivityAt = state.lastActivityAt,
              now.timeIntervalSince(lastActivityAt) >= Self.staleTaskTimeout else {
            return
        }
        state.resetTask()
    }

    private static let terminalTaskEventTypes: Set<String> = [
        "task_complete",
        "task_failed",
        "task_cancelled",
        "task_canceled",
        "task_aborted",
        "turn_complete",
        "turn_failed",
        "turn_cancelled",
        "turn_canceled",
        "turn_aborted",
        "session_end",
        "session_ended",
        "interrupted"
    ]

    private static let lifecycleEventTypes: Set<String> =
        terminalTaskEventTypes.union(["task_started"])

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

    private func updateSessionTitles() -> Bool {
        let fileSize: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: sessionIndexURL.path)
            guard let size = (attributes[.size] as? NSNumber)?.uint64Value else { return false }
            fileSize = size
        } catch {
            AppLogger.codex.debug("Session index unavailable: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return false
        }

        if fileSize < sessionIndexOffset {
            sessionIndexOffset = 0
            sessionIndexLines = JSONLineBuffer()
            titleByThreadID.removeAll(keepingCapacity: true)
            titleOrderByThreadID.removeAll(keepingCapacity: true)
            missingTitleIDs.removeAll()
        }
        guard fileSize > sessionIndexOffset else { return false }
        let readingFromStart = sessionIndexOffset == 0

        do {
            let handle = try FileHandle(forReadingFrom: sessionIndexURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: sessionIndexOffset)
            let completed = try readChunks(handle: handle, fileSize: fileSize) { data, offset in
                var lines = sessionIndexLines
                lines.consume(data) { parseSessionIndexLine($0) }
                sessionIndexLines = lines
                sessionIndexOffset = offset
                trimTitleCache()
            }
            return readingFromStart && completed
        } catch {
            AppLogger.codex.error("Unable to update session index: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return false
        }
    }

    private func readChunks(
        handle: FileHandle,
        fileSize: UInt64,
        processChunk: (Data, UInt64) -> Void
    ) throws -> Bool {
        var offset = try handle.offset()
        while offset < fileSize {
            guard !Task.isCancelled else { return false }
            let count = Int(min(UInt64(Self.readChunkBytes), fileSize - offset))
            let didRead = try autoreleasepool {
                guard let data = try handle.read(upToCount: count), !data.isEmpty else { return false }
                offset = try handle.offset()
                processChunk(data, offset)
                return true
            }
            guard didRead else { return false }
        }
        return true
    }

    private func recoverMissingTitles(indexWasFullyRead: Bool) {
        let unresolvedIDs = Set(candidates.map(\.threadID)).filter {
            titleByThreadID[$0] == nil && !missingTitleIDs.contains($0)
        }
        guard !unresolvedIDs.isEmpty else { return }
        if indexWasFullyRead {
            missingTitleIDs.formUnion(unresolvedIDs)
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: sessionIndexURL)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            var lines = JSONLineBuffer()
            let completed = try readChunks(handle: handle, fileSize: fileSize) { data, _ in
                lines.consume(data) { parseSessionIndexLine($0, matching: unresolvedIDs) }
            }
            if completed {
                missingTitleIDs.formUnion(unresolvedIDs.filter { titleByThreadID[$0] == nil })
            }
            trimTitleCache()
        } catch {
            AppLogger.codex.debug("Session title lookup temporarily unavailable")
        }
    }

    private func parseSessionIndexLine(_ line: Data.SubSequence, matching ids: Set<String>? = nil) {
        guard !line.isEmpty,
              let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let id = record["id"] as? String,
              ids?.contains(id) ?? true,
              let title = record["thread_name"] as? String,
              !title.isEmpty
        else {
            return
        }
        titleByThreadID[id] = compactTitle(title)
        titleOrder &+= 1
        titleOrderByThreadID[id] = titleOrder
        missingTitleIDs.remove(id)
    }

    private func trimTitleCache() {
        guard titleByThreadID.count > Self.maximumCachedTitles else { return }
        let pinnedIDs = Set(candidates.map(\.threadID)).filter { titleByThreadID[$0] != nil }
        let recentIDs = titleOrderByThreadID
            .filter { !pinnedIDs.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(Self.maximumCachedTitles - pinnedIDs.count)
            .map(\.key)
        let retainedIDs = pinnedIDs.union(recentIDs)
        titleByThreadID = titleByThreadID.filter { retainedIDs.contains($0.key) }
        titleOrderByThreadID = titleOrderByThreadID.filter { retainedIDs.contains($0.key) }
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
