## [Unreleased]

- Wake the reactor when workers return reusable connections or free connection
  capacity, removing the dependency on the 50 ms housekeeping poll.
- Disable Nagle's algorithm on accepted TCP sockets to reduce delays between
  separate response header and body writes.
- Rename the distribution to `spinel-spinner` while retaining `require "spinner"`
  and the `Spinner` namespace.

## [0.1.0.pre.1] - 2026-10-28

- Prepare the first public preview of the packaged Spinel HTTP server.
- Parse bracketed Forwarded IPv6 addresses without storing a MatchData value,
  avoiding a Spinel C type mismatch when compiled with Hamster.

## [0.1.0] - 2026-10-18

- Initial release
