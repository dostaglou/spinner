# HTTP/1.1 coverage ledger

Reference: installed Puma **8.0.2**, pinned in Gemfile.lock. Source review covers
`lib/puma/client.rb` (body IO/tempfiles), `server.rb` and `request.rb`
(response execution), `dsl.rb` (remote addresses/configuration), and `minissl.rb`
(TLS). Shared valid wire behavior is compared directly with Puma by
`puma_comparison_test.rb`; Spinner does not claim full Rack or Puma parity.

| Capability | Implementation | Native/socket verification |
| --- | --- | --- |
| Packaging/basic startup | Native Spinel, call(env), separate basic fixture | Build/unpack/compile/start gate |
| IO input | Binary memory/file backends, sized/full/output-buffer reads, gets/each/rewind/close | Native component probe; binary HTTP and file-backed incremental consume |
| Body limits/spill | Fixed and chunked share BodyStorage; private exclusive files | Below/exact/above threshold, configured maximum, binary upload, pipeline boundaries |
| Storage admission | Bounded disk workers/queue and aggregate disk budget; paused reads | Budget exhaustion, unavailable directory, partial upload EOF/timeout/shutdown cleanup |
| Responses | Header arrays, owned framing, HEAD, enumerables, close | Repeated cookies, exact decoded bytes, invalid responses, enumeration failure, disconnect |
| Streams | Separate bounded pool and idle watchdog; finite reuse | Output before completion, saturation 503, healthy app worker while streaming, stream pipeline, idle closure |
| HTTP parsing | OPTIONS/star, absolute forms, field-aware duplicates | Smuggling cases, authority conflict, repeated ordinary fields, header/body deadlines |
| Proxy metadata | Peer IP, trusted IPv4/IPv6 CIDRs, validated Forwarded chain | Native IPv6 network probe, direct trusted/untrusted/malformed/chained metadata, Nginx forwarding |
| Upgrades/WebSockets | Core transport handoff; optional framed adapter | Fragmented text, binary, ping/pong, masking rejection, close, oversized header rejection, session limit, shutdown accounting, Nginx handoff |
| TLS | Lazy FFI setup, 1.2–1.3, HTTP/1.1 ALPN, key matching | Verified clients, both TLS versions, stalled peers, invalid credentials, HTTP/2-only ALPN rejection, certificate replacement on HUP |
| Supervision | Worker replacement, rolling restart, storm limit, parent monitoring | Kill and observe replacement, observe all rolled PIDs, kill supervisor, restart storm |
| Operations | Connection/queue bounds, drain deadline, accept backoff, structured metrics | Queue pressure, slow clients, descriptor exhaustion/recovery, active-request drain, closed idle clients |
| Resources | Incremental spooling and explicit cleanup | Soak: repeated traffic/restarts, descriptors, 24 MiB incremental upload and RSS growth ceiling |

Intentional stricter policies: framing and Host duplicates are always rejected;
no request trailers; only the listed methods; absolute target scheme must match
the socket; response header names must be lowercase. Forwarded trust is a
Spinner policy rather than an imitation of Puma's configurable header mode.

Release evidence is recorded from the local macOS Spinel environment. The
manual GitHub Actions workflow provisions Ubuntu, Nginx, OpenSSL, and a pinned
Spinel compiler; its first hosted Linux run remains pending. Actual
disk-full/permission fault injection, sustained
slow-reader fairness across many connections, and extended restart/resource
soaks remain additional production gates. A configured budget failure is not
proof of OS-level ENOSPC handling. Network deadlines cannot safely preempt
arbitrary application code. No production-readiness claim follows from startup
or accepted configuration keywords alone.
