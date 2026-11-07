import Foundation

/// Orchestrates calendar event synchronization for mirror rules.
///
/// The sync engine executes the core algorithm: fetch source events,
/// diff against existing sync records, create/update/delete blocker events,
/// and persist the updated state. Each rule is processed independently.
///
/// ## Algorithm Overview
/// 1. Validate source and target calendars exist and are writable.
/// 2. Fetch source events within the configured time window, skipping
///    cancelled events and blockers that would loop back to a calendar they
///    derive from (see ``BlockerNotes``).
/// 3. Diff fetched events against persisted `SyncRecord` mappings, mirroring
///    source events with an identical title and time only once.
/// 3b. Adopt matching CalMirror blockers already present in the target
///    calendar instead of creating duplicates.
/// 4. Execute create/update/delete operations for blocker events.
/// 5. Persist updated sync records and append a `SyncLog` entry.
///
/// ## Recurring Events
/// `predicateForEvents` automatically expands recurring events into
/// individual occurrences. Each occurrence is treated as a standalone
/// event, producing one blocker per occurrence within the sync window.
public final class SyncEngine {

    // MARK: - Constants

    /// Maximum number of EventKit save/remove operations before an
    /// intermediate commit. Keeps memory pressure low and limits the
    /// blast radius of a single failed commit.
    private static let batchSize = 50

    // MARK: - Dependencies

    private let calendarService: any CalendarAccess
    private let syncRecordStore: SyncRecordStore
    private let syncLogStore: SyncLogStore

    // MARK: - Initialization

    /// Creates a sync engine with the specified dependencies.
    ///
    /// - Parameters:
    ///   - calendarService: The calendar service used for EventKit operations.
    ///     Defaults to the shared singleton.
    ///   - syncRecordStore: The store used to persist source-to-blocker mappings.
    ///   - syncLogStore: The store used to persist sync execution logs.
    public init(
        calendarService: CalendarService = .shared,
        syncRecordStore: SyncRecordStore,
        syncLogStore: SyncLogStore
    ) {
        self.calendarService = calendarService
        self.syncRecordStore = syncRecordStore
        self.syncLogStore = syncLogStore
    }

    /// Test seam for a staged in-memory calendar implementation.
    init(calendarAccess: any CalendarAccess, syncRecordStore: SyncRecordStore, syncLogStore: SyncLogStore) {
        self.calendarService = calendarAccess
        self.syncRecordStore = syncRecordStore
        self.syncLogStore = syncLogStore
    }

    // MARK: - Public API

