# Spinner

Spinner is a native Spinel HTTP/1.1 server. An application implements `call(env)`
and returns `[status, headers, body]`. Compile the application with the packaged
library, then run the resulting executable:

```ruby
require "spinner"

class Application
  def call(env)
    [200, {"content-type" => "text/plain"}, ["Hello"]]
  end
end

Spinner::Server.new(Application.new, host: "127.0.0.1", port: 4000).run
```

```sh
spinel app.rb --require-gate -I lib -o app
./app
```

The environment includes request method, path, query, protocol, validated Host,
content headers, normalized `HTTP_*` headers, `REMOTE_ADDR`, `rack.url_scheme`,
and binary `rack.input`. Input supports `read(length = nil, buffer = nil)`,
`gets`, `each`, `rewind`, and `close`. Dispatch waits for the complete request
body. Input and temporary storage belong to the request and are closed when its
response finishes. Calling `read` without a length explicitly allocates the
remaining body; consume with sized reads to keep application memory bounded.

Headers use lowercase names and string or string-array values. Arrays emit
separate fields, including `set-cookie`. Response framing belongs to Spinner.
An array body produces a Content-Length response; an enumerable body streams
with HTTP/1.1 chunking (HTTP/1.0 streams close the connection). HEAD closes the
body without enumerating streams. Finite HTTP/1.1 streams preserve keep-alive
and pipelining. Body `close` runs after completion, errors, or disconnection.

| Option | Default | Behavior |
| --- | --- | --- |
| `max_body_bytes` | 1 MiB | Decoded body limit for both framing modes; overflow returns 413 |
| `body_memory_bytes` | 64 KiB | Spill threshold, between zero and body limit |
| `spool_directory` | `TMPDIR` or `/tmp` | Exclusive binary files, mode 0600 |
| `spool_budget_bytes` | 128 MiB | Aggregate server disk budget; divided evenly across worker processes |
| `storage_workers` | 2 | Disk workers per process; socket reads pause during pending writes |
| `max_header_bytes` | 32 KiB | Request header limit |
| `header_timeout`, `body_timeout`, `write_timeout` | 5 seconds each | Ordinary network deadlines |
| `stream_idle_timeout` | 30 seconds | Stream/upgrade transport idle deadline, refreshed on progress |
| `max_streams`, `max_upgrades` | 32 each | Separate execution/admission limits per process; excess returns 503 before headers |
| `trusted_proxies` | `[]` | IPv4/IPv6 CIDRs allowed to supply standardized Forwarded metadata |
| `threads`, `queue_capacity`, `max_connections` | 4, 64, 128 | Application workers, queued work, accepted connections per process |
| `queue_timeout`, `keepalive_timeout` | 5 seconds each | Admission wait and idle connection deadlines |
| `max_requests_per_connection` | 100 | Keep-alive request ceiling |
| `drain_timeout` | 10 seconds | Shutdown deadline |
| `worker_processes` | 1 | Supervised TCP workers; HUP rolls them one at a time |
| `reactor_heartbeat` | `false` | Emit the once-per-second `SPINNER_METRIC event=reactor` snapshot |
| `request_metrics` | `false` | Emit routine `queued`, `start`, and `finish` request metrics |
| `unix_path`, `listener` | `nil` | Unix socket or supplied listener, mutually exclusive |
| `tls_cert`, `tls_key` | `nil` | PEM chain/key pair for TCP TLS |

Spool exhaustion and filesystem failures return 503 and release storage.
Transport, application, stream, storage, admission, worker, TLS, and shutdown
metrics go to stderr as `SPINNER_METRIC event=...` records. Unix sockets have
an empty remote address. Forwarded fields are ignored for untrusted immediate
peers. Trusted chains are validated in full, then walked from the nearest peer
until the first untrusted address. Malformed chains do not change identity or
scheme; X-Forwarded-* fields never change them.

The periodic reactor heartbeat and routine request metrics are disabled by
default. Enable them in Ruby with `reactor_heartbeat: true` and
`request_metrics: true`, or with `SPINNER_REACTOR_HEARTBEAT=1` and
`SPINNER_REQUEST_METRICS=1`. Request metrics include queue admission and
worker/stream lifecycle events; failure, rejection, worker, and shutdown
metrics remain enabled.

