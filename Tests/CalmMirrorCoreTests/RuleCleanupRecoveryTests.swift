import XCTest
@testable import CalmMirrorCore

/// Failure injection for rule deletion cleanup, independent of EventKit permissions.
final class RuleCleanupRecoveryTests: XCTestCase {
    func testFailedBlockerDeleteRetainsRuleAndMappingsThenRetryCleansUp() throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryFiles() }
        fixture.calendar.failDeleteFor = "blocker-2"

        XCTAssertThrowsError(try fixture.cleanup())
        XCTAssertTrue(fixture.store.rule(for: fixture.rule.id) != nil)
        XCTAssertEqual(try fixture.records.loadRecordsChecked(for: fixture.rule.id).count, 2)
        XCTAssertEqual(fixture.calendar.committedBlockerIDs, Set(["blocker-1", "blocker-2"]))
        XCTAssertTrue(fixture.calendar.discardedPendingChanges)

        fixture.calendar.failDeleteFor = nil
        let result = try fixture.cleanup()
        XCTAssertEqual(result.blockersRemoved, 2)
        XCTAssertNil(fixture.store.rule(for: fixture.rule.id))
        XCTAssertTrue(try fixture.records.loadRecordsChecked(for: fixture.rule.id).isEmpty)
        XCTAssertTrue(fixture.calendar.committedBlockerIDs.isEmpty)
    }

    func testFailedCalendarCommitRetainsStateAndRetryDoesNotDeleteForeignEvents() throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryFiles() }
        fixture.calendar.failNextCommit = true

        XCTAssertThrowsError(try fixture.cleanup())
        XCTAssertNotNil(fixture.store.rule(for: fixture.rule.id))
        XCTAssertEqual(try fixture.records.loadRecordsChecked(for: fixture.rule.id).count, 2)
        XCTAssertEqual(fixture.calendar.committedBlockerIDs, Set(["blocker-1", "blocker-2"]))

        // One blocker is now foreign. Retry removes only the still verified managed blocker.
        let original = try XCTUnwrap(fixture.calendar.snapshots["blocker-2"])
        fixture.calendar.snapshots["blocker-2"] = CalendarEventSnapshot(
            handle: original.handle, identifier: original.identifier, externalIdentifier: original.externalIdentifier,
            calendarIdentifier: original.calendarIdentifier, title: original.title, startDate: original.startDate,
            endDate: original.endDate, isAllDay: original.isAllDay, notes: "User created event", isCanceled: original.isCanceled
        )
        let result = fixture.cleanupExpectingFailure()
        XCTAssertNotNil(result)
        XCTAssertNotNil(fixture.store.rule(for: fixture.rule.id))
        XCTAssertEqual(try fixture.records.loadRecordsChecked(for: fixture.rule.id).count, 2)
        XCTAssertTrue(fixture.calendar.deletedIDs.isEmpty)
    }

    func testResolutionFailureAfterStagedDeleteDiscardsAllPendingChanges() throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryFiles() }
        fixture.calendar.failResolveFor = "blocker-2"

        XCTAssertThrowsError(try fixture.cleanup())
        XCTAssertTrue(fixture.calendar.pendingIDs.isEmpty)
        XCTAssertTrue(fixture.calendar.discardedPendingChanges)
        XCTAssertEqual(fixture.calendar.committedBlockerIDs, Set(["blocker-1", "blocker-2"]))
        XCTAssertNotNil(fixture.store.rule(for: fixture.rule.id))
        XCTAssertEqual(try fixture.records.loadRecordsChecked(for: fixture.rule.id).count, 2)
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "test.\(UUID().uuidString)"
        let rule: MirrorRule
        let defaults: UserDefaults
        let store: RuleStore
        let records: SyncRecordStore
        let calendar = CleanupCalendarFake()

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suiteName)!
            let lockURL = root.appendingPathComponent("mutation.lock")
            store = RuleStore(defaults: defaults, mutationLockURL: lockURL)
            records = try SyncRecordStore(baseDirectory: root.appendingPathComponent("records"))
            rule = MirrorRule(title: "Test", sourceCalendarIdentifier: "source", targetCalendarIdentifier: "target",
                              windowDays: 14, blockerLabel: "Busy", usePlaceholder: true)
            try store.addRule(rule)
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            let mappings = (1...2).map { index in
                SyncRecord(sourceEventIdentifier: "source-\(index)", sourceExternalIdentifier: "source-ext-\(index)",
                           sourceStartDate: t, sourceEndDate: t.addingTimeInterval(3600), sourceIsAllDay: false,
                           sourceContentHash: "hash", blockerEventIdentifier: "blocker-\(index)",
                           blockerExternalIdentifier: "blocker-ext-\(index)", lastSyncedAt: t)
            }
            try records.saveRecords(mappings, for: rule.id)
            for mapping in mappings {
                calendar.snapshots[mapping.blockerEventIdentifier] = CalendarEventSnapshot(
                    handle: mapping.blockerEventIdentifier, identifier: mapping.blockerEventIdentifier,
                    externalIdentifier: mapping.blockerExternalIdentifier, calendarIdentifier: "target",
                    title: "Busy", startDate: t, endDate: t.addingTimeInterval(3600), isAllDay: false,
                    notes: "Managed by CalMirror", isCanceled: false
                )
            }
        }

        func cleanup() throws -> (rule: MirrorRule, blockersRemoved: Int) {
            try store.removeRuleWithCleanup(id: rule.id, syncRecordStore: records, calendarAccess: calendar)
        }

        func cleanupExpectingFailure() -> Error? {
            do { _ = try cleanup(); return nil } catch { return error }
        }

        func removeTemporaryFiles() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class CleanupCalendarFake: CalendarAccess {
    var snapshots: [String: CalendarEventSnapshot] = [:]
    var failDeleteFor: String?
    var failResolveFor: String?
    var failNextCommit = false
    var pendingIDs: [String] = []
    var deletedIDs: [String] = []
    var discardedPendingChanges = false
    var committedBlockerIDs: Set<String> { Set(snapshots.keys) }

    func calendarDescriptor(withIdentifier id: String) -> CalendarDescriptor? {
        CalendarDescriptor(identifier: id, title: id, allowsContentModifications: true)
    }
    func fetchEvents(in calendar: CalendarDescriptor, from: Date, to: Date, retainHandles: Bool) throws -> [CalendarEventSnapshot] { [] }
    func resolveBlocker(for record: SyncRecord, in target: CalendarDescriptor) throws -> BlockerResolution {
        if record.blockerEventIdentifier == failResolveFor { throw NSError(domain: "cleanup-test", code: 3) }
        guard let event = snapshots[record.blockerEventIdentifier] else { return .missing }
        guard event.calendarIdentifier == target.identifier else { return .foreign }
        guard event.notes?.contains("Managed by CalMirror") == true else { return .untagged }
        return .found(event)
    }
    func createBlockerEvent(in calendar: CalendarDescriptor, title: String, startDate: Date, endDate: Date, isAllDay: Bool, notes: String, commit: Bool) throws -> CalendarEventSnapshot { fatalError("Unused") }
    func updateBlockerEvent(_ event: CalendarEventSnapshot, title: String, startDate: Date, endDate: Date, isAllDay: Bool, notes: String, commit: Bool) throws { fatalError("Unused") }
    func deleteEvent(_ event: CalendarEventSnapshot, commit: Bool) throws {
        if event.identifier == failDeleteFor { throw NSError(domain: "cleanup-test", code: 1) }
        pendingIDs.append(event.identifier)
    }
    func commitChanges() throws {
        if failNextCommit { failNextCommit = false; throw NSError(domain: "cleanup-test", code: 2) }
        for id in pendingIDs { snapshots.removeValue(forKey: id); deletedIDs.append(id) }
        pendingIDs.removeAll()
    }
    func discardPendingChanges() { pendingIDs.removeAll(); discardedPendingChanges = true }
    func releaseEventHandles() {}
}