    /// Executes the sync algorithm for a single mirror rule.
    ///
    /// Fetches source events within the rule's time window, diffs them
    /// against existing sync records, and creates/updates/deletes blocker
    /// events in the target calendar accordingly. Results are persisted
    /// and a `SyncLog` entry is returned.
    ///
    /// - Parameters:
    ///   - rule: The mirror rule defining source/target calendars and settings.
    ///   - dryRun: When `true`, the diff is computed but no EventKit changes
    ///     are written and no records are saved. Useful for previewing changes.
    /// - Returns: A `SyncLog` describing the outcome of this sync execution.
    public func sync(rule: MirrorRule, dryRun: Bool = false) -> SyncLog {
        let startTime = Date()

        // ------------------------------------------------------------------
        // Step 1: Validate calendars
        // ------------------------------------------------------------------

        guard let sourceCalendar = calendarService.calendarDescriptor(withIdentifier: rule.sourceCalendarIdentifier) else {
            return buildErrorLog(
                rule: rule,
                startTime: startTime,
                error: SyncError(
                    code: .calendarNotFound,
                    message: "Source calendar not found (identifier: \(rule.sourceCalendarIdentifier))."
                )
            )
        }

        guard let targetCalendar = calendarService.calendarDescriptor(withIdentifier: rule.targetCalendarIdentifier) else {
            return buildErrorLog(
                rule: rule,
                startTime: startTime,
                error: SyncError(
                    code: .calendarNotFound,
                    message: "Target calendar not found (identifier: \(rule.targetCalendarIdentifier))."
                )
            )
        }

        guard targetCalendar.allowsContentModifications else {
            return buildErrorLog(
                rule: rule,
                startTime: startTime,
                error: SyncError(
                    code: .calendarReadOnly,
                    message: "Target calendar \"\(targetCalendar.title)\" is read-only."
                )
            )
        }

        // ------------------------------------------------------------------
        // Step 2: Compute time window
        // ------------------------------------------------------------------

        let calendar = Calendar.current
        let windowStart = calendar.startOfDay(for: Date())
        let windowEnd = calendar.date(byAdding: .day, value: rule.windowDays, to: windowStart)!

        // ------------------------------------------------------------------
        // Step 3: Fetch source events, filter cancelled and looping ones
        // ------------------------------------------------------------------

        let allSourceEvents: [CalendarEventSnapshot]
        do {
            allSourceEvents = try calendarService.fetchEvents(
                in: sourceCalendar, from: windowStart, to: windowEnd, retainHandles: false
            )
        } catch {
            return buildErrorLog(rule: rule, startTime: startTime, error: SyncError(
                code: .calendarNotFound,
                message: "Could not read the source calendar; no calendar changes were made. \(error.localizedDescription)"
            ))
        }

        // Filtering before diffing also removes previously chained copies when
        // chaining is disabled: their records become orphaned and are cleaned up.
        let sourceEvents = allSourceEvents.filter { event in
            !event.isCanceled && rule.acceptsSource(notes: event.notes)
        }

        // ------------------------------------------------------------------
        // Step 4: Load existing sync records
        // ------------------------------------------------------------------

        let existingRecords: [SyncRecord]
        do {
            existingRecords = try syncRecordStore.loadRecordsChecked(for: rule.id)
        } catch {
            return buildErrorLog(rule: rule, startTime: startTime, error: SyncError(
                code: .unknown,
                message: "Sync mappings could not be read; no calendar changes were made. \(error.localizedDescription)"
            ))
        }

        let otherOwners: (local: Set<String>, external: Set<String>)
        do {
            otherOwners = try syncRecordStore.blockerIdentifiersOwned(byRulesOtherThan: rule.id)
        } catch {
            return buildErrorLog(rule: rule, startTime: startTime, error: SyncError(
                code: .unknown,
                message: "Could not verify blocker ownership across rules; no calendar changes were made. \(error.localizedDescription)"
            ))
        }
        if existingRecords.contains(where: {
            otherOwners.local.contains($0.blockerEventIdentifier)
                || otherOwners.external.contains($0.blockerExternalIdentifier)
        }) {
            return buildErrorLog(rule: rule, startTime: startTime, error: SyncError(
                code: .blockerOperationFailed,
                message: "A blocker mapping is also owned by another rule; refusing to mutate it."
            ))
        }

        // ------------------------------------------------------------------
        // Step 5: Diff — classify each event and record
        // ------------------------------------------------------------------

        let diffResult = computeDiff(
            sourceEvents: sourceEvents,
            existingRecords: existingRecords,
            rule: rule
        )

        // ------------------------------------------------------------------
        // Step 5b: Reuse blockers that already exist in the target calendar
        // ------------------------------------------------------------------

        // A new event whose blocker (same title and time) is already present
        // in the target calendar adopts it instead of creating a duplicate.
        let adoptableBlockers: [BlockerKey: CalendarEventSnapshot]
        do {
            adoptableBlockers = diffResult.newEvents.isEmpty ? [:] : try findAdoptableBlockers(
                in: targetCalendar, from: windowStart, to: windowEnd,
                existingRecords: existingRecords, rule: rule, otherOwners: otherOwners
            )
        } catch {
            return buildErrorLog(rule: rule, startTime: startTime, error: SyncError(
                code: .calendarNotFound,
                message: "Could not read the target calendar; no calendar changes were made. \(error.localizedDescription)"
            ))
        }
        var availableBlockers = adoptableBlockers
        var eventsToCreate: [NewEvent] = []
        var eventsToUpdate = diffResult.changedEvents
        var adoptedRecords: [SyncRecord] = []
        let now = Date()

        for newItem in diffResult.newEvents {
            let event = newItem.event
            guard let blocker = availableBlockers.removeValue(forKey: blockerKey(for: event, rule: rule)) else {
                eventsToCreate.append(newItem)
                continue
            }
            let record = Self.makeRecord(
                source: event, blocker: blocker,
                contentHash: newItem.contentHash, syncedAt: now
            )
            if blocker.notes == blockerNotes(for: event, rule: rule) {
                adoptedRecords.append(record)
            } else {
                // Adopted blocker lacks up-to-date origins: refresh it below.
                eventsToUpdate.append(ChangedEvent(
                    event: event,
                    contentHash: newItem.contentHash,
                    existingRecord: record
                ))
            }
        }

        // ------------------------------------------------------------------
        // Step 6: Execute changes (unless dry run)
        // ------------------------------------------------------------------

        var errors: [SyncError] = []
        var removedChanges: [BlockerChange] = []
        var addedChanges: [BlockerChange] = []
        var updatedChanges: [BlockerChange] = []
        var pendingAddedChanges: [BlockerChange] = []
        var pendingUpdatedChanges: [BlockerChange] = []
        var pendingRemovedChanges: [BlockerChange] = []
        var commitOutcomeUncertain = false
        var confirmedRecords = existingRecords
        var pendingRecordChanges: [(id: String, record: SyncRecord?)] = adoptedRecords.map {
            ($0.id, $0)
        }
        var pendingCalendarOperations = 0

        func checkpoint() throws {
            if pendingCalendarOperations > 0 {
                try calendarService.commitChanges()
                pendingCalendarOperations = 0
            }
            addedChanges.append(contentsOf: pendingAddedChanges)
            updatedChanges.append(contentsOf: pendingUpdatedChanges)
            removedChanges.append(contentsOf: pendingRemovedChanges)
            pendingAddedChanges.removeAll()
            pendingUpdatedChanges.removeAll()
            pendingRemovedChanges.removeAll()
            guard !pendingRecordChanges.isEmpty else { return }
            for change in pendingRecordChanges {
                if let record = change.record {
                    if let index = confirmedRecords.firstIndex(where: { $0.id == change.id }) {
                        confirmedRecords[index] = record
                    } else {
                        confirmedRecords.append(record)
                    }
                } else {
                    confirmedRecords.removeAll { $0.id == change.id }
                }
            }
            try syncRecordStore.saveRecords(confirmedRecords, for: rule.id)
            pendingRecordChanges.removeAll()
        }

        if !dryRun {
            var operationCount = 0

            // --- Create blockers for NEW events ---
            for newItem in eventsToCreate {
                if commitOutcomeUncertain { break }
                let event = newItem.event
                do {
                    let blocker = try calendarService.createBlockerEvent(
                        in: targetCalendar,
                        title: rule.blockerTitle(forSourceTitle: event.title),
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay,
                        notes: blockerNotes(for: event, rule: rule),
                        commit: false
                    )

                    let record = Self.makeRecord(
                        source: event, blocker: blocker,
                        contentHash: newItem.contentHash, syncedAt: now
                    )

                    pendingRecordChanges.append((record.id, record))
                    pendingAddedChanges.append(BlockerChange(
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay
                    ))

                    operationCount += 1
                    pendingCalendarOperations += 1
                    if operationCount % Self.batchSize == 0 {
                        do { try checkpoint() }
                        catch {
                            errors.append(SyncError(code: .eventKitInternal,
                                message: "Batch commit or mapping checkpoint failed; stopping this sync: \(error.localizedDescription)"))
                            commitOutcomeUncertain = true
                            calendarService.discardPendingChanges()
                        }
                    }
                } catch {
                    errors.append(SyncError(
                        code: .blockerOperationFailed,
                        message: "Failed to create blocker for source event \(event.identifier): \(error.localizedDescription)"
                    ))
                }
            }

            // --- Update blockers for CHANGED events ---
            for changedItem in eventsToUpdate {
                if commitOutcomeUncertain { break }
                let event = changedItem.event
                let existingRecord = changedItem.existingRecord

                do {
                    // Look up the blocker event: primary identifier first, then external fallback.
                    guard case .found(let blockerEvent) = try calendarService.resolveBlocker(
                        for: existingRecord, in: targetCalendar
                    ) else {
                        errors.append(SyncError(
                            code: .blockerOperationFailed,
                            message: "Blocker event not found for update (source: \(event.identifier))."
                        ))
                        continue
                    }

                    try calendarService.updateBlockerEvent(
                        blockerEvent,
                        title: rule.blockerTitle(forSourceTitle: event.title),
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay,
                        notes: blockerNotes(for: event, rule: rule),
                        commit: false
                    )

                    let record = Self.makeRecord(
                        source: event, blocker: blockerEvent,
                        contentHash: changedItem.contentHash, syncedAt: now
                    )

                    pendingRecordChanges.append((record.id, record))
                    pendingUpdatedChanges.append(BlockerChange(
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay
                    ))

                    operationCount += 1
                    pendingCalendarOperations += 1
                    if operationCount % Self.batchSize == 0 {
                        do { try checkpoint() }
                        catch {
                            errors.append(SyncError(code: .eventKitInternal,
                                message: "Batch commit or mapping checkpoint failed; stopping this sync: \(error.localizedDescription)"))
                            commitOutcomeUncertain = true
                            calendarService.discardPendingChanges()
                        }
                    }
                } catch {
                    errors.append(SyncError(
                        code: .blockerOperationFailed,
                        message: "Failed to update blocker for source event \(event.identifier): \(error.localizedDescription)"
                    ))
                }
            }

            // --- Delete blockers for ORPHANED records ---
            for orphanedRecord in diffResult.orphanedRecords {
                if commitOutcomeUncertain { break }
                do {
                    switch try calendarService.resolveBlocker(for: orphanedRecord, in: targetCalendar) {
                    case .found(let blockerEvent):
                        try calendarService.deleteEvent(blockerEvent, commit: false)
                        pendingRecordChanges.append((orphanedRecord.id, nil))

                        operationCount += 1
                        pendingCalendarOperations += 1
                        if operationCount % Self.batchSize == 0 {
                            do { try checkpoint() }
                            catch {
                                errors.append(SyncError(code: .eventKitInternal,
                                    message: "Batch commit or mapping checkpoint failed; stopping this sync: \(error.localizedDescription)"))
                                commitOutcomeUncertain = true
                                calendarService.discardPendingChanges()
                            }
                        }
                    case .missing:
                        pendingRecordChanges.append((orphanedRecord.id, nil))
                        pendingRemovedChanges.append(BlockerChange(
                            startDate: orphanedRecord.sourceStartDate,
                            endDate: orphanedRecord.sourceEndDate,
                            isAllDay: orphanedRecord.sourceIsAllDay
                        ))
                    case .foreign, .untagged, .ambiguous:
                        errors.append(SyncError(
                            code: .blockerOperationFailed,
                            message: "Refused to delete an orphaned blocker because its ownership could not be verified."
                        ))
                        continue
                    }

                    pendingRemovedChanges.append(BlockerChange(
                        startDate: orphanedRecord.sourceStartDate,
                        endDate: orphanedRecord.sourceEndDate,
                        isAllDay: orphanedRecord.sourceIsAllDay
                    ))
                } catch {
                    errors.append(SyncError(
                        code: .blockerOperationFailed,
                        message: "Failed to delete orphaned blocker \(orphanedRecord.blockerEventIdentifier): \(error.localizedDescription)"
                    ))
                }
            }

            // --- Final commit and mapping checkpoint for remaining work ---
            if !commitOutcomeUncertain
                && (pendingCalendarOperations > 0 || !pendingRecordChanges.isEmpty) {
                do {
                    try checkpoint()
                } catch {
                    commitOutcomeUncertain = true
                    calendarService.discardPendingChanges()
                    errors.append(SyncError(
                        code: .eventKitInternal,
                        message: "Final commit or mapping checkpoint failed: \(error.localizedDescription)"
                    ))
                }
            }
        } else {
            // Dry run: populate change arrays for reporting without executing.
            for newItem in eventsToCreate {
                addedChanges.append(BlockerChange(
                    startDate: newItem.event.startDate,
                    endDate: newItem.event.endDate,
                    isAllDay: newItem.event.isAllDay
                ))
            }
            for changedItem in eventsToUpdate {
                updatedChanges.append(BlockerChange(
                    startDate: changedItem.event.startDate,
                    endDate: changedItem.event.endDate,
                    isAllDay: changedItem.event.isAllDay
                ))
            }
            for orphanedRecord in diffResult.orphanedRecords {
                removedChanges.append(BlockerChange(
                    startDate: orphanedRecord.sourceStartDate,
                    endDate: orphanedRecord.sourceEndDate,
                    isAllDay: orphanedRecord.sourceIsAllDay
                ))
            }
        }

        // ------------------------------------------------------------------
        // Step 7: Build updated records list and persist
        // ------------------------------------------------------------------

        // Mappings are checkpointed only after their matching calendar batch
        // commits. If a later batch fails, earlier confirmed checkpoints remain.

        // ------------------------------------------------------------------
        // Step 8: Build and persist the sync log
        // ------------------------------------------------------------------

        let duration = Date().timeIntervalSince(startTime)

        var syncLog = SyncLog(
            ruleId: rule.id,
            timestamp: startTime,
            durationSeconds: duration,
            added: addedChanges,
            removed: removedChanges,
            updated: updatedChanges,
            errors: errors
        )

        if !dryRun {
            do {
                try syncLogStore.appendLog(syncLog)
            } catch {
                errors.append(SyncError(
                    code: .unknown,
                    message: "Calendar sync finished, but activity could not be saved: \(error.localizedDescription)"
                ))
                syncLog = SyncLog(ruleId: rule.id, timestamp: startTime,
                    durationSeconds: duration, added: addedChanges,
                    removed: removedChanges, updated: updatedChanges, errors: errors)
            }
        }

        calendarService.releaseEventHandles()
        return syncLog
    }

