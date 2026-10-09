import Foundation
import Testing
@testable import Raven

private let recordJSON = """
{"id":"r1","timestamp":"2026-10-01T14:33:08Z","account":"a","model":"m","status":200}
"""

struct ContextDecodeTests {
    @Test func modelEntryPrefersMaxContextLength() throws {
        let entry = try PanelJSON.decoder.decode(
            ModelEntry.self,
            from: Data(#"{"id":"m","max_context_length":1000000,"context_window":200000,"context_length":300000}"#.utf8))
        #expect(entry.contextWindow == 1_000_000)
    }

    @Test func modelEntryFallsBackToContextWindow() throws {
        let entry = try PanelJSON.decoder.decode(
            ModelEntry.self,
            from: Data(#"{"id":"m","context_window":1048576,"context_length":300000}"#.utf8))
        #expect(entry.contextWindow == 1_048_576)
    }

    @Test func modelEntryFallsBackToContextLength() throws {
        let entry = try PanelJSON.decoder.decode(
            ModelEntry.self,
            from: Data(#"{"id":"m","context_length":1000000}"#.utf8))
        #expect(entry.contextWindow == 1_000_000)
    }

    @Test func modelEntryWithoutAnyWindowStaysNil() throws {
        let entry = try PanelJSON.decoder.decode(ModelEntry.self, from: Data(#"{"id":"m"}"#.utf8))
        #expect(entry.contextWindow == nil)
    }

    @Test func modelEntryRoundTripWritesMaxContextLength() throws {
        let entry = try PanelJSON.decoder.decode(ModelEntry.self, from: Data(#"{"id":"m","max_context_length":1000000}"#.utf8))
        let data = try PanelJSON.encoder.encode(entry)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("max_context_length"))
        let decoded = try PanelJSON.decoder.decode(ModelEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test func modelsResponseAcceptsContextWindowAlias() throws {
        let response = try PanelJSON.decoder.decode(
            ModelsResponse.self,
            from: Data(#"{"data":[{"id":"proxy","context_window":1000000}]}"#.utf8))
        #expect(response.entries.first?.contextWindow == 1_000_000)
    }

    @Test func contextLabelHandlesNonRoundMillions() {
        #expect(ContextWindow.label(1_050_000) == "1.05M ctx")
        #expect(ContextWindow.label(200_000) == "200K ctx")
        #expect(ContextWindow.label(1_000_000) == "1M ctx")
        #expect(ContextWindow.label(1500) == "2K ctx")
    }
}

struct PanelCacheTests {
    private func scratchDirectory(_ name: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "raven-cache-tests")
            .appending(path: name)
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func missingCacheReadsAsEmptyNotStale() {
        let url = scratchDirectory("missing").appending(path: "panel-usage-cache.json")
        #expect(PanelCache.loadUsage(url) == [])
    }

    @Test func corruptCacheDecodesToNil() throws {
        let url = scratchDirectory("corrupt").appending(path: "panel-usage-cache.json")
        try Data("not json at all".utf8).write(to: url)
        #expect(PanelCache.loadUsage(url) == nil)
    }

    @Test func validCacheStillLoads() throws {
        let url = scratchDirectory("valid").appending(path: "panel-usage-cache.json")
        let record = try PanelJSON.decoder.decode(UsageRecord.self, from: Data(recordJSON.utf8))
        PanelCache.saveUsage([record], to: url)
        #expect(PanelCache.loadUsage(url)?.count == 1)
    }

    @Test func quarantineMovesFileAsideWithStamp() throws {
        let dir = scratchDirectory("quarantine")
        let url = dir.appending(path: "panel-usage-cache.json")
        try Data("broken".utf8).write(to: url)
        PanelCache.quarantine(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.hasPrefix("panel-usage-cache.corrupt-") && $0.hasSuffix(".json") })
    }
}

@MainActor
struct UsageStreamGateTests {
    @Test func nonRecordEventsAreNotDecoded() {
        let stream = UsageStream()
        var pending = "message"
        pending = stream.handle(line: "event: status", pendingEvent: pending)
        _ = stream.handle(line: "data: definitely-not-a-record", pendingEvent: pending)
        _ = stream.handle(line: "", pendingEvent: pending)
        #expect(stream.droppedRecords == 0)
    }

    @Test func recordEventDecodesAndDelivers() {
        let stream = UsageStream()
        var delivered: UsageRecord?
        stream.onRecord = { delivered = $0 }
        var pending = stream.handle(line: "event: record", pendingEvent: "message")
        pending = stream.handle(line: "data: " + recordJSON, pendingEvent: pending)
        pending = stream.handle(line: "", pendingEvent: pending)
        #expect(delivered?.model == "m")
        #expect(pending == "record")
        #expect(stream.droppedRecords == 0)
    }

    @Test func malformedRecordCountsAsDrop() {
        let stream = UsageStream()
        let pending = stream.handle(line: "event: record", pendingEvent: "message")
        _ = stream.handle(line: "data: {oops", pendingEvent: pending)
        _ = stream.handle(line: "", pendingEvent: pending)
        #expect(stream.droppedRecords == 1)
    }

    @Test func resetDropsClearsCounter() {
        let stream = UsageStream()
        let pending = stream.handle(line: "event: record", pendingEvent: "message")
        _ = stream.handle(line: "data: {oops", pendingEvent: pending)
        #expect(stream.droppedRecords == 1)
        stream.resetDrops()
        #expect(stream.droppedRecords == 0)
    }

    @Test func readyEventRequestsSnapshot() {
        let stream = UsageStream()
        var snapshotRequests = 0
        stream.onSnapshot = { snapshotRequests += 1 }
        _ = stream.handle(line: "event: ready", pendingEvent: "message")
        #expect(snapshotRequests == 1)
    }

    @Test func commentLinesLeavePendingEventUntouched() {
        let stream = UsageStream()
        let pending = stream.handle(line: ": keep-alive", pendingEvent: "record")
        #expect(pending == "record")
    }
}

struct WorkbuddyKeyingTests {
    private var accounts: [WorkbuddyAccountStatus] {
        [
            WorkbuddyAccountStatus(uid: "u1", nickname: "alpha", credits: 10, cooling: false,
                                   coolRemainingSec: nil, reason: nil),
            WorkbuddyAccountStatus(uid: "wb-nick-only", nickname: "beta", credits: 20, cooling: false,
                                   coolRemainingSec: nil, reason: nil),
        ]
    }

    @Test func uidWinsFirst() {
        let account = AccountView(name: "whatever", provider: "workbuddy", workbuddyUid: "u1",
                                  workbuddyNickname: "beta", antigravityEmail: nil, disabled: nil)
        #expect(WorkbuddyKeying.status(in: accounts, for: account)?.uid == "u1")
    }

    @Test func nicknameFillsMissingUid() {
        let account = AccountView(name: "alpha", provider: "workbuddy", workbuddyUid: nil,
                                  workbuddyNickname: "beta", antigravityEmail: nil, disabled: nil)
        #expect(WorkbuddyKeying.status(in: accounts, for: account)?.uid == "wb-nick-only")
    }

    @Test func nameFallsBackToUid() {
        let account = AccountView(name: "u1", provider: "workbuddy", workbuddyUid: nil,
                                  workbuddyNickname: nil, antigravityEmail: nil, disabled: nil)
        #expect(WorkbuddyKeying.status(in: accounts, for: account)?.nickname == "alpha")
    }

    @Test func unmatchedAccountReturnsNil() {
        let account = AccountView(name: "ghost", provider: "workbuddy", workbuddyUid: "u9",
                                  workbuddyNickname: "omega", antigravityEmail: nil, disabled: nil)
        #expect(WorkbuddyKeying.status(in: accounts, for: account) == nil)
    }
}
