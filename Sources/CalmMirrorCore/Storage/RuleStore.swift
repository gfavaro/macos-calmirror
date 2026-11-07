import EventKit
import Foundation

/// Errors that can occur during rule store operations.
public enum RuleStoreError: Error, LocalizedError {
    /// The requested rule was not found in the store.
    case ruleNotFound(UUID)
    case unreadable(Error)

    public var errorDescription: String? {
        switch self {
        case .ruleNotFound(let id):
            return "No rule found with id \(id.uuidString)."
        case .unreadable(let error):
            return "Saved mirror rules could not be read; no changes were made. \(error.localizedDescription)"
        }
    }
}

/// Manages persistence of mirror rules in UserDefaults shared suite.
///
/// Both the SwiftUI app and CLI tool access rules through this store
/// using the shared suite `com.gravitek.calmirror`, enabling configuration
/// changes in one to be immediately visible to the other.
public final class RuleStore: @unchecked Sendable {

    /// The shared suite name used by both the app and CLI.
    public static let suiteName = "com.gravitek.calmirror"

    private let defaults: UserDefaults
    private let mutationLockURL: URL?

    public init() {
        // Use shared suite; fall back to standard if suite creation fails
        self.defaults = UserDefaults(suiteName: RuleStore.suiteName) ?? .standard
        self.mutationLockURL = nil
    }

    /// For testing: inject a custom UserDefaults instance.
    internal init(defaults: UserDefaults, mutationLockURL: URL? = nil) {
        self.defaults = defaults
        self.mutationLockURL = mutationLockURL
    }

    private func acquireMutationLock() throws -> ProcessMutationLock {
        if let mutationLockURL {
            return try ProcessMutationLock.acquire(at: mutationLockURL, wait: false)
        }
        return try ProcessMutationLock.acquire(wait: false)
    }

    // MARK: - Read Operations

    /// Loads all persisted mirror rules from UserDefaults.
    ///
    /// Decodes the JSON data stored under `MirrorRule.userDefaultsKey`.
    /// Returns an empty array if no data is stored or if decoding fails.
    ///
    /// - Returns: The array of persisted mirror rules, or an empty array.
    public func loadRules() -> [MirrorRule] {
        (try? loadRulesChecked()) ?? []
    }

    public func loadRulesChecked() throws -> [MirrorRule] {
        guard let data = defaults.data(forKey: MirrorRule.userDefaultsKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([MirrorRule].self, from: data)
        } catch {
            throw RuleStoreError.unreadable(error)
        }
    }

    /// Finds and returns a single rule by its identifier.
    ///
    /// - Parameter id: The UUID of the rule to look up.
    /// - Returns: The matching rule, or `nil` if no rule exists with that id.
    public func rule(for id: UUID) -> MirrorRule? {
        loadRules().first { $0.id == id }
    }

    // MARK: - Write Operations

    /// Encodes and persists the given array of rules to UserDefaults under the
    /// shared mutation lock. Lock and encoding failures are reported to callers.
    public func saveRules(_ rules: [MirrorRule]) throws {
        let lock = try acquireMutationLock()
        defer { lock.release() }
        try persistRules(rules)
    }

    private func persistRules(_ rules: [MirrorRule]) throws {
        let data = try JSONEncoder().encode(rules)
        defaults.set(data, forKey: MirrorRule.userDefaultsKey)
    }

    /// Validates and appends a new rule to the persisted collection.
    ///
    /// Runs validation on the rule's configuration before saving.
    /// If validation fails, the rule is not added and the error is thrown.
    ///
    /// - Parameter rule: The new rule to add.
    /// - Throws: `MirrorRule.ValidationError` if the rule's configuration is invalid.
    public func addRule(_ rule: MirrorRule) throws {
        let lock = try acquireMutationLock()
        defer { lock.release() }
        if let validationError = MirrorRule.validate(
            title: rule.title,
            sourceCalendarIdentifier: rule.sourceCalendarIdentifier,
            targetCalendarIdentifier: rule.targetCalendarIdentifier,
            windowDays: rule.windowDays,
            blockerLabel: rule.blockerLabel,
            usePlaceholder: rule.usePlaceholder
        ) {
            throw validationError
        }

        var rules = try loadRulesChecked()
        rules.append(rule)
        try persistRules(rules)
    }

