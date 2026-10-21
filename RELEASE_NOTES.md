# ZigNexa v0.1.0

Initial public release of ZigNexa, a lightweight HTTP framework for Zig 0.15.2
built on the pinned `httpz` server.

## Included

- Public `zignexa` module with `App`, `Context`, and middleware exports.
- GET, POST, PUT, PATCH, DELETE, HEAD, and OPTIONS route registration, including
  path parameters and prefixed route groups.
- Request query/header access and plain-text/JSON response helpers.
- Global, group, and route middleware with continuation and short-circuiting.
- Logger, returned-error Recovery, RequestID, and CORS middleware.
- Build, test, and Hello World example steps.

## Known limitations

- Unsupported methods and unmatched routes use httpz's 404 behavior; 405
  negotiation and custom not-found handlers are not provided.
- Recovery handles returned errors, not panics.
- TLS, asynchronous handlers, and per-request timeout/cancellation are not
  provided.

## Release validation

Verified with Zig 0.15.2 using `zig fmt build.zig src/ examples/`, `zig build`,
`zig build test`, `zig build example`, and `zig build crud-example`. The
standalone CRUD package also builds against `v0.1.0`. The repository's existing
annotated `v0.1.0` tag must be checked against the release commit before any
push; never overwrite it.
