# Code and performance audit — September 2026

The audit covered all implementation modules: Core process execution, SVN
commands/parsers/models, App state/services/views, Finder integration, Agent,
cross-process coordination, and local build/CI configuration. The baseline was
`d3513f2bb6cd5057558ca3c6d688984187b60b1b`.

## Changes

- Cancel obsolete diff requests when the selected file, working copy or tab
  changes; isolate directory retries from late errors; clear stale diff
  presentations and statistics.
- Read root metadata when registering a working-copy subdirectory. Update the
  service cache after registry persistence succeeds.
- Reuse status array storage, precomputed counts and compact diff row indices.
  Compute commit selection summaries only when their inputs change. Remove
  unused status UI components and retained Agent preflight data.
- Filter historical paths off the main actor, propagate cancellation, honor
  updated preferred paths and retain recently used diffs in the bounded cache.
- Reuse XML date formatters within each parse, scan diff lines without a full
  normalized copy, construct SVN targets directly in `Data`, and drain
  autoreleased URL temporaries after each target.
- Accept the registered root's physical spelling for missing/deleted absolute
  paths without relaxing component boundary checks. This handles macOS's
  inconsistent `/private/tmp` alias normalization when a file disappears.
- Preserve complete raw patches when malformed ranges, integer overflow or
  multiple file sections cannot be represented safely.
- Reuse unchanged Finder snapshots, serialize reloads, and avoid re-registering
  unchanged roots. Remove completed duplicate queue files and isolate corrupt
  receipts without blocking unrelated commands.
- Run blocking process I/O outside the cooperative executor, handle closed
  stdin without terminating the App, and escalate cancellation to SIGKILL after
  a grace period when the direct child ignores SIGTERM.
- Resolve the Swift package explicitly in the local builder so it works when
  invoked outside the repository.

## Measurements

These are synthetic microbenchmarks on the same Apple Silicon Mac, not a claim
about overall application RSS or a universal minimum memory footprint.

Core measurements use `swiftc -O -swift-version 6
-strict-concurrency=complete -warnings-as-errors`. Each baseline/current pair
was run alternately three times in fresh processes; the table reports medians.
Elapsed time excludes fixture construction. Peak RSS includes the entire
benchmark process, including its fixture. MB uses decimal units.

| Fixture | Baseline time | Updated time | Baseline peak RSS | Updated peak RSS |
| --- | ---: | ---: | ---: | ---: |
| 5,000 log entries with fractional dates | 0.737 s | 0.182 s | 10.7 MB | 10.1 MB |
| 100,000 added CRLF diff lines | 0.144 s | 0.050 s | 101.2 MB | 78.4 MB |
| 60,000 commit targets under an existing root | 1.493 s | 1.218 s | 166.2 MB | 30.6 MB |

[CoreBenchmark.swift](CoreBenchmark.swift) contains the fixtures;
[core-results.json](core-results.json) records every measured run. Compile the
benchmark with `Models.swift`, `SVNRevisionDetails.swift`,
`SVNCommandBuilder.swift`, `ProcessRunner.swift`, `SVNXMLParser.swift` and
`UnifiedDiffParser.swift` from the desired revision, then run it with `xml`,
`diff` or `targets`. A writable `-module-cache-path` is needed in a sandbox.

Separate App storage checks used 100,000 clean or modified statuses and 100,000
paired replacement rows. They count unique array buffers as
`capacity × element stride`, excluding referenced string storage and the rest
of the application:

| Storage | Baseline | Updated | Reduction |
| --- | ---: | ---: | ---: |
| Status snapshot entry arrays | 40,795,800 B | 12,009,360 B | 70.6% |
| Two flattened diff presentation arrays | 50,331,512 B | 12,582,800 B | 75.0% |

## Verification and limits

The final all-product release build passed Swift 6 complete concurrency checks
with warnings treated as errors. Eight App regressions, five Finder cache
regressions, the complete Core smoke suite and four new queue scenarios passed.
A fresh local SVN repository also passed a 4,100-file single-transaction commit
and 600-file missing-addition cleanup with versioned-file protection.
The local builder completed when invoked from outside the repository; the App
and embedded Finder extension passed signature validation before and after ZIP
extraction. All ten plist/entitlement files passed syntax validation.

The App and Finder regression scripts run without XCTest:

```sh
bash Scripts/test-app-regressions.sh
bash Scripts/test-finder-regressions.sh
```

Core and queue regressions are included in `SvnDockCoreSmoke`. The same App and
Finder checks also have XCTest wrappers for full Xcode installations. This
machine's Command Line Tools do not include XCTest, so `swift test` reports
`no such module 'XCTest'`; the full XCTest suite was not run here.

The process layer still captures complete stdout/stderr, and raw diff copying
retains complete patch text. Memory therefore scales with result size. These
changes reduce duplication and abandoned work without silently truncating SVN
results. Descendants retaining inherited pipes are not covered by the direct
child's cancellation bound. Whole-app Instruments profiling, long-duration
usage, and interactive Finder/UI validation remain outside these measured
results.
