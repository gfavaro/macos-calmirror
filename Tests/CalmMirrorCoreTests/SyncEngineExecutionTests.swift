import XCTest
@testable import CalmMirrorCore

/// In-memory adapter with separately observable committed and staged state.
private final class FakeCalendarAccess: CalendarAccess {
    enum Failure: Error { case injected }
    enum Operation: Equatable { case create, update, delete, commit, discard }

    private(set) var calendars: [String: CalendarDescriptor] = [:]
    private(set) var committed: [String: CalendarEventSnapshot] = [:]
    private var staged: [String: CalendarEventSnapshot?] = [:]
    private(set) var operations: [Operation] = []
    var failOperationAt: Int?
    var failCommitAt: Int?
    var unavailableOnFetch: String?
    var unavailableOnResolve: String?
    private var operationNumber = 0
    private var commitNumber = 0

    func addCalendar(_ id: String, writable: Bool = true) {
        calendars[id] = CalendarDescriptor(identifier: id, title: id, allowsContentModifications: writable)
    }

    @discardableResult
    func addEvent(calendarID: String, id: String, externalID: String = "external", title: String?,
                  start: Date, end: Date, allDay: Bool = false, notes: String? = nil,
                  canceled: Bool = false) -> CalendarEventSnapshot {
        let event = CalendarEventSnapshot(handle: UUID().uuidString, identifier: id,
            externalIdentifier: externalID, calendarIdentifier: calendarID, title: title,
            startDate: start, endDate: end, isAllDay: allDay, notes: notes, isCanceled: canceled)
        committed[event.handle] = event
        return event
    }

    func replaceEvent(identifier: String, calendarID: String, start: Date, end: Date, title: String) {
        let oldHandles = committed.values.filter {
            $0.identifier == identifier && $0.calendarIdentifier == calendarID
        }.map(\.handle)
        oldHandles.forEach { committed.removeValue(forKey: $0) }
        _ = addEvent(calendarID: calendarID, id: identifier, title: title, start: start, end: end)
    }

    func removeEvent(identifier: String, calendarID: String) {
        let handles = committed.values.filter {
            $0.identifier == identifier && $0.calendarIdentifier == calendarID
        }.map(\.handle)
        handles.forEach { committed.removeValue(forKey: $0) }
    }

    func resetOperationHistory() {
        operations.removeAll()
        operationNumber = 0
        commitNumber = 0
        failOperationAt = nil
        failCommitAt = nil
    }

    func calendarDescriptor(withIdentifier id: String) -> CalendarDescriptor? { calendars[id] }

    func fetchEvents(in calendar: CalendarDescriptor, from: Date, to: Date,
                     retainHandles: Bool = false) throws -> [CalendarEventSnapshot] {
        guard calendars[calendar.identifier] != nil, unavailableOnFetch != calendar.identifier else {
            throw CalendarAccessError.calendarUnavailable(calendar.identifier)
        }
        return committed.values.filter {
            $0.calendarIdentifier == calendar.identifier && $0.startDate < to && $0.endDate >= from
        }.sorted { $0.startDate < $1.startDate }
    }

    func resolveBlocker(for record: SyncRecord, in target: CalendarDescriptor) throws -> BlockerResolution {
        guard calendars[target.identifier] != nil, unavailableOnResolve != target.identifier else {
            throw CalendarAccessError.calendarUnavailable(target.identifier)
        }
        let matches = committed.values.filter {
            $0.identifier == record.blockerEventIdentifier
                || $0.externalIdentifier == record.blockerExternalIdentifier
        }
        let valid = matches.filter {
            $0.calendarIdentifier == target.identifier && BlockerNotes.isManaged($0.notes)
        }
        if valid.count == 1, let event = valid.first { return .found(event) }
        if valid.count > 1 { return .ambiguous }
        if matches.contains(where: { $0.calendarIdentifier != target.identifier }) { return .foreign }
        if !matches.isEmpty { return .untagged }
        return .missing
    }

    func createBlockerEvent(in calendar: CalendarDescriptor, title: String, startDate: Date,
                            endDate: Date, isAllDay: Bool, notes: String, commit: Bool) throws -> CalendarEventSnapshot {
        try record(.create)
        let event = CalendarEventSnapshot(handle: UUID().uuidString, identifier: UUID().uuidString,
            externalIdentifier: UUID().uuidString, calendarIdentifier: calendar.identifier,
            title: title, startDate: startDate, endDate: endDate, isAllDay: isAllDay,
            notes: notes, isCanceled: false)
        staged[event.handle] = event
        if commit { try commitChanges() }
        return event
    }

