import EventKit
import Foundation
import XCTest
@testable import CalmMirrorCore

/// Opt-in integration checks against two temporary, user-approved EventKit calendars.
/// These tests never run as part of the normal unit-test suite.
final class EventKitIntegrationTests: XCTestCase {
    func testCommittedBlockerRecoveryAndPendingChangeReset() throws {
        guard ProcessInfo.processInfo.environment["CALMIRROR_RUN_EVENTKIT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CALMIRROR_RUN_EVENTKIT_INTEGRATION=1 to create disposable local calendars.")
        }

        guard ProcessInfo.processInfo.environment["CALMIRROR_ALLOW_ICLOUD_TEST_CALENDARS"] == "1" else {
            throw XCTSkip("Set CALMIRROR_ALLOW_ICLOUD_TEST_CALENDARS=1 to permit temporary iCloud calendars.")
        }
        let eventStore = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Full Calendar access is not granted to this test process.")
        }
        guard let iCloudSource = eventStore.sources.first(where: {
            $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud")
        }) else {
            throw XCTSkip("No iCloud calendar source is available.")
        }

        let suffix = UUID().uuidString
        let source = try makeCalendar(title: "CalMirror Test Source \(suffix)", source: iCloudSource,
                                      eventStore: eventStore)
        let sourceCalendarID = source.calendarIdentifier
        var target: EKCalendar?
        defer {
            if let targetID = target?.calendarIdentifier,
               let calendar = eventStore.calendar(withIdentifier: targetID) {
                try? eventStore.removeCalendar(calendar, commit: true)
            }
            if let calendar = eventStore.calendar(withIdentifier: sourceCalendarID) {
                try? eventStore.removeCalendar(calendar, commit: true)
            }
        }
        target = try makeCalendar(title: "CalMirror Test Target \(suffix)", source: iCloudSource,
                                  eventStore: eventStore)
        let targetCalendar = try XCTUnwrap(target)
        let targetCalendarID = targetCalendar.calendarIdentifier
        let calendarService = CalendarService(eventStore: eventStore)
        let start = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            .addingTimeInterval(12 * 60 * 60)
        let end = start.addingTimeInterval(60 * 60)

        let sourceEvent = EKEvent(eventStore: eventStore)
        sourceEvent.calendar = source
        sourceEvent.title = "Original integration event"
        sourceEvent.startDate = start
        sourceEvent.endDate = end
        try eventStore.save(sourceEvent, span: .thisEvent, commit: true)
        let sourceEventID = try XCTUnwrap(sourceEvent.eventIdentifier)

        let rule = MirrorRule(
            title: "EventKit Integration \(suffix.prefix(8))",
            sourceCalendarIdentifier: source.calendarIdentifier,
            targetCalendarIdentifier: targetCalendar.calendarIdentifier,
            windowDays: 7,
            blockerLabel: "Busy",
            usePlaceholder: false
        )
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalMirror-EventKit-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let logStore = try SyncLogStore(logFileURL: scratch.appendingPathComponent("logs.json"))
        let failedMappingStore = try SyncRecordStore(baseDirectory: scratch.appendingPathComponent("failed-mappings"))
        let failingWriterStore = try SyncRecordStore(
            baseDirectory: scratch.appendingPathComponent("failing-mappings"),
            writeHandler: { _, _ in throw IntegrationWriteError.injected }
        )

        // EventKit commits the new blocker; deliberately fail the later JSON
        // checkpoint, then verify that a subsequent run adopts the real blocker.
        let firstRun = SyncEngine(calendarService: calendarService,
                                  syncRecordStore: failingWriterStore,
                                  syncLogStore: logStore).sync(rule: rule)
        XCTAssertFalse(firstRun.errors.isEmpty, "The injected mapping checkpoint failure should be logged")
        XCTAssertEqual(events(in: targetCalendarID, store: eventStore).count, 1)

        // EventKit reset behavior is what the engine uses after an operation or
        // commit error. Verify staged creates, edits, and deletes are discarded.
        let blocker = try XCTUnwrap(events(in: targetCalendarID, store: eventStore).first)
        let originalTitle = blocker.title
        try calendarService.updateBlockerEvent(blocker, title: "Uncommitted edit",
                                               startDate: start, endDate: end, isAllDay: false,
                                               notes: blocker.notes ?? "", commit: false)
        calendarService.discardPendingChanges()
        XCTAssertEqual(events(in: targetCalendarID, store: eventStore).first?.title, originalTitle)

        let blockerForDelete = try XCTUnwrap(events(in: targetCalendarID, store: eventStore).first)
        try calendarService.deleteEvent(blockerForDelete, commit: false)
        calendarService.discardPendingChanges()
        XCTAssertEqual(events(in: targetCalendarID, store: eventStore).count, 1)

        let currentTarget = try XCTUnwrap(eventStore.calendar(withIdentifier: targetCalendarID))
        _ = try calendarService.createBlockerEvent(
            in: currentTarget, title: "Uncommitted create", startDate: start.addingTimeInterval(7200),
            endDate: end.addingTimeInterval(7200), isAllDay: false,
            notes: BlockerNotes.compose(origins: [source.calendarIdentifier]), commit: false
        )
        calendarService.discardPendingChanges()
        XCTAssertEqual(events(in: targetCalendarID, store: eventStore).count, 1)

        let recovery = SyncEngine(calendarService: calendarService,
                                  syncRecordStore: failedMappingStore,
                                  syncLogStore: logStore)
        _ = recovery.sync(rule: rule)
        XCTAssertEqual(try failedMappingStore.loadRecordsChecked(for: rule.id).count, 1)
        XCTAssertEqual(events(in: targetCalendarID, store: eventStore).count, 1,
                         "Recovery should adopt the committed blocker without duplicating it")

        let sourceEventToUpdate = try XCTUnwrap(eventStore.event(withIdentifier: sourceEventID))
        sourceEventToUpdate.title = "Updated integration event"
        try eventStore.save(sourceEventToUpdate, span: .thisEvent, commit: true)
        let updateRun = recovery.sync(rule: rule)
        XCTAssertEqual(updateRun.updatedCount, 1)
        XCTAssertEqual(events(in: targetCalendarID, store: eventStore).first?.title,
                       rule.blockerTitle(forSourceTitle: sourceEventToUpdate.title))

        let sourceEventToDelete = try XCTUnwrap(eventStore.event(withIdentifier: sourceEventID))
        try eventStore.remove(sourceEventToDelete, span: .thisEvent, commit: true)
        let deleteRun = recovery.sync(rule: rule)
        XCTAssertEqual(deleteRun.removedCount, 1)
        XCTAssertTrue(events(in: targetCalendarID, store: eventStore).isEmpty)

        try eventStore.removeCalendar(try XCTUnwrap(eventStore.calendar(withIdentifier: targetCalendarID)), commit: true)
        target = nil
        try eventStore.removeCalendar(try XCTUnwrap(eventStore.calendar(withIdentifier: sourceCalendarID)), commit: true)
        XCTAssertNil(eventStore.calendar(withIdentifier: targetCalendarID))
        XCTAssertNil(eventStore.calendar(withIdentifier: sourceCalendarID))
    }

    private func makeCalendar(title: String, source: EKSource,
                              eventStore: EKEventStore) throws -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = title
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func events(in calendarID: String, store: EKEventStore) -> [EKEvent] {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 10, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate)
    }

    private enum IntegrationWriteError: Error {
        case injected
    }
}
