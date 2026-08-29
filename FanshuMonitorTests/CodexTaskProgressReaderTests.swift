import Foundation
import Testing
@testable import FanshuMonitor

struct CodexTaskProgressReaderTests {
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

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