    func updateBlockerEvent(_ event: CalendarEventSnapshot, title: String, startDate: Date,
                            endDate: Date, isAllDay: Bool, notes: String, commit: Bool) throws {
        try record(.update)
        staged[event.handle] = CalendarEventSnapshot(handle: event.handle, identifier: event.identifier,
            externalIdentifier: event.externalIdentifier, calendarIdentifier: event.calendarIdentifier,
            title: title, startDate: startDate, endDate: endDate, isAllDay: isAllDay,
            notes: notes, isCanceled: false)
        if commit { try commitChanges() }
    }

    func deleteEvent(_ event: CalendarEventSnapshot, commit: Bool) throws {
        try record(.delete)
        staged[event.handle] = .some(nil)
        if commit { try commitChanges() }
    }

    func commitChanges() throws {
        operations.append(.commit)
        commitNumber += 1
        if failCommitAt == commitNumber { throw Failure.injected }
        for (handle, event) in staged {
            if let event { committed[handle] = event }
            else { committed.removeValue(forKey: handle) }
        }
        staged.removeAll()
    }

    func discardPendingChanges() {
        operations.append(.discard)
        staged.removeAll()
    }

    func releaseEventHandles() {}

    private func record(_ operation: Operation) throws {
        operationNumber += 1
        if failOperationAt == operationNumber { throw Failure.injected }
        operations.append(operation)
    }
}

final class SyncEngineExecutionTests: XCTestCase {
    private let sourceID = "source"
    private let targetID = "target"

    func testDryRunPerformsNoCalendarOrPersistenceWrites() throws {
        let fixture = try makeFixture(eventCount: 1)
        let log = fixture.engine.sync(rule: fixture.rule, dryRun: true)
        XCTAssertEqual(log.added.count, 1)
        XCTAssertTrue(fixture.calendar.operations.isEmpty)
        XCTAssertTrue(fixture.records.loadRecords(for: fixture.rule.id).isEmpty)
        XCTAssertTrue(fixture.logs.loadLogs().isEmpty)
    }

    func testUnreadableMappingStatePreventsCalendarWritesAndIsPreserved() throws {
        let fixture = try makeFixture(eventCount: 1)
        let url = fixture.records.filePath(for: fixture.rule.id)
        let original = Data("{invalid".utf8)
        try original.write(to: url)
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertTrue(log.added.isEmpty, "Uncommitted creates must not be reported as completed")
        XCTAssertTrue(fixture.calendar.operations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnavailableTargetReadsFailClosedForAdoptionAndCleanup() throws {
        let creation = try makeFixture(eventCount: 1)
        creation.calendar.unavailableOnFetch = targetID
        let createLog = creation.engine.sync(rule: creation.rule)
        XCTAssertFalse(createLog.errors.isEmpty)
        XCTAssertTrue(creation.calendar.operations.isEmpty)
        XCTAssertTrue(creation.records.loadRecords(for: creation.rule.id).isEmpty)

        let cleanup = try makeFixture(eventCount: 1)
        _ = cleanup.engine.sync(rule: cleanup.rule)
        let source = try cleanup.calendar.fetchEvents(in: cleanup.calendar.calendars[sourceID]!,
            from: cleanup.start, to: cleanup.end, retainHandles: false).first!
        cleanup.calendar.removeEvent(identifier: source.identifier, calendarID: sourceID)
        cleanup.calendar.resetOperationHistory()
        cleanup.calendar.unavailableOnResolve = targetID
        let cleanupLog = cleanup.engine.sync(rule: cleanup.rule)
        XCTAssertFalse(cleanupLog.errors.isEmpty)
        XCTAssertTrue(cleanup.calendar.operations.isEmpty)
        XCTAssertEqual(cleanup.records.loadRecords(for: cleanup.rule.id).count, 1)
    }

    func testMappingWriteFailureAfterCommitRecoversByAdoptionWithoutDuplicate() throws {
        var failWrites = true
        let fixture = try makeFixture(eventCount: 1, writeHandler: { data, url in
            if failWrites { throw NSError(domain: "InjectedWrite", code: 1) }
            try data.write(to: url, options: .atomic)
        })
        let firstRun = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(firstRun.errors.isEmpty)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 1)
        XCTAssertTrue(fixture.records.loadRecords(for: fixture.rule.id).isEmpty)

        failWrites = false
        fixture.calendar.resetOperationHistory()
        // Reconstruct the process-owned engine and stores after the committed
        // blocker survived but its mapping checkpoint did not.
        let restartedRecords = try SyncRecordStore(
            baseDirectory: fixture.directory.appendingPathComponent("records"),
            writeHandler: { data, url in
                if failWrites { throw NSError(domain: "InjectedWrite", code: 1) }
                try data.write(to: url, options: .atomic)
            }
        )
        let restartedLogs = try SyncLogStore(
            logFileURL: fixture.directory.appendingPathComponent("logs/activity.json")
        )
        let restartedEngine = SyncEngine(calendarAccess: fixture.calendar,
            syncRecordStore: restartedRecords, syncLogStore: restartedLogs)
        let retry = restartedEngine.sync(rule: fixture.rule)
        XCTAssertTrue(retry.errors.isEmpty)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 1)
        XCTAssertEqual(restartedRecords.loadRecords(for: fixture.rule.id).count, 1)
        XCTAssertTrue(fixture.calendar.operations.isEmpty)
    }