    /// Executes the sync algorithm for all enabled rules sequentially.
    ///
    /// Disabled rules are skipped. Each enabled rule is synced independently;
    /// a failure in one rule does not prevent subsequent rules from running.
    ///
    /// - Parameters:
    ///   - rules: The array of mirror rules to process.
    ///   - dryRun: When `true`, no EventKit changes are written.
    /// - Returns: An array of `SyncLog` entries, one per enabled rule processed.
    public func syncAll(rules: [MirrorRule], dryRun: Bool = false) -> [SyncLog] {
        rules
            .filter(\.isEnabled)
            .map { sync(rule: $0, dryRun: dryRun) }
    }

    // MARK: - Diff Algorithm

    /// Intermediate types used during the diff phase to classify source events.
    private struct NewEvent {
        let event: CalendarEventSnapshot
        let contentHash: String
    }

    private struct ChangedEvent {
        let event: CalendarEventSnapshot
        let contentHash: String
        let existingRecord: SyncRecord
    }

    /// Result of diffing source events against existing sync records.
    private struct DiffResult {
        /// Source events with no matching sync record — blockers must be created.
        let newEvents: [NewEvent]
        /// Source events whose content hash differs from the record — blockers must be updated.
        let changedEvents: [ChangedEvent]
        /// Existing records with no matching source event — blockers must be deleted.
        let orphanedRecords: [SyncRecord]
        /// Existing records whose content hash matches the source event — no action needed.
        let unchangedRecords: [SyncRecord]
    }

