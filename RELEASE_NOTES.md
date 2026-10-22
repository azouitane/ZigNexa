# ZigNexa v0.1.1

Patch release for Zig 0.15.2. This release updates application lifecycle and
registration behavior, vendors the pinned httpz dependency with local listener
startup cleanup fixes, and replaces the previous examples with a basic server
example.

## Changes

- Vendor the exact httpz revision previously pinned by ZigNexa, so package
  builds use the included source. The vendored source adds cleanup for the
  listener and initialized workers when listener startup fails.
- Store route metadata and route paths in the httpz server's startup arena,
  validate supported methods before registration, preserve global/group/route
  middleware ordering, and reject global middleware registration after routes.
- Keep app ownership with the caller after `Run`/`listen`; callers stop serving
  and deinitialize the app after listener and serving threads have finished.
- Add `Context.HeaderCopy` and `Context.StringCopy` for response values that
  need copying into request response storage.
- Replace the hello-world and CRUD examples with `examples/basic.zig` and the
  root `example`, `run-example`, and `run` build steps.
- Add tests for allocation failures, registration and middleware behavior,
  request helpers, and live HTTP lifecycle and routing behavior.

## Tests and example

The repository test suite includes allocation failure, registration and
middleware behavior, request helper, and live HTTP lifecycle/routing tests.
The release checks are:

```sh
zig fmt --check build.zig src/ examples/
zig build
zig build test
zig build example
git diff --check
```

The basic server example listens on localhost port 8080 and can be built with
`zig build example` or run with `zig build run-example`.

## Known limitations

- Unsupported methods and unmatched routes use httpz's 404 behavior; 405
  negotiation and custom not-found handlers are not provided.
- Recovery handles returned errors, not panics.
- TLS, asynchronous handlers, and per-request timeout/cancellation are not
  provided.
