# ZigNexa

ZigNexa is a lightweight HTTP framework facade over the pinned [httpz.zig](https://github.com/karlseguin/http.zig) server. It targets Zig 0.15.2 and keeps request dispatch, path matching, and middleware traversal in httpz.

## Goals and status

The current implementation provides a small Context API, common HTTP method routes with `:param` paths, route groups, and ordered middleware. It favors static handler and middleware callbacks and registration-time composition.

Current limitations:

- The ZigNexa route facade supports GET, POST, PUT, PATCH, DELETE, HEAD, and OPTIONS. Trace, CONNECT, and arbitrary extension methods remain available through the re-exported `httpz` module.
- httpz returns 404 for unmatched routes; its current router does not expose a 405 method negotiation hook to ZigNexa.
- ZigNexa does not yet expose custom not-found/error-handler registration. Unhandled returned errors become 500 responses in httpz; use `Recovery` to control the response body.
- Recovery catches returned Zig errors only. It cannot catch panics.
- Timeout middleware is not provided. httpz does not expose per-request cancellation for this synchronous callback chain.
- Middleware and routes must be registered before serving. Group middleware applies to routes registered after that middleware is added.
- The default listener binds to localhost. `Run` also binds to localhost; use `init` with an explicit `httpz.Config` to bind another address.

## Requirements

- Zig 0.15.2
- The exact httpz dependency pinned in `build.zig.zon`

The repository uses Zig's package manager. Run `zig build --fetch` when the dependency is not already present in the local package cache.

## Build and test

```sh
zig version
zig fmt build.zig src/
zig build
zig build test
zig build run
```

The tests are registered through the `test` step in `build.zig`. They cover global/group/route middleware registration order, route parameter matching, Context query and response helpers, continuation, recovery, CORS preflight, and request ID validation.

## Hello World

The public module import name is `zignexa`:

```zig
const ZigNexa = @import("zignexa");

pub fn main() !void {
    var app = ZigNexa.Default();
    app.GET("/", home);
    try app.Run(8080);
}

fn home(c: *ZigNexa.Context) !void {
    try c.String(200, "Hello from ZigNexa!");
}
```

`Default` uses `std.heap.page_allocator`. For explicit allocator ownership, initialize an app with `App.init(allocator, httpz_config)`, then call `listen` and `deinit` yourself.

## Routing and Context

ZigNexa exposes `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, and `OPTIONS`, with fallible `try*` forms. These methods are also available on route groups. Handlers receive a request-scoped `*Context`:

```zig
app.GET("/users/:id", getUser);

fn getUser(c: *ZigNexa.Context) !void {
    const id = c.Param("id");
    const page = (try c.Query("page")) orelse "1";
    c.Header("Cache-Control", "no-store");
    try c.JSON(200, .{ .id = id, .page = page });
}
```

`Param` returns an empty string if the name is absent. `Query` returns an optional request-lifetime slice and can fail while httpz parses the query. Request headers are read with `RequestHeader` (use lowercase names). `Header` adds a response header. `String` sets a text response, and `JSON` serializes a value using Zig's JSON formatter.

The `httpz` request and response are exposed as `Context.request` and `Context.response` for advanced use. Those pointers and their data are valid only while the request is being handled.

## Route groups

Groups prepend a prefix and can add middleware:

```zig
var api = app.Group("/api/v1");
api.Use(authenticate);
api.GET("/health", health);
```

Middleware added to the group runs after app middleware and before route-local middleware. Add it before registering routes. Prefix joining handles a single slash at the boundary.

Route-local middleware can be created and passed as handles:

```zig
const auth = try app.createMiddleware(authenticate);
app.GETWithMiddleware("/private", privateHandler, &.{auth});
```

The app owns each middleware implementation and releases it on `deinit` or when `Run` returns. Do not retain a middleware handle after its app is deinitialized.

## Middleware

Middleware has the signature `fn (*Context) !void`. Call `try c.Next()` to continue; return without calling `Next` to stop dispatch. A middleware that calls `Next` more than once is not supported by httpz's executor. Composition follows registration order and uses httpz's executor without allocating a chain per request. Route middleware arrays are assembled during registration.

Global middleware runs in registration order, followed by group middleware, route middleware, and the handler. Register global middleware before routes so each route receives it. Global middleware is also used for unmatched requests through httpz's not-found execution path.

```zig
app.Use(ZigNexa.middleware.Logger);
app.Use(ZigNexa.middleware.Recovery);
app.Use(ZigNexa.middleware.RequestID);
```

Built-ins:

- `Logger` logs method, path, final response status, and elapsed monotonic nanoseconds. Put `Recovery` after it so returned errors become 500 before the logger records the result.
- `Recovery` catches returned errors from downstream middleware or handlers and replaces the response with plain-text 500. It does not catch panics.
- `RequestID` preserves a valid incoming `X-Request-ID` (1–128 ASCII alphanumeric, `-`, `_`, `.`, or `:` characters). Invalid or missing values are replaced with 128-bit random hex and returned as `X-Request-ID`. Treat client-provided IDs as correlation labels, not trusted identity.
- `cors(config)` performs exact origin matching, adds configured allow headers, and answers OPTIONS requests that include `Access-Control-Request-Method` with 204. A single `"*"` origin allows all origins; credentials are omitted for wildcard policy.

Example CORS configuration:

```zig
app.Use(ZigNexa.middleware.cors(.{
    .origins = &.{"https://example.com"},
    .methods = "GET, OPTIONS",
    .headers = "Content-Type, X-Request-ID",
    .max_age_seconds = 600,
    .allow_credentials = true,
}));
```

## Error handling

Handlers and middleware return Zig error unions. httpz propagates returned errors through the executor; its server responds with status 500 if they remain uncaught. Add `Recovery` to replace that default response body. Zig panics are not recoverable through this middleware. Avoid returning an error after committing a response with direct lower-level `httpz.Response.write` calls.

## Complete example

This complete application is also in `src/main.zig`:

```zig
const ZigNexa = @import("zignexa");

pub fn main() !void {
    var app = ZigNexa.Default();
    app.Use(ZigNexa.middleware.Logger);
    app.Use(ZigNexa.middleware.Recovery);
    app.Use(ZigNexa.middleware.RequestID);
    app.GET("/", home);
    app.GET("/users/:id", getUser);
    var api = app.Group("/api/v1");
    api.GET("/health", health);
    try app.Run(8080);
}

fn home(c: *ZigNexa.Context) !void {
    try c.String(200, "Hello from ZigNexa!");
}

fn getUser(c: *ZigNexa.Context) !void {
    try c.JSON(200, .{ .id = c.Param("id"), .name = "Ahmed" });
}

fn health(c: *ZigNexa.Context) !void {
    try c.JSON(200, .{ .status = "ok" });
}
```

## Project structure

```text
build.zig                 Build, run, and test steps
build.zig.zon             Zig version floor and pinned httpz dependency
src/root.zig              Public zignexa module
src/app.zig               Server lifecycle, routes, and global middleware
src/context.zig           Request and response helpers
src/handler.zig           httpz handler/middleware adapters
src/route_group.zig       Prefix routes and group middleware
src/middleware.zig        Logger, recovery, CORS, request IDs
src/main.zig              Runnable example
```

## Development

Keep changes compatible with Zig 0.15.2 and the pinned httpz commit. Add behavior tests alongside the relevant module, format with `zig fmt build.zig src/`, and run both `zig build` and `zig build test`. Update this README when behavior or public signatures change. Prefer small changes that use httpz's actual router and executor instead of duplicating request dispatch.

## Security

- Validate and bound application input before using it. `Param` and `Query` return untrusted request data.
- Configure CORS origins narrowly. CORS is a browser policy, not authentication.
- Request IDs are for correlation only. The middleware accepts safe client-provided IDs but replaces malformed values.
- Use TLS at an appropriate deployment boundary; this framework currently provides a plain HTTP listener through httpz.
- Avoid exposing internal error details to clients. `Recovery` deliberately returns a generic message.

## Performance

Route and middleware composition happens during registration. The request path delegates to httpz and does not allocate middleware-chain storage per request. `Query` may trigger lazy parsing, JSON responses serialize into httpz's request-scoped response buffer, and request IDs allocate 16 bytes of request-arena storage for generated IDs.

No benchmark results are claimed. A future benchmark should compare the same handler and payload against the pinned httpz server in ReleaseFast mode, report request rate and latency distributions, and include the exact command and hardware. The current `benchmarks/` directory is not present.

## Roadmap

- Expose POST/PUT/PATCH/DELETE and other httpz methods through ZigNexa's Context API.
- Add a configurable 404 handler and method-aware 405 responses if supported cleanly by httpz.
- Add integration tests for real response serialization and CORS preflight requests.
- Evaluate request cancellation support before considering timeout middleware.
- Add reproducible performance benchmarks.