    /// Computes the diff between fetched source events and persisted sync records.
    ///
    /// Uses a composite key of `sourceEventIdentifier` and `sourceStartDate`
    /// (via `SyncRecord.id`) to match events to records. This correctly handles
    /// recurring event occurrences, which share the same `eventIdentifier` but
    /// have different start dates.
    ///
    /// - Parameters:
    ///   - sourceEvents: Events fetched from the source calendar within the time window.
    ///   - existingRecords: Previously persisted sync records for this rule.
    /// - Returns: A `DiffResult` classifying each event and record.
    private func computeDiff(
        sourceEvents: [CalendarEventSnapshot],
        existingRecords: [SyncRecord],
        rule: MirrorRule
    ) -> DiffResult {
        let plan = SyncPlanner.plan(
            sourceEvents: sourceEvents.map { event in
                SourceEventSnapshot(identifier: event.identifier, title: event.title,
                                    startDate: event.startDate, endDate: event.endDate,
                                    isAllDay: event.isAllDay, notes: event.notes)
            },
            existingRecords: existingRecords,
            rule: rule
        )
        // EventKit objects stay in the imperative engine. The planner only
        // returns indexes into this immutable snapshot of the source list.
        return DiffResult(
            newEvents: plan.newEvents.map {
                NewEvent(event: sourceEvents[$0.sourceIndex], contentHash: $0.contentHash)
            },
            changedEvents: plan.changedEvents.map {
                ChangedEvent(event: sourceEvents[$0.source.sourceIndex],
                             contentHash: $0.source.contentHash, existingRecord: $0.existingRecord)
            },
            orphanedRecords: plan.orphanedRecords,
            unchangedRecords: plan.unchangedRecords
        )
    }

