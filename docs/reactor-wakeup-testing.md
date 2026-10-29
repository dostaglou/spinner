# Reactor wakeup candidate: testing handoff

This working-tree candidate implements Plan A from `tmp/plans.md`. It keeps the
50 ms housekeeping interval, connection limits, TCP options, response writer,
and public server configuration unchanged. No gem has been published or globally
installed, and the Hamster benchmark application has not been changed.

## Implementation

Each reactor owns a nonblocking pipe, created before its application workers.
Workers publish reusable clients under the existing pool mutex, then signal the
pipe outside that mutex. Buffered and asynchronous completions use the same
operation. Closing a worker-owned connection also signals, so a reactor that
excluded its listener at full capacity can resume accepting promptly.

The reactor always selects the notification reader. It drains notifications
before inspecting completions and capacity: a publication after that drain
leaves a readable token for the next select. A full pipe coalesces notifications;
the completion queue remains the source of truth. No pending flag or busy polling
is used. Both ends are close-on-exec, and producers are stopped/joined before the
reactor closes the pipe. Partial worker startup also cleans up its producers.

Signal handlers retain their existing bounded polling behavior; they do not
acquire a new mutex or write to the notifier. Request-body storage retains its
separate existing polling path.

## Verification in this session

- Final focused run: **12 tests, 37 assertions, zero failures/errors**, including
  the two existing proxy-metadata unit tests. Scenario assertions inside the
  CRuby/native subprocess fixtures are additional checks beyond that count.
- Focused notifier tests cover notification before/during select, full-pipe
  coalescing, concurrent producers, interrupted syscalls, EOF, descriptor closure
  and partial pool startup failure.
- The real reactor/parser/pool handoff fixture runs under both CRuby 3.4.9 and
  compiled Spinel `2026.09.12+11846 (10f112c51)`. The native test builds and
  extracts the actual gem before compiling, catching packaging omissions.
- That fixture uses duplex pipes and a deliberately long **1-second test-only
  poll interval**. It exercises serial reuse at limits 100 and 125, pipelining,
  finite streaming, concurrent completions, completion before select, capacity
  release, application/stream errors, disconnect, graceful/forced shutdown and
  idle non-spinning behavior. These are scheduling tests, not TCP benchmarks.
- A negative-control copy with worker notifications disabled failed the handoff
  assertion under both runtimes, taking about **0.98 seconds** to hand back the
  connection. The normal candidate passes with the same long poll interval.
- The packaged basic server, complete framework fixture, native component
  fixture and handoff fixture compile. Native components execute successfully.
- The full socket suite is **not verified here**. A baseline attempt was blocked
  before server readiness: CRuby reports `EPERM` on localhost bind, while the
  native server reports connection refused. The TCP/TLS, network lifecycle and
  soak checks below must run in a normal local terminal.
- Targeted lint reports four existing warnings in `reactor.rb`/`thread_pool.rb`
  (overlapping exception classes and broad worker-join rescue). No new lint
  warnings remain. `git diff --check` passes.

Focused output is in `tmp/wakeup-focused.log`. Local build artifacts, verification
output and source hashes are in `tmp/wakeup-candidate/`. The candidate archive
retains the development version `0.1.0.pre.1`; **do not push it as that already
published version**. Use a local source override for application testing.

## Spinner checks to run before benchmarking

From `spinner/`, run the full packaged suite and soak:

```sh
rbenv exec bundle exec rake test
rbenv exec bundle exec rake soak
```

The full suite includes the new TCP serial keep-alive test, which reads each
response before issuing the next request, verifies closure after request 100,
and then opens a fresh connection. Existing coverage checks TLS, streaming,
WebSockets, backpressure, descriptor exhaustion, graceful shutdown and worker
process restart. The soak checks include bounded descriptors/memory.

To run just the new tests:

```sh
rbenv exec bundle exec ruby -Itest -e 'require_relative "test/reactor_wakeup_test"; require_relative "test/reactor_handoff_test"'
```

Do not report a successful compile as a successful live server test. Keep any
failures and process logs; diagnose them before publishing a release.

## Hamster benchmark integration for Luna

1. Read the benchmark app's `AGENTS.md`. Use an isolated copy of the app and keep
   the original report and executable available as the baseline. Keep the same
   database/data, app environment, compiler and worker/thread settings.
2. In that copy, change the existing Spinner Gemfile entry to a path dependency
   on this checkout. For an app directly under `benchmarks/`, use:

   ```ruby
   gem "spinel-spinner", "= 0.1.0.pre.1", path: "../../spinner", require: "spinner"
   ```

   This satisfies Hamster's current version pin while selecting the modified
   source. Do not edit the globally installed gem. If the copy is elsewhere,
   adjust the path accordingly.
3. From the isolated app, run:

   ```sh
   rbenv exec bundle install
   rbenv exec bundle info spinel-spinner
   rbenv exec ruby bin/hamster build
   PORT=4001 rbenv exec ruby bin/hamster serve
   ```

   Confirm `bundle info` resolves to the modified checkout. Hamster's builder
   passes that gem's `lib` path to Spinel. Rebuilding is essential: restarting an
   old executable will still run the old server. Record the source diff/revision,
   compiler version, selected path and resulting binary hash.
4. Before scoring results, make the independent benchmark-harness corrections
   listed in `tmp/plans.md`: disable Net::HTTP retries, reject missing samples,
   and use a consistent documented batch timing boundary. Those changes are
   intentionally left for the benchmark work. Rerun baseline and candidate with
   the same corrected harness.
5. From the workspace root, with the original Rails/Sinatra servers running:

   ```sh
   rbenv exec ruby benchmarks/performance.rb --requests 1000 --warmup 200 --rounds 3 --concurrency 1 --order-seed 135649634500837374213775538725808562773 --hamster-url http://127.0.0.1:4001 --report-dir benchmarks/reports/spinner-wakeup
   ```

   Check response parity and all sample counts, and compare first/reused
   connections as well as overall median/p95/p99. The primary expectation is
   removal of latency caused by waiting for the reactor poll. Repeat at
   concurrency 4 and 16 after checking serial latency; concurrency can mask a
   missing wakeup through unrelated socket activity.
6. If a roughly 50/100 ms population remains, retain the report and investigate
   the separate TCP-buffering hypothesis from Plan B. Do not combine TCP changes
   with this candidate before measuring it, or infer a Rails speedup from the
   isolated pipe fixture.

After the live suite and application measurements pass, prepare a new Spinner
prerelease and update Hamster's dependency pin as a separate release change.
