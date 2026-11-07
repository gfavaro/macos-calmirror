# EventKit integration check

The integration test is opt-in and creates two UUID-named temporary calendars
in the user's iCloud account. Explicitly opt in to iCloud writes before running it. It
removes both calendars after the assertions, including via fallback cleanup if
an assertion or operation fails.

Run it with:

```sh
CALMIRROR_RUN_EVENTKIT_INTEGRATION=1 CALMIRROR_ALLOW_ICLOUD_TEST_CALENDARS=1 swift test --filter EventKitIntegrationTests
```

The test exercises real EventKit create/update/delete commits, confirms that
`EKEventStore.reset()` discards staged create/update/delete changes, and injects
a mapping-file write failure after a successful calendar commit to verify that a
later run adopts the committed blocker without duplicating it.

EventKit does not provide a deterministic way to force a provider-side commit
failure. This integration test therefore does not claim to validate the result
of a genuinely failed or uncertain remote commit. The fake adapter tests cover
those engine branches.