    // MARK: - Private Helpers

    /// Builds the same persisted mapping after adoption, creation or update.
    private static func makeRecord(
        source: CalendarEventSnapshot, blocker: CalendarEventSnapshot, contentHash: String, syncedAt: Date
    ) -> SyncRecord {
        SyncRecord(
            sourceEventIdentifier: source.identifier,
            sourceExternalIdentifier: source.externalIdentifier,
            sourceStartDate: source.startDate,
            sourceEndDate: source.endDate,
            sourceIsAllDay: source.isAllDay,
            sourceContentHash: contentHash,
            blockerEventIdentifier: blocker.identifier,
            blockerExternalIdentifier: blocker.externalIdentifier,
            lastSyncedAt: syncedAt
        )
    }

    /// Returns the title-and-time identity of the blocker mirroring a source event.
    private func blockerKey(for event: CalendarEventSnapshot, rule: MirrorRule) -> BlockerKey {
        BlockerKey(
            title: rule.blockerTitle(forSourceTitle: event.title),
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay
        )
    }

    /// Returns the managed notes (tag + origin calendar chain) of the blocker
    /// mirroring a source event.
    private func blockerNotes(for event: CalendarEventSnapshot, rule: MirrorRule) -> String {
        BlockerNotes.compose(origins: BlockerNotes.originsForBlocker(
            sourceNotes: event.notes,
            sourceCalendarIdentifier: rule.sourceCalendarIdentifier
        ))
    }

