import Darwin
import Foundation
import XCTest
@testable import CalmMirrorCore

final class ProcessInterruptionTests: XCTestCase {
    func testChildWorkerPausesBeforeMappingCheckpoint() throws {
        guard let root = ProcessInfo.processInfo.environment["CALMIRROR_CRASH_WORKER_DIR"] else { return }
        let calendar = try DurableCalendarAccess(directory: URL(fileURLWithPath: root))
        let paths = URL(fileURLWithPath: root)
        let records = try SyncRecordStore(baseDirectory: paths.appendingPathComponent("records"),
            writeHandler: { _, _ in
                try Data("ready".utf8).write(to: paths.appendingPathComponent("checkpoint-ready"))
                while true { Thread.sleep(forTimeInterval: 1) }
            })
        let logs = try SyncLogStore(logFileURL: paths.appendingPathComponent("logs.json"))
        _ = SyncEngine(calendarAccess: calendar, syncRecordStore: records, syncLogStore: logs)
            .sync(rule: Self.rule)
        XCTFail("Worker should have been terminated before sync returned")
    }

    func testTerminationAfterCommitRecoversByAdoptingCommittedBlocker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try DurableCalendarAccess.seed(directory: directory)

        let bundle = Bundle(for: ProcessInterruptionTests.self).bundleURL.path
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "ProcessInterruptionTests/testChildWorkerPausesBeforeMappingCheckpoint", bundle]
        var environment = ProcessInfo.processInfo.environment
        environment["CALMIRROR_CRASH_WORKER_DIR"] = directory.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let marker = directory.appendingPathComponent("checkpoint-ready")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: marker.path), child.isRunning else {
            XCTFail("Child did not reach the post-commit checkpoint")
            return
        }
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)

        let calendar = try DurableCalendarAccess(directory: directory)
        XCTAssertEqual(calendar.targetEventCount, 1, "Calendar commit must survive child termination")
        let records = try SyncRecordStore(baseDirectory: directory.appendingPathComponent("records"))
        XCTAssertTrue(try records.loadRecordsChecked(for: Self.rule.id).isEmpty,
                      "Child must stop before writing the mapping checkpoint")
        let logs = try SyncLogStore(logFileURL: directory.appendingPathComponent("retry-logs.json"))
        let retry = SyncEngine(calendarAccess: calendar, syncRecordStore: records, syncLogStore: logs)
            .sync(rule: Self.rule)
        XCTAssertTrue(retry.errors.isEmpty)
        XCTAssertEqual(calendar.targetEventCount, 1)
        XCTAssertEqual(try records.loadRecordsChecked(for: Self.rule.id).count, 1)
        XCTAssertEqual(calendar.createCount, 0, "Retry should adopt the committed blocker")
    }

    private static let rule = MirrorRule(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        title: "Interruption", sourceCalendarIdentifier: "source", targetCalendarIdentifier: "target",
        windowDays: 7, blockerLabel: "Busy", usePlaceholder: true, isEnabled: true,
        createdAt: Date(), updatedAt: Date())
}

private final class DurableCalendarAccess: CalendarAccess {
    private struct DiskEvent: Codable {
        var identifier: String; var externalIdentifier: String; var calendarIdentifier: String
        var title: String?; var startDate: Date; var endDate: Date; var isAllDay: Bool
        var notes: String?; var isCanceled: Bool
    }
    private let file: URL
    private var committed: [DiskEvent]
    private var staged: [DiskEvent] = []
    private(set) var createCount = 0
    private let source = CalendarDescriptor(identifier: "source", title: "Source", allowsContentModifications: false)
    private let target = CalendarDescriptor(identifier: "target", title: "Target", allowsContentModifications: true)
    var targetEventCount: Int { committed.filter { $0.calendarIdentifier == "target" }.count }

    init(directory: URL) throws {
        file = directory.appendingPathComponent("calendar.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        committed = try decoder.decode([DiskEvent].self, from: Data(contentsOf: file))
    }
    static func seed(directory: URL) throws {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let event = DiskEvent(identifier: "source-event", externalIdentifier: "source-external",
            calendarIdentifier: "source", title: "Meeting", startDate: start,
            endDate: start.addingTimeInterval(1800), isAllDay: false, notes: nil, isCanceled: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([event]).write(to: directory.appendingPathComponent("calendar.json"))
    }
    func calendarDescriptor(withIdentifier id: String) -> CalendarDescriptor? { id == "source" ? source : (id == "target" ? target : nil) }
    func fetchEvents(in calendar: CalendarDescriptor, from: Date, to: Date, retainHandles: Bool) throws -> [CalendarEventSnapshot] {
        committed.filter { $0.calendarIdentifier == calendar.identifier && $0.startDate < to && $0.endDate >= from }.map(snapshot)
    }
    func resolveBlocker(for record: SyncRecord, in target: CalendarDescriptor) throws -> BlockerResolution {
        let matches = committed.filter { $0.calendarIdentifier == target.identifier && ($0.identifier == record.blockerEventIdentifier || $0.externalIdentifier == record.blockerExternalIdentifier) }
        if let event = matches.first, BlockerNotes.isManaged(event.notes) { return .found(snapshot(event)) }
        return matches.isEmpty ? .missing : .untagged
    }
    func createBlockerEvent(in calendar: CalendarDescriptor, title: String, startDate: Date, endDate: Date, isAllDay: Bool, notes: String, commit: Bool) throws -> CalendarEventSnapshot {
        createCount += 1
        let event = DiskEvent(identifier: UUID().uuidString, externalIdentifier: UUID().uuidString, calendarIdentifier: calendar.identifier, title: title, startDate: startDate, endDate: endDate, isAllDay: isAllDay, notes: notes, isCanceled: false)
        staged.append(event); return snapshot(event)
    }
    private enum UnsupportedOperation: Error { case update, delete }
    func updateBlockerEvent(_ event: CalendarEventSnapshot, title: String, startDate: Date, endDate: Date, isAllDay: Bool, notes: String, commit: Bool) throws { throw UnsupportedOperation.update }
    func deleteEvent(_ event: CalendarEventSnapshot, commit: Bool) throws { throw UnsupportedOperation.delete }
    func commitChanges() throws {
        committed.append(contentsOf: staged); staged.removeAll()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(committed).write(to: file, options: .atomic)
    }
    func discardPendingChanges() { staged.removeAll() }
    func releaseEventHandles() {}
    private func snapshot(_ event: DiskEvent) -> CalendarEventSnapshot {
        CalendarEventSnapshot(handle: event.identifier, identifier: event.identifier, externalIdentifier: event.externalIdentifier, calendarIdentifier: event.calendarIdentifier, title: event.title, startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay, notes: event.notes, isCanceled: event.isCanceled)
    }
}