    func testCreatesAndPersistsMappingAfterConfirmedCommit() throws {
        let fixture = try makeFixture(eventCount: 1)
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertEqual(log.added.count, 1)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 1)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, 1)
        XCTAssertEqual(fixture.calendar.operations, [.create, .commit])
    }

    func testAdoptsMatchingManagedBlockerWithoutCreatingDuplicate() throws {
        let fixture = try makeFixture(eventCount: 1)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        let notes = BlockerNotes.compose(origins: [sourceID])
        let existing = fixture.calendar.addEvent(calendarID: targetID, id: "managed", title: "Busy",
            start: source.startDate, end: source.endDate, notes: notes)
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertTrue(log.added.isEmpty)
        XCTAssertEqual(fixture.calendar.committed.count, 2)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).first?.blockerEventIdentifier,
                       existing.identifier)
        XCTAssertTrue(fixture.calendar.operations.isEmpty)
    }

    func testLegacyManagedBlockerWithoutOriginsIsAdoptedAndTagged() throws {
        let fixture = try makeFixture(eventCount: 1)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        let legacy = fixture.calendar.addEvent(calendarID: targetID, id: "legacy", title: "Busy",
            start: source.startDate, end: source.endDate, notes: CalendarService.blockerNotesTag)
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertTrue(log.errors.isEmpty)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 1)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).first?.blockerEventIdentifier,
                       legacy.identifier)
        XCTAssertTrue(BlockerNotes.origins(fromNotes: fixture.calendar.committed[legacy.handle]?.notes)
            .contains(sourceID))
    }

    func testAdoptionSkipsBlockerOwnedByAnotherRule() throws {
        let fixture = try makeFixture(eventCount: 1)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        let existing = fixture.calendar.addEvent(calendarID: targetID, id: "owned", title: "Busy",
            start: source.startDate, end: source.endDate, notes: BlockerNotes.compose(origins: [sourceID]))
        let ownerID = UUID()
        let ownerRecord = SyncRecord(sourceEventIdentifier: "other-source", sourceExternalIdentifier: "other-ext",
            sourceStartDate: source.startDate, sourceEndDate: source.endDate, sourceIsAllDay: false,
            sourceContentHash: "hash", blockerEventIdentifier: existing.identifier,
            blockerExternalIdentifier: existing.externalIdentifier, lastSyncedAt: Date())
        try fixture.records.saveRecords([ownerRecord], for: ownerID)

        _ = fixture.engine.sync(rule: fixture.rule)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 2)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, 1)
    }

    func testFailedFinalCommitDiscardsStagedEventsAndKeepsPriorMappings() throws {
        let fixture = try makeFixture(eventCount: 1)
        fixture.calendar.failCommitAt = 1
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertTrue(log.added.isEmpty)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == sourceID }.count, 1)
        XCTAssertFalse(fixture.calendar.committed.values.contains { $0.calendarIdentifier == targetID })
        XCTAssertTrue(fixture.records.loadRecords(for: fixture.rule.id).isEmpty)
        XCTAssertEqual(fixture.calendar.operations, [.create, .commit, .discard])
    }

    func testFailedFiftiethOperationCommitStopsBeforeFurtherCalendarWrites() throws {
        let fixture = try makeFixture(eventCount: 51)
        fixture.calendar.failCommitAt = 1
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertTrue(log.added.isEmpty)
        XCTAssertEqual(fixture.calendar.operations.filter { $0 == .create }.count, 50)
        XCTAssertEqual(fixture.calendar.operations.suffix(2), [.commit, .discard])
        XCTAssertFalse(fixture.calendar.committed.values.contains { $0.calendarIdentifier == targetID })
        XCTAssertTrue(fixture.records.loadRecords(for: fixture.rule.id).isEmpty)
    }

    func testLaterBatchFailureKeepsEarlierCheckpointAndRetryCompletesIdempotently() throws {
        let fixture = try makeFixture(eventCount: 51)
        fixture.calendar.failCommitAt = 2
        let firstRun = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(firstRun.errors.isEmpty)
        XCTAssertEqual(firstRun.added.count, 50, "Only the confirmed first batch should be reported")
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 50)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, 50)

        fixture.calendar.resetOperationHistory()
        let retry = fixture.engine.sync(rule: fixture.rule)
        XCTAssertTrue(retry.errors.isEmpty)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 51)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, 51)
    }

    func testChangedSourceUpdatesManagedBlocker() throws {
        let fixture = try makeFixture(eventCount: 1)
        _ = fixture.engine.sync(rule: fixture.rule)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        fixture.calendar.replaceEvent(identifier: source.identifier, calendarID: sourceID,
            start: source.startDate, end: source.endDate.addingTimeInterval(600), title: "Updated")
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertEqual(log.updated.count, 1)
        let blocker = try XCTUnwrap(fixture.calendar.committed.values.first { $0.calendarIdentifier == targetID })
        XCTAssertEqual(blocker.endDate, source.endDate.addingTimeInterval(600))
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, 1)
    }

    func testOrphanedSourceDeletesManagedBlockerAndMapping() throws {
        let fixture = try makeFixture(eventCount: 1)
        _ = fixture.engine.sync(rule: fixture.rule)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        fixture.calendar.removeEvent(identifier: source.identifier, calendarID: sourceID)
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertEqual(log.removed.count, 1)
        XCTAssertFalse(fixture.calendar.committed.values.contains { $0.calendarIdentifier == targetID })
        XCTAssertTrue(fixture.records.loadRecords(for: fixture.rule.id).isEmpty)
    }

    func testFailedCreateDoesNotPersistFabricatedMapping() throws {
        let fixture = try makeFixture(eventCount: 3)
        fixture.calendar.failOperationAt = 2
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertEqual(log.added.count, 2)
        XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, 2)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, 2)
    }

    func testFailedUpdateRetainsPreviousMappingAndBlockerForRetry() throws {
        let fixture = try makeFixture(eventCount: 1)
        _ = fixture.engine.sync(rule: fixture.rule)
        let oldRecord = try XCTUnwrap(fixture.records.loadRecords(for: fixture.rule.id).first)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        fixture.calendar.replaceEvent(identifier: source.identifier, calendarID: sourceID,
            start: source.startDate, end: source.endDate.addingTimeInterval(600), title: "Changed")
        fixture.calendar.resetOperationHistory()
        fixture.calendar.failOperationAt = 1
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertTrue(log.updated.isEmpty)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).first?.sourceContentHash,
                       oldRecord.sourceContentHash)
        let blocker = try XCTUnwrap(fixture.calendar.committed.values.first { $0.calendarIdentifier == targetID })
        XCTAssertEqual(blocker.endDate, source.endDate)
    }

    func testFailedDeleteRetainsMappingAndBlockerForRetry() throws {
        let fixture = try makeFixture(eventCount: 1)
        _ = fixture.engine.sync(rule: fixture.rule)
        let record = try XCTUnwrap(fixture.records.loadRecords(for: fixture.rule.id).first)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        fixture.calendar.removeEvent(identifier: source.identifier, calendarID: sourceID)
        fixture.calendar.resetOperationHistory()
        fixture.calendar.failOperationAt = 1
        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertTrue(log.removed.isEmpty)
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).first?.id, record.id)
        XCTAssertTrue(fixture.calendar.committed.values.contains { $0.identifier == record.blockerEventIdentifier })
    }

    func testSharedBlockerOwnershipPreventsCrossRuleDeletion() throws {
        let fixture = try makeFixture(eventCount: 1)
        _ = fixture.engine.sync(rule: fixture.rule)
        let record = try XCTUnwrap(fixture.records.loadRecords(for: fixture.rule.id).first)
        let otherRuleID = UUID()
        try fixture.records.saveRecords([record], for: otherRuleID)
        let source = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false).first!
        fixture.calendar.removeEvent(identifier: source.identifier, calendarID: sourceID)

        let log = fixture.engine.sync(rule: fixture.rule)
        XCTAssertFalse(log.errors.isEmpty)
        XCTAssertTrue(fixture.calendar.committed.values.contains { $0.identifier == record.blockerEventIdentifier })
        XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).first?.id, record.id)
    }

    func testMixedRunExecutesCreatesThenUpdatesThenDeletesBeforeCommit() throws {
        let fixture = try makeFixture(eventCount: 2)
        _ = fixture.engine.sync(rule: fixture.rule)
        let sources = try fixture.calendar.fetchEvents(in: fixture.calendar.calendars[sourceID]!,
            from: fixture.start, to: fixture.end, retainHandles: false)
        fixture.calendar.replaceEvent(identifier: sources[0].identifier, calendarID: sourceID,
            start: sources[0].startDate, end: sources[0].endDate.addingTimeInterval(600), title: "Changed")
        fixture.calendar.removeEvent(identifier: sources[1].identifier, calendarID: sourceID)
        let newStart = fixture.start.addingTimeInterval(12_000)
        fixture.calendar.addEvent(calendarID: sourceID, id: "source-new", title: "New",
            start: newStart, end: newStart.addingTimeInterval(1800))
        fixture.calendar.resetOperationHistory()
        _ = fixture.engine.sync(rule: fixture.rule)
        XCTAssertEqual(fixture.calendar.operations, [.create, .update, .delete, .commit])
    }

    func testBatchBoundariesCommitAtFiftyOperations() throws {
        for count in [0, 1, 49, 50, 51, 100] {
            let fixture = try makeFixture(eventCount: count)
            _ = fixture.engine.sync(rule: fixture.rule)
            let commits = fixture.calendar.operations.filter { $0 == .commit }.count
            XCTAssertEqual(commits, count == 0 ? 0 : (count + 49) / 50,
                           "Unexpected commit count for \(count) operations")
            XCTAssertEqual(fixture.calendar.committed.values.filter { $0.calendarIdentifier == targetID }.count, count)
            XCTAssertEqual(fixture.records.loadRecords(for: fixture.rule.id).count, count)
            try FileManager.default.removeItem(at: fixture.directory)
        }
    }

    private func makeFixture(eventCount: Int,
                             writeHandler: ((Data, URL) throws -> Void)? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let recordDirectory = directory.appendingPathComponent("records")
        let records: SyncRecordStore
        if let writeHandler {
            records = try SyncRecordStore(baseDirectory: recordDirectory, writeHandler: writeHandler)
        } else {
            records = try SyncRecordStore(baseDirectory: recordDirectory)
        }
        let logs = try SyncLogStore(logFileURL: directory.appendingPathComponent("logs/activity.json"))
        let calendar = FakeCalendarAccess()
        calendar.addCalendar(sourceID)
        calendar.addCalendar(targetID)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let end = start.addingTimeInterval(Double(120 * 24 * 3600))
        for index in 0..<eventCount {
            let date = start.addingTimeInterval(Double(index * 3600))
            calendar.addEvent(calendarID: sourceID, id: "source-\(index)", title: "Event \(index)",
                start: date, end: date.addingTimeInterval(1800))
        }
        let rule = MirrorRule(id: UUID(), title: "Test", sourceCalendarIdentifier: sourceID,
            targetCalendarIdentifier: targetID, windowDays: 120, blockerLabel: "Busy",
            usePlaceholder: true, isEnabled: true, createdAt: Date(), updatedAt: Date())
        let engine = SyncEngine(calendarAccess: calendar, syncRecordStore: records, syncLogStore: logs)
        return Fixture(directory: directory, calendar: calendar, records: records, logs: logs,
                       engine: engine, rule: rule, start: start, end: end)
    }

    private struct Fixture {
        let directory: URL
        let calendar: FakeCalendarAccess
        let records: SyncRecordStore
        let logs: SyncLogStore
        let engine: SyncEngine
        let rule: MirrorRule
        let start: Date
        let end: Date
    }
}
