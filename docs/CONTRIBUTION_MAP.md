# Contribution map

The fork contains the complete integrated app on `main`. It builds and runs
without waiting for upstream changes. The PRs below are optional contributions
to `gravitek-io/macos-calmirror:main`. They are ready for review.

| Change | Request | Draft PR | Local validation |
|---|---|---|---|
| Chaining control | [#12](https://github.com/gravitek-io/macos-calmirror/issues/12) | [#26](https://github.com/gravitek-io/macos-calmirror/pull/26) | 96 tests passed |
| Sync interval | [#16](https://github.com/gravitek-io/macos-calmirror/issues/16) | [#27](https://github.com/gravitek-io/macos-calmirror/pull/27) | 98 tests passed |
| Rule management UI | [#19](https://github.com/gravitek-io/macos-calmirror/issues/19) | [#28](https://github.com/gravitek-io/macos-calmirror/pull/28) | 92 tests passed |
| Checked storage reads | [#22](https://github.com/gravitek-io/macos-calmirror/issues/22) | [#29](https://github.com/gravitek-io/macos-calmirror/pull/29) | 94 tests passed |
| Process lock | [#23](https://github.com/gravitek-io/macos-calmirror/issues/23) | [#30](https://github.com/gravitek-io/macos-calmirror/pull/30) | 96 tests passed |
| Activity polling | [#24](https://github.com/gravitek-io/macos-calmirror/issues/24) | [#31](https://github.com/gravitek-io/macos-calmirror/pull/31) | 95 tests completed, one skipped |
| Calendar and planner boundary | [#25](https://github.com/gravitek-io/macos-calmirror/issues/25) | [#32](https://github.com/gravitek-io/macos-calmirror/pull/32) | 100 tests passed |
| CLI and release contracts | [#25](https://github.com/gravitek-io/macos-calmirror/issues/25) | [#33](https://github.com/gravitek-io/macos-calmirror/pull/33) | 92 tests passed; release and contract checks passed |

## Review history

The recovery review is [gfavaro/macos-calmirror#1](https://github.com/gfavaro/macos-calmirror/pull/1).
It targets `review/sync-recovery-base` in the fork. That branch combines upstream
PRs #26, #29, #30, #31, and #32. This keeps the recovery review limited to its
engine and cleanup changes. It covers requests #20 and #21 and completes the
mapping-read work in #22. Its tests include SIGKILL before a mapping checkpoint.

The final integration branch, `fix/connect-contributed-features`, targets
`review/ui-integration-base`. It connects chaining controls and checked reads
to the new UI and split CLI. It also adds the schedule page to the sidebar.
The combined tree passed 144 tests with two opt-in cases skipped. The release
build, metadata check, help/version snapshots, and whitespace check passed.

The fork can develop and release independently. Future upstream contributions
can use these review branches as references. Visual UI checks and a real
provider commit failure remain outside automated coverage.

EventKit notification triggers remain a proposal in
[request #18](https://github.com/gravitek-io/macos-calmirror/issues/18).
