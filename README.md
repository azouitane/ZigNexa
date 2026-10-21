# ZigNexa

ZigNexa is a small HTTP framework for Zig 0.15.2, built on the pinned
[httpz.zig](https://github.com/karlseguin/http.zig) server. It provides a
Context-based handler API, route groups, and ordered middleware while leaving
socket handling and route dispatch to httpz.

## Current release

| Stable | Latest |
| --- | --- |
| `v0.1.0` | `v0.1.0` |

## Requirements and status

- Zig 0.15.2 or newer within the supported API range.
- The `httpz` dependency is pinned in `build.zig.zon` and resolved automatically
  by Zig's package manager.
- Implemented: GET, POST, PUT, PATCH, DELETE, HEAD and OPTIONS routes, `:param`
  paths, query and request header access, response headers, text and JSON
  responses, groups, middleware, 404 responses, and returned-error handling.
- Not implemented: 405 method negotiation, custom not-found callbacks, TLS,
  asynchronous handlers, per-request timeout/cancellation, and arbitrary panic
  recovery. httpz returns 404 for unmatched method/path combinations.

## Installation

From a Zig 0.15.2 project:

1. Add ZigNexa as a dependency in `build.zig.zon`:

   ```bash
   zig fetch --save "git+https://github.com/azouitane/ZigNexa#v0.1.0"
   ```

2. Import the dependency in `build.zig`, after defining `exe`:

   ```zig
   const zignexa = b.dependency("zignexa", .{
       .target = target,
       .optimize = optimize,
   });

   // Add ZigNexa to the executable's root module.
   exe.root_module.addImport("zignexa", zignexa.module("zignexa"));
   ```

The package name and exported module are both `zignexa`. The dependency wires
`httpz` into the public module, so no separate `httpz` import is needed. Import
the library with:

```zig
const std = @import("std");
const zignexa = @import("zignexa");
```

## Hello World

```zig
const zignexa = @import("zignexa");

pub fn main() !void {
    var app = try zignexa.App.init(std.heap.page_allocator, .{ .address = .localhost(8080) });
    defer app.deinit();
    try app.tryGET("/", home);
    try app.listen();
}

fn home(c: *zignexa.Context) !void {
    try c.String(200, "Hello, world!");
}
```

The equivalent runnable example is in `examples/hello-world/src/main.zig`.

## CRUD example

`examples/crud` is a small runnable users API built through the public
`@import("zignexa")` module. It uses an in-memory, fixed-size collection; all
users are lost when the server restarts, so this storage is not suitable for
production persistence.

```text
examples/crud/
├── build.zig
├── build.zig.zon
└── src/main.zig
```

From the repository root, build the example against the local library source
and run it at `http://localhost:8080`:

```bash
zig build crud-example
zig build run-crud
```

To build independently against the `v0.1.0` package tag, run from
`examples/crud`:

```bash
zig build
zig build run
```

The endpoints return JSON. Create and update requests take a JSON object with a
non-empty `name` of at most 64 bytes. Invalid IDs or bodies return 400; absent
users return 404.

| Method | Endpoint | Behavior |
| --- | --- | --- |
| GET | `/users` | List all users |
| GET | `/users/:id` | Retrieve a user |
| POST | `/users` | Create a user (201) |
| PUT | `/users/:id` | Replace a user's name |
| DELETE | `/users/:id` | Delete a user |

With the server running, try:

```bash
curl http://localhost:8080/users
curl -X POST http://localhost:8080/users -H 'content-type: application/json' -d '{"name":"Ada"}'
curl http://localhost:8080/users/1
curl -X PUT http://localhost:8080/users/1 -H 'content-type: application/json' -d '{"name":"Grace"}'
curl -X DELETE http://localhost:8080/users/1
```

Example create request and response:

```json
{"name":"Ada"}
```

```json
{"id":1,"name":"Ada"}
```

## Routes and context

`App.init(allocator, httpz_config)` initializes the listener and framework
storage. `deinit` releases it. Routes and middleware should be registered
before `listen`. Capitalized convenience methods panic on registration
allocation errors; use the `try*` variants for explicit error handling.

```zig
try app.tryGET("/users/:id", getUser);
try app.tryPOST("/users", createUser);

fn getUser(c: *zignexa.Context) !void {
    const id = c.Param("id");
    const page = (try c.Query("page")) orelse "1";
    const agent = c.RequestHeader("user-agent") orelse "unknown";
    c.Header("Cache-Control", "no-store");
    try c.JSON(200, .{ .id = id, .page = page, .agent = agent });
}
```

The other supported route helpers are `tryPUT`, `tryPATCH`, `tryDELETE`,
`tryHEAD`, and `tryOPTIONS`; corresponding capitalized wrappers are also
available. `Param` returns an empty slice for an absent key. `Query` returns an
optional request-lifetime slice and can return a parsing error. Request header
names use httpz's lowercase lookup convention. `String` writes plain text;
`JSON` serializes using Zig's JSON support. The request, response, and their
data are valid only while handling that request.

## Route groups

Groups prepend a prefix and can register middleware:

```zig
var api = app.Group("/api/v1");
try api.tryUse(authenticate);
try api.tryGET("/health", health);
```

Groups and their middleware storage are app-owned. Add group middleware before
registering routes. For route-local middleware, create a middleware handle
with `app.createMiddleware(callback)` and pass it to `GETWithMiddleware` or
`Handle`; the app owns the handle until `deinit`.

## Middleware

Middleware has signature `fn (*Context) !void`. Call `try c.Next()` to run the
next middleware or handler; returning without calling `Next` short-circuits.
The order is global middleware in registration order, then group middleware in
registration order, then route middleware in supplied order, then the handler.
Register app-wide middleware before routes. Middleware runs on the httpz
request callback; calling `Next` more than once is unsupported.

```zig
try app.tryUse(zignexa.middleware.Logger);
try app.tryUse(zignexa.middleware.Recovery);
try app.tryUse(zignexa.middleware.RequestID);
try app.tryUse(zignexa.middleware.cors(.{
    .origins = &.{"https://example.com"},
    .methods = "GET, POST, OPTIONS",
    .headers = "Content-Type, X-Request-ID",
}));
```

- `Logger` reports method, path, final status, and elapsed monotonic time. Put
  `Recovery` after it so errors are converted before logging completes.
- `Recovery` catches returned Zig errors and sends a generic text 500. It cannot
  recover from panics or process-level failures.
- `RequestID` validates an incoming `X-Request-ID` (1–128 permitted ASCII
  characters), or generates a random 128-bit hexadecimal ID, then returns it in
  the response header. IDs are correlation labels, not authentication.
- `cors(config)` uses exact origin matching, supports `"*"`, and answers
  preflight OPTIONS requests with 204. Credentials are not emitted for wildcard
  origins. Configure origins narrowly; CORS is not access control.

There is no timeout middleware because this synchronous API has no per-request
cancellation contract.

## Errors and HTTP behavior

Handler and middleware errors propagate through httpz. If no `Recovery`
middleware catches them, httpz returns a server error response. Unmatched
routes and unsupported methods return httpz's 404 response; ZigNexa does not
currently distinguish 405. Avoid returning errors after writing directly to
the lower-level response stream. ZigNexa does not provide TLS; deploy behind a
TLS-capable proxy or listener boundary appropriate to your application.

## Build, test, and run examples

```sh
zig version
zig fmt build.zig src/ examples/
zig build
zig build test
zig build example
zig build crud-example
zig build run
```

`zig build example` builds and installs the example binary. `zig build run`
starts it on localhost port 8080 (`zig build run-example` is an equivalent
alias). Run build commands from the repository root. Tests cover Context helpers,
route parameter registration, middleware ordering and short-circuiting,
returned errors, CORS, and request IDs.

## Architecture

- `src/root.zig`: public `zignexa` module.
- `src/app.zig`: app lifecycle, route registration, global middleware.
- `src/context.zig`: request-scoped accessors and response helpers.
- `src/handler.zig`: adapters to httpz callbacks and executor.
- `src/route_group.zig`: prefixed registrations and group middleware.
- `src/middleware.zig`: Logger, Recovery, RequestID, and CORS.
- `examples/hello-world/src/main.zig`: runnable example application.

Route and middleware composition happens during registration. Request and
response lifetimes remain owned by httpz; the app arena holds route and
registration data until `deinit`. Do not retain Context or request slices past
the handler call.

## Development and contributions

Use Zig 0.15.2, preserve the pinned httpz revision, format changed Zig files,
and run `zig build` and `zig build test`. Update this README when changing
public behavior or signatures. Keep changes focused on httpz's existing
router/executor model.

## Security

Validate untrusted path and query values before using them. Restrict CORS
origins, do not treat request IDs as trusted identity, and avoid exposing
internal errors. Use an appropriate TLS boundary for production traffic.

## Versioning and release

ZigNexa follows semantic versioning. `v0.1.0` is the initial stable release
and latest release. Breaking API changes before `1.0.0` may require a minor
version bump. The existing `v0.1.0` tag is immutable; these working-tree
changes do not retag or publish a release.

## License

ZigNexa is distributed under the MIT License. See [LICENSE](LICENSE).
