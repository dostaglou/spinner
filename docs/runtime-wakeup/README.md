# Spinel GC wakeup investigation checkpoint

This folder preserves the runtime patch and regression sources used to diagnose
occasional 51 ms stalls in Spinner and Hamster health benchmarks. The fix belongs
to Spinel's scheduler, not Spinner's Ruby reactor. It targets runtime revision
`10f112c51`; it has not been installed globally or published.

## Cause and fix

`sp_ev_worker_wait` releases the scheduler lock for a zero-timeout event drain.
A collector can raise the GC barrier and send a kick while that drain runs.
The drain consumes the kick, and after reacquiring the lock the caller can
enter a blocking event wait without checking the raised barrier. The collector
then waits for that worker to park, while it waits for another event or the
runtime's 50 ms backstop.

`gc-before-event-wait.patch` checks `g_stw_active` under the scheduler lock
before blocking. Returning lets the caller's loop park at the barrier. It
retains the event backend and its existing backstop.

Source: <https://github.com/matz/spinel/blob/10f112c51/lib/sp_sched.c>.

## Regression sources

- `reactor_probe.rb` runs the real Spinner reactor/parser/pool/writer over
  duplex pipes for 9,000 serial requests. Client and server threads share a
  compiled runtime, so this diagnoses scheduling rather than HTTP capacity.
- `guard_regression.c` is a deterministic macOS boundary test. Build it with
  `-DSP_THREADS -DTEST_SCHED_SOURCE='"/absolute/path/to/lib/sp_sched.c"'`
  and the matching runtime headers. It includes the scheduler implementation;
  replace `sp_sched.o` in a **test copy** of the matching threaded archive with
  this object and link a small threaded Ruby program using that copy. The
  constructor checks the raised-barrier state without waiting on wall time:
  original source exits 98 with `GC_WAIT_GUARD_FAILED`; patched source prints
  `GC_WAIT_GUARD_OK` and lets the program run normally.

To run the pipe reproducer from the Spinner repository with a patched compiler:

```sh
mkdir -p tmp
/path/to/patched/spinel docs/runtime-wakeup/reactor_probe.rb \
  --require-gate -I lib -o tmp/gc-reactor-probe
env -u SPINEL_SCHED_POLL SPINEL_WORKERS=4 SPINEL_GC_STATS=1 \
  SPINEL_GC_PHASES=1 SPINEL_SCHED_STATS=1 tmp/gc-reactor-probe
```

Inspect the request counts, GC barrier park time and event backstop expiries
together; latency outliers alone do not establish this defect.

## Validation at this checkpoint

- Rebuilt original scheduler: 18 slow requests in 9,000, 0.916 seconds waiting
  for GC parking, 19 backstop expiries. Instrumentation confirms entry into a
  blocking event wait with the barrier already active.
- Deterministic regression fails on original source and passes on patched source.
- Six patched pipe runs at worker settings 1, 4 and 8: 54,000 correct requests,
  zero requests over 20 ms, zero backstop expiries, 0.001–0.002 seconds of GC
  park waiting per run. A separate preliminary low-worker run had other latency
  outliers without backstop expiries; this is not a claim of zero host jitter.
- Twelve focused runtime tests and Spinner's reactor handoff fixture pass.
- Patched HTTP health servers, default event backend, five rounds of 10,000
  requests per app and mode: 200,000 successes, zero requests over 10 ms.
  Median untraced RPS: Spinner 8,897, Hamster 8,337. Tracing slightly lowers RPS.

## Concurrent validation and pause point

Performance is no longer a blocker as of 2026-10-29; further investigation is
paused at the user's request.

The patched HTTP servers were also checked without tracing at concurrency 24
and 48, alongside Sinatra. At concurrency 48, five rounds of 100,000 requests
per app completed all 1.5 million requests successfully:

| App | Median RPS | p99 ms | Maximum ms |
|---|---:|---:|---:|
| Spinner | 14,588 | 8.566 | 133.712 |
| Hamster | 13,943 | 8.622 | 126.020 |
| Sinatra | 9,261 | 10.162 | 165.971 |

Throughput was essentially flat versus concurrency 24. Longer pauses appeared
in groups of 48 outstanding requests across all three apps. Client GC is a
hypothesis because the Ruby runner retains 1.5 million sample records; server
GC and host scheduling have not been excluded. These tails are distinct from
the earlier regular 51 ms stall population and remain unattributed.

The matching patched runtime and separately built candidate server executables
remain local benchmark artifacts. The globally installed runtime has not been
replaced, and no release or upstream change has been published. Spinner's
5 ms reactor interval remains the experimental setting saved in this checkpoint.
The runtime patch is preserved here for later review and integration.

Deferred work, if needed: attribute the long-run tails using client GC/memory
and server barrier/backstop counters; run Linux/epoll and the full upstream
suite before a general runtime release. HTTP measurements here are closed-loop
latency tests, not fixed-arrival-rate capacity measurements.
