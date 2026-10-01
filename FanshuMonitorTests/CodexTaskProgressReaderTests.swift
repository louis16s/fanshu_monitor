import Foundation
import Testing
@testable import FanshuMonitor

struct CodexTaskProgressReaderTests {
    @Test func emptySessionDiscoveryIsCachedForThirtySeconds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 0)).isEmpty)

        let threadID = "61234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"新任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        let event = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#
        try Data((event + "\n").utf8).write(to: rollout)

        #expect(await reader.load(now: Date(timeIntervalSince1970: 29)).isEmpty)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 30)).count == 1)
    }

    @Test func sessionIndexUpdatesIncrementallyAndWaitsForCompleteLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = "01234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"初始任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        let events = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","input":"update_plan step:\"检查\", status:\"in_progress\""}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(events.utf8).write(to: rollout)

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let initial = await reader.load(now: Date(timeIntervalSince1970: 0))
        #expect(initial.first?.title == "初始任务")

        let partialUpdate = "{\"id\":\"\(threadID)\",\"thread_name\":\"不会提前出现\"}"
        try append(Data(partialUpdate.dropLast(2).utf8), to: index)
        let partial = await reader.load(now: Date(timeIntervalSince1970: 31))
        #expect(partial.first?.title == "初始任务")

        try append(Data((String(partialUpdate.suffix(2)) + "\n").utf8), to: index)
        let completed = await reader.load(now: Date(timeIntervalSince1970: 62))
        #expect(completed.first?.title == "不会提前出现")
    }

    @Test func rolloutUpdatesWaitForCompleteLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = "11234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"增量任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8)
            .write(to: rollout)
        try append(Data([0x0A]), to: rollout)

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 0)).count == 1)

        let completion = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn"}}"#
        let splitIndex = completion.index(completion.startIndex, offsetBy: completion.count / 2)
        try append(Data(completion[..<splitIndex].utf8), to: rollout)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 1)).count == 1)

        try append(Data((String(completion[splitIndex...]) + "\n").utf8), to: rollout)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 2)).isEmpty)
    }

    @Test func interruptedTerminalEventClearsTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = "41234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"中断任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8)
            .write(to: rollout)
        try append(Data([0x0A]), to: rollout)

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let startedAt = Date()
        #expect(await reader.load(now: startedAt).count == 1)

        let interruption = #"{"type":"event_msg","payload":{"type":"task_aborted","turn_id":"turn"}}"#
        try append(Data((interruption + "\n").utf8), to: rollout)
        #expect(await reader.load(now: Date().addingTimeInterval(1)).isEmpty)
    }

    @Test func inactiveRolloutExpiresAfterBoundedIdlePeriod() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = "51234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"无终态任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8)
            .write(to: rollout)
        try append(Data([0x0A]), to: rollout)

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let startedAt = Date()
        #expect(await reader.load(now: startedAt).count == 1)

        let staleAt = startedAt.addingTimeInterval(CodexTaskProgressReader.staleTaskTimeout + 1)
        #expect(await reader.load(now: staleAt).isEmpty)
    }

    @Test func missingRolloutKeepsLastStateUntilTheNextDiscoveryPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = "31234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"稳定任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8)
            .write(to: rollout)
        try append(Data([0x0A]), to: rollout)

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 0)).count == 1)

        try FileManager.default.removeItem(at: rollout)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 1)).count == 1)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 31)).isEmpty)
    }

    @Test func planParsingUsesJSONWithoutDependingOnKeyOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = "21234567-89ab-cdef-0123-456789abcdef"
        try Data("{\"id\":\"\(threadID)\",\"thread_name\":\"计划任务\"}\n".utf8).write(to: index)
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        let planInput = #"{"plan":[{"status":"completed","step":"已完成"},{"status":"in_progress","step":"正在处理"}]}"#
        let response: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": "update_plan",
                "arguments": planInput
            ]
        ]
        let responseLine = try JSONSerialization.data(withJSONObject: response)
        var events = Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8)
        events.append(0x0A)
        events.append(responseLine)
        events.append(0x0A)
        try events.write(to: rollout)

        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let progress = try #require(await reader.load(now: Date(timeIntervalSince1970: 0)).first)
        #expect(progress.completedSteps == 1)
        #expect(progress.totalSteps == 2)
        #expect(progress.activeStep == "正在处理")
    }

    @Test func planRecordAcrossReadChunksPreservesUTF8AndProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = UUID().uuidString.lowercased()
        let rollout = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        let response: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "function_call", "name": "update_plan",
                "padding": String(repeating: "跨块", count: 60_000),
                "arguments": #"{"plan":[{"step":"已完成","status":"completed"},{"step":"继续处理","status":"in_progress"}]}"#
            ]
        ]
        var data = Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n").utf8)
        data.append(try JSONSerialization.data(withJSONObject: response))
        data.append(0x0A)
        try data.write(to: rollout)
        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let task = try #require(await reader.load().first)
        #expect(task.totalSteps == 2)
        #expect(task.completedSteps == 1)
        #expect(task.activeStep == "继续处理")
    }

    @Test func oversizedPartialRecordDoesNotHideFollowingTerminalEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = sessions.appendingPathComponent("rollout-\(UUID().uuidString.lowercased()).jsonl")
        try Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n").utf8).write(to: rollout)
        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let now = Date()
        #expect(await reader.load(now: now).count == 1)
        try append(Data(repeating: 0x78, count: 2 * 1_024 * 1_024), to: rollout)
        #expect(await reader.load(now: now.addingTimeInterval(1)).count == 1)
        let retained = await reader.retainedStateCounts()
        #expect(retained.bufferedBytes <= 1_024 * 1_024)
        try append(Data(("\n" + #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn"}}"# + "\n").utf8), to: rollout)
        #expect(await reader.load(now: now.addingTimeInterval(2)).isEmpty)
    }

    @Test func boundedTitlesKeepCurrentNamesAndRecoverAnOlderReturningSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var indexData = Data()
        var rollouts: [URL] = []
        var threadIDs: [String] = []
        for position in 0..<13 {
            let id = UUID().uuidString.lowercased()
            let url = sessions.appendingPathComponent("rollout-\(id).jsonl")
            try Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(position))], ofItemAtPath: url.path)
            indexData.append(Data("{\"id\":\"\(id)\",\"thread_name\":\"任务\(position)\"}\n".utf8))
            rollouts.append(url)
            threadIDs.append(id)
        }
        for _ in 0..<1_000 {
            indexData.append(Data("{\"id\":\"\(UUID().uuidString)\",\"thread_name\":\"历史会话\"}\n".utf8))
        }
        try indexData.write(to: index)
        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let initial = await reader.load(now: now)
        #expect(initial.count == 12)
        #expect(initial.allSatisfy { $0.title.hasPrefix("任务") })
        #expect(!initial.contains { $0.id == threadIDs[0] })
        #expect(await reader.retainedStateCounts().titles <= 256)

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(31)], ofItemAtPath: rollouts[0].path)
        let returning = await reader.load(now: now.addingTimeInterval(31))
        #expect(returning.first { $0.id == threadIDs[0] }?.title == "任务0")
        #expect(await reader.retainedStateCounts().titles <= 256)

        try append(Data("{\"id\":\"\(threadIDs[0])\",\"thread_name\":\"已改名的旧任务\"}\n".utf8), to: index)
        let renamed = await reader.load(now: now.addingTimeInterval(62))
        #expect(renamed.first { $0.id == threadIDs[0] }?.title == "已改名的旧任务")
    }

    @Test func oversizedIndexRecordDoesNotBlockLaterTitlesOrIndexReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let rollout = sessions.appendingPathComponent("rollout-\(id).jsonl")
        try Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n").utf8).write(to: rollout)
        var indexData = Data(repeating: 0x78, count: 2 * 1_024 * 1_024)
        indexData.append(Data("\n{\"id\":\"\(id)\",\"thread_name\":\"有效标题\"}\n".utf8))
        try indexData.write(to: index)
        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let now = Date()
        #expect(await reader.load(now: now).first?.title == "有效标题")
        try Data("{\"id\":\"\(id)\",\"thread_name\":\"重建索引后的标题\"}\n".utf8).write(to: index)
        #expect(await reader.load(now: now.addingTimeInterval(31)).first?.title == "重建索引后的标题")
    }

    @Test func cancelledLoadDoesNotDelayTheNextDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let index = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = sessions.appendingPathComponent("rollout-\(UUID().uuidString.lowercased()).jsonl")
        try Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n").utf8).write(to: rollout)
        let reader = CodexTaskProgressReader(sessionsRoot: sessions, sessionIndexURL: index)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await reader.load(now: Date(timeIntervalSince1970: 0))
        }
        #expect(await cancelled.value.isEmpty)
        #expect(await reader.load(now: Date(timeIntervalSince1970: 1)).count == 1)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