    /// Replaces an existing rule with an updated version, matched by id.
    ///
    /// Locates the rule in the stored collection by its `id` property and
    /// replaces it with the provided updated rule.
    ///
    /// - Parameter rule: The updated rule (must have the same id as an existing rule).
    /// - Throws: `RuleStoreError.ruleNotFound` if no rule with the given id exists.
    public func updateRule(_ rule: MirrorRule) throws {
        let lock = try acquireMutationLock()
        defer { lock.release() }
        var rules = try loadRulesChecked()
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            throw RuleStoreError.ruleNotFound(rule.id)
        }
        rules[index] = rule
        try persistRules(rules)
    }

    /// Removes a rule by its identifier and returns the removed rule.
    ///
    /// - Parameter id: The UUID of the rule to remove.
    /// - Returns: The rule that was removed from the store.
    /// - Throws: `RuleStoreError.ruleNotFound` if no rule with the given id exists.
    @discardableResult
    public func removeRule(id: UUID) throws -> MirrorRule {
        let lock = try acquireMutationLock()
        defer { lock.release() }
        return try removeRuleWithoutLock(id: id)
    }

    private func removeRuleWithoutLock(id: UUID) throws -> MirrorRule {
        var rules = try loadRulesChecked()
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw RuleStoreError.ruleNotFound(id)
        }
        let removed = rules.remove(at: index)
        try persistRules(rules)
        return removed
    }

    /// Removes a rule and performs full cascade cleanup of associated data.
    ///
    /// This method ensures no orphaned data remains after a rule is deleted:
    /// 1. Loads the rule's sync records to identify managed blocker events.
    /// 2. Deletes each blocker event from the target calendar (primary identifier
    ///    lookup with external identifier fallback).
    /// 3. Commits all EventKit deletions in a single batch.
    /// 4. Deletes the sync record JSON file for the rule.
    /// 5. Removes the rule from UserDefaults.
    ///
    /// If a blocker event is no longer found in EventKit (e.g., the user already
    /// deleted it manually), it is silently skipped. The sync record file and
    /// rule entry are always cleaned up regardless of individual blocker deletion
    /// outcomes.
    ///
    /// - Parameters:
    ///   - id: The UUID of the rule to remove.
    ///   - syncRecordStore: The store managing per-rule sync record files.
    ///   - calendarService: The calendar service used for EventKit operations.
    /// - Returns: A tuple containing the removed rule and the count of blocker events
    ///   successfully deleted from the target calendar.
    /// - Throws: `RuleStoreError.ruleNotFound` if no rule with the given id exists.
    ///   EventKit or file system errors from cleanup operations are also propagated.
    @discardableResult
    public func removeRuleWithCleanup(
        id: UUID,
        syncRecordStore: SyncRecordStore,
        calendarService: CalendarService
    ) throws -> (rule: MirrorRule, blockersRemoved: Int) {
        try removeRuleWithCleanup(id: id, syncRecordStore: syncRecordStore, calendarAccess: calendarService)
    }

    /// Internal adapter overload lets cleanup recovery be tested without EventKit.
    @discardableResult
    func removeRuleWithCleanup(
        id: UUID,
        syncRecordStore: SyncRecordStore,
        calendarAccess: any CalendarAccess
    ) throws -> (rule: MirrorRule, blockersRemoved: Int) {
        let lock = try acquireMutationLock()
        defer { lock.release() }
        defer { calendarAccess.releaseEventHandles() }

        // Verify the rule exists before performing cleanup.
        guard let rule = try loadRulesChecked().first(where: { $0.id == id }) else {
            throw RuleStoreError.ruleNotFound(id)
        }
        guard let targetCalendar = calendarAccess.calendarDescriptor(withIdentifier: rule.targetCalendarIdentifier) else {
            throw NSError(domain: "CalMirror.RuleCleanup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The rule's target calendar is unavailable; cleanup was not started."
            ])
        }

        // Step 1: Load sync records for this rule.
        let records = try syncRecordStore.loadRecordsChecked(for: id)
        let otherOwners = try syncRecordStore.blockerIdentifiersOwned(byRulesOtherThan: id)
        guard !records.contains(where: {
            otherOwners.local.contains($0.blockerEventIdentifier)
                || otherOwners.external.contains($0.blockerExternalIdentifier)
        }) else {
            throw NSError(domain: "CalMirror.RuleCleanup", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "A recorded blocker is also owned by another rule; cleanup was not started."
            ])
        }

        // Step 2: Delete each managed blocker event from EventKit.
        var blockersRemoved = 0
        for record in records {
            do {
                switch try calendarAccess.resolveBlocker(for: record, in: targetCalendar) {
                case .found(let blockerEvent):
                    try calendarAccess.deleteEvent(blockerEvent, commit: false)
                    blockersRemoved += 1
                case .missing:
                    continue
                case .foreign, .untagged, .ambiguous:
                    throw NSError(domain: "CalMirror.RuleCleanup", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "A recorded blocker could not be verified as managed in the target calendar; rule data was retained."
                    ])
                }
            } catch {
                // Resolution itself may fail after earlier deletes were staged.
                // Reset all staged edits so another caller cannot accidentally commit them.
                calendarAccess.discardPendingChanges()
                throw error
            }
        }

        // Step 3: Commit all pending EventKit deletions in one batch.
        if blockersRemoved > 0 {
            do {
                try calendarAccess.commitChanges()
            } catch {
                calendarAccess.discardPendingChanges()
                throw error
            }
        }

        // Step 4: Delete the sync record JSON file.
        try syncRecordStore.deleteRecords(for: id)

        // Step 5: Remove the rule from UserDefaults.
        let removedRule = try removeRuleWithoutLock(id: id)

        return (rule: removedRule, blockersRemoved: blockersRemoved)
    }

    // MARK: - Toggle Operations

    /// Enables a rule by setting `isEnabled` to `true` and updating the timestamp.
    ///
    /// - Parameter id: The UUID of the rule to enable.
    /// - Throws: `RuleStoreError.ruleNotFound` if no rule with the given id exists.
    public func enableRule(id: UUID) throws {
        try setEnabled(true, for: id)
    }

    /// Disables a rule by setting `isEnabled` to `false` and updating the timestamp.
    ///
    /// - Parameter id: The UUID of the rule to disable.
    /// - Throws: `RuleStoreError.ruleNotFound` if no rule with the given id exists.
    public func disableRule(id: UUID) throws {
        try setEnabled(false, for: id)
    }

    /// Applies the shared read-modify-write sequence used by both toggle actions.
    private func setEnabled(_ enabled: Bool, for id: UUID) throws {
        let lock = try acquireMutationLock()
        defer { lock.release() }
        var rules = try loadRulesChecked()
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw RuleStoreError.ruleNotFound(id)
        }
        rules[index].isEnabled = enabled
        rules[index].updatedAt = Date()
        try persistRules(rules)
    }
}