TLS loads libssl when requested, checks chain/key loading and key matching,
permits TLS 1.2/1.3, and selects only `http/1.1` via ALPN. Clients can omit ALPN.
Set `SPINNER_SSL_LIBRARY` to a matching OpenSSL shared library if needed.

TERM/INT stop admission, close idle and partial clients, and allow active work
to finish within the drain deadline. HUP in multiprocess mode rolls workers.
Unexpected worker exits trigger replacement; more than five unexpected exits
in ten seconds stop the supervisor. Workers detect parent death. Network
timeouts do not safely interrupt arbitrary application or enumerator code.
A timed-out enumerator retains its bounded execution slot until it returns or
the worker exits. Recover stuck application code by replacing the process.
Abruptly killing an unsupervised process can leave a named spool file; a
supervisor removes its dead workers' spool files.

Optional WebSockets use the bundled adapter:

```ruby
require "spinner/websocket"

class Echo
  def call(session)
    message = session.read_message # [opcode, binary bytes], or nil after close
    session.write_message(message[0], message[1]) unless message.nil?
    session.close
  end
end

class Application
  def call(env)
    [101, {"upgrade" => "websocket"}, Echo.new]
  end
end

application = Spinner::WebSocket::Adapter.new(Application.new,
  max_message_bytes: 1048576, idle_timeout: 30.0)
Spinner::Server.new(application).run
```

The adapter validates handshakes before application dispatch, bounds messages,
validates masking and UTF-8 text, reassembles fragmentation, handles ping/pong,
and exchanges close frames. It does not negotiate extensions or subprotocols.
The core upgrade API accepts `[101, headers, Spinner::Upgrade.new { |transport,
buffered_bytes| ... }]`. The callback owns the transport until it returns;
Spinner keeps the connection counted and closes it on return or shutdown.

Supported methods are GET, HEAD, POST, PUT, PATCH, DELETE, and OPTIONS, including
`OPTIONS *`. Absolute targets must match Host and transport scheme. TRACE and
CONNECT are disabled. Duplicate Host/framing/singleton fields, normalization
collisions, trailers, and ambiguous framing are rejected. Ordinary repeated
fields combine with commas; Cookie uses semicolons. Routing, multipart/form
parsing, authentication, and middleware belong to the application. Full Rack
compatibility, HTTP/2, mTLS, SNI certificate selection, early hints, sendfile,
and Puma CLI parity remain outside this contract.

The reference dependency is **Puma 8.0.2**. Tests build and unpack the gem,
compile basic startup and native component probes separately from the expanded
application fixture, and exercise native executables over sockets:

For a package-level preview, build and install the gem, then compile with the
installed library path. Spinel is a separate compiler prerequisite:

```sh
gem build spinel-spinner.gemspec
gem install --local spinel-spinner-0.1.0.pre.1.gem
spinel app.rb --require-gate -I "$(ruby -e 'puts Gem::Specification.find_by_name("spinel-spinner").full_gem_path')/lib" -o app
```

The gem is named `spinel-spinner`; application code uses `require "spinner"`
and the `Spinner` namespace. In a Gemfile, use
`gem "spinel-spinner", require: "spinner"` when using Bundler's automatic requires.

The installed gem provides Ruby source to the compiler; it does not provide a
precompiled server executable. Applications still require a Spinel compilation
step for their own entrypoint.

```sh
bundle install
bundle exec rake test
bundle exec rake soak
```

The GitHub Actions workflow is manual-only for now. It uses a GitHub-hosted
Ubuntu runner, installs the native test tools, and builds a pinned Spinel
revision. Select **Run workflow** in the Actions tab; enable the `soak` input to
run the longer resource and restart checks. Locally, provide Spinel, a C
compiler, OpenSSL, and Nginx on `PATH`. `KEEP_SPINNER_TEST_ARTIFACTS=1` retains
build and process artifacts; failed startup/process logs are retained
automatically. See
[test/COVERAGE.md](test/COVERAGE.md) for evidence and remaining release gates.
