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

Run `zig fmt --check build.zig src/ examples/hello-world/src/main.zig`,
`zig build`, `zig build test`, and `zig build example` with Zig 0.15.2 before
publishing. The repository's existing `v0.1.0` tag must be checked against the
release commit before any push; do not overwrite a published tag.