    /// Indexes, by title and time, the CalMirror blockers of the target calendar
    /// that no sync record of this rule references.
    ///
    /// Such blockers appear when the record mapping was lost or went stale
    /// (records file removed, save failure, identifiers changed by the server).
    /// Only events carrying ``CalendarService/blockerNotesTag`` qualify: an
    /// adopted blocker is later updated or deleted along with its source event,
    /// which must never happen to an event the user created themselves.
    /// Blockers still referenced by a record are excluded because they are
    /// either already in use or about to be deleted as orphans.
    ///
    /// - Parameters:
    ///   - calendar: The rule's target calendar.
    ///   - startDate: Start of the sync window.
    ///   - endDate: End of the sync window.
    ///   - existingRecords: The rule's persisted sync records.
    /// - Returns: Adoptable blocker events keyed by their title and time.
    private func findAdoptableBlockers(
        in calendar: CalendarDescriptor,
        from startDate: Date,
        to endDate: Date,
        existingRecords: [SyncRecord],
        rule: MirrorRule,
        otherOwners: (local: Set<String>, external: Set<String>)
    ) throws -> [BlockerKey: CalendarEventSnapshot] {
        let claimedIdentifiers = Set(existingRecords.map(\.blockerEventIdentifier))
        let claimedExternalIdentifiers = Set(existingRecords.map(\.blockerExternalIdentifier))

        var adoptable: [BlockerKey: CalendarEventSnapshot] = [:]
        for event in try calendarService.fetchEvents(in: calendar, from: startDate, to: endDate, retainHandles: true) {
            guard BlockerNotes.isManaged(event.notes),
                  !claimedIdentifiers.contains(event.identifier),
                  !claimedExternalIdentifiers.contains(event.externalIdentifier),
                  !otherOwners.local.contains(event.identifier),
                  !otherOwners.external.contains(event.externalIdentifier)
            else { continue }

            let knownOrigins = BlockerNotes.origins(fromNotes: event.notes)
            guard knownOrigins.isEmpty || knownOrigins.contains(rule.sourceCalendarIdentifier) else { continue }

            let key = BlockerKey(
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay
            )
            // Keep the first match; any further identical blocker stays untouched.
            if adoptable[key] == nil {
                adoptable[key] = event
            }
        }
        return adoptable
    }

    /// Records an early calendar-validation failure using the existing logging policy.
    private func buildErrorLog(rule: MirrorRule, startTime: Date, error: SyncError) -> SyncLog {
        let duration = Date().timeIntervalSince(startTime)

        let syncLog = SyncLog(
            ruleId: rule.id,
            timestamp: startTime,
            durationSeconds: duration,
            added: [],
            removed: [],
            updated: [],
            errors: [error]
        )

        do {
            try syncLogStore.appendLog(syncLog)
        } catch {
            // Log persistence failure is non-fatal for error logs.
        }

        return syncLog
    }
}
