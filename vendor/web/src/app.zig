//! Server lifecycle: listener, accept loop, bounded worker pool, graceful
//! drain, signal handling, periodic jobs, and health counters.
//!
//! This is the one copy of the skeleton that applications previously
//! hand-rolled per repo. The accept task either queues a connection or
//! answers 503 immediately — it never blocks and never drops silently. A
//! stalled peer costs one worker for at most the idle timeout. Shutdown
//! stops accepting, drains queued and in-flight connections up to a
//! deadline, then force-closes stragglers and reports that it had to.

const std = @import("std");
const web_server = @import("web_server");
const web_router = @import("web_router");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    ListenFailed,
    ForcedShutdown,
    AlreadyRunning,
    TooManyJobs,
};

pub const Counters = struct {
    connections_accepted: u64 = 0,
    requests: u64 = 0,
    responses_5xx: u64 = 0,
    queue_rejections: u64 = 0,
    forced_closes: u64 = 0,
};

pub const RequestLog = struct {
    method: std.http.Method,
    target: []const u8,
    status: std.http.Status,
    duration_ns: u64,
};

pub const JobContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *App,

    pub fn stopping(context: *const JobContext) bool {
        return context.app.stopping.load(.acquire);
    }
};

pub const Job = struct {
    name: []const u8,
    interval_ms: u64,
    run: *const fn (context: *JobContext) anyerror!void,
};

pub const RequestContext = struct {
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    io: std.Io,
    app: *App,
    peer_address: std.Io.net.IpAddress,
};

pub const Options = struct {
    address: std.Io.net.IpAddress,
    workers: ?usize = null,
    queue_depth: ?usize = null,
    connection: web_server.ConnectionOptions = .{},
    idle_timeout_ms: u64 = 15_000,
    drain_timeout_ms: u64 = 10_000,
    healthz: bool = true,
    /// Called with every lifecycle anomaly; the lifecycle itself never prints.
    on_error: *const fn (err: anyerror, note: []const u8) void,
    on_request: ?*const fn (log: RequestLog) void = null,
};

/// The signal handler must be async-signal-safe: it stores a flag and calls
/// shutdown(2) on the listener so the blocked accept returns. Everything else
/// happens on ordinary threads.
var signal_listener_socket: std.atomic.Value(i64) = .init(-1);
var signal_requested: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    signal_requested.store(true, .release);
    const handle = signal_listener_socket.load(.acquire);
    if (handle >= 0) {
        _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
    }
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    queue: std.Io.Queue(std.Io.net.Stream),
    queue_buffer: []std.Io.net.Stream,
    workers: []?std.Thread,
    /// One slot per worker: the fd it is currently serving, -1 when idle.
    /// Force-close during drain shuts these down to unblock stalled reads.
    active_sockets: []std.atomic.Value(i64),
    /// True while the worker is inside a handler (not waiting between
    /// keep-alive requests). Drain closes idle connections immediately and
    /// only in-handler connections wait for the deadline.
    active_in_handler: []std.atomic.Value(bool),
    job_slots: [max_jobs]?Job = @splat(null),
    job_threads: [max_jobs]?std.Thread = @splat(null),
    job_count: usize = 0,
    job_mutex: std.Io.Mutex = .init,
    job_condition: std.Io.Condition = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    in_flight: std.atomic.Value(usize) = .init(0),
    queued: std.atomic.Value(usize) = .init(0),
    drain_mutex: std.Io.Mutex = .init,
    drain_condition: std.Io.Condition = .init,
    bound_port: std.atomic.Value(u16) = .init(0),
    counter_accepted: std.atomic.Value(u64) = .init(0),
    counter_requests: std.atomic.Value(u64) = .init(0),
    counter_5xx: std.atomic.Value(u64) = .init(0),
    counter_rejections: std.atomic.Value(u64) = .init(0),
    counter_forced: std.atomic.Value(u64) = .init(0),

    const max_jobs = 8;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Error!App {
        const worker_count = options.workers orelse @max(@as(usize, 4), std.Thread.getCpuCount() catch 4);
        if (worker_count == 0) return Error.Unsupported;
        const depth = options.queue_depth orelse worker_count * 8;
        const queue_buffer = gpa.alloc(std.Io.net.Stream, depth) catch return Error.OutOfMemory;
        errdefer gpa.free(queue_buffer);
        const workers = gpa.alloc(?std.Thread, worker_count) catch return Error.OutOfMemory;
        errdefer gpa.free(workers);
        @memset(workers, null);
        const active_sockets = gpa.alloc(std.atomic.Value(i64), worker_count) catch return Error.OutOfMemory;
        errdefer gpa.free(active_sockets);
        for (active_sockets) |*slot| slot.* = .init(-1);
        const active_in_handler = gpa.alloc(std.atomic.Value(bool), worker_count) catch return Error.OutOfMemory;
        errdefer gpa.free(active_in_handler);
        for (active_in_handler) |*slot| slot.* = .init(false);
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .queue = .init(queue_buffer),
            .queue_buffer = queue_buffer,
            .workers = workers,
            .active_sockets = active_sockets,
            .active_in_handler = active_in_handler,
        };
    }

    pub fn deinit(app: *App) void {
        app.gpa.free(app.active_in_handler);
        app.gpa.free(app.active_sockets);
        app.gpa.free(app.workers);
        app.gpa.free(app.queue_buffer);
        app.* = undefined;
    }

    /// Register a periodic job before `run`. The job thread sleeps on a
    /// condition, so shutdown interrupts it immediately and idle costs nothing.
    pub fn addJob(app: *App, job: Job) Error!void {
        if (app.running.load(.acquire)) return Error.AlreadyRunning;
        if (app.job_count == max_jobs) return Error.TooManyJobs;
        app.job_slots[app.job_count] = job;
        app.job_count += 1;
    }

    pub fn boundPort(app: *App) u16 {
        return app.bound_port.load(.acquire);
    }

    pub fn counters(app: *App) Counters {
        return .{
            .connections_accepted = app.counter_accepted.load(.monotonic),
            .requests = app.counter_requests.load(.monotonic),
            .responses_5xx = app.counter_5xx.load(.monotonic),
            .queue_rejections = app.counter_rejections.load(.monotonic),
            .forced_closes = app.counter_forced.load(.monotonic),
        };
    }

    pub fn requestShutdown(app: *App) void {
        _ = app;
        signal_requested.store(true, .release);
        const handle = signal_listener_socket.load(.acquire);
        if (handle >= 0) {
            _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
        }
    }

    /// Serve until SIGTERM/SIGINT (or `requestShutdown`), then drain.
    /// Returns Error.ForcedShutdown when the drain deadline forced closes.
    pub fn run(
        app: *App,
        comptime Ctx: type,
        ctx: Ctx,
        handler: *const fn (Ctx, *RequestContext) anyerror!void,
    ) Error!void {
        signal_requested.store(false, .release);
        app.stopping.store(false, .release);
        app.running.store(true, .release);
        defer app.running.store(false, .release);

        var listener = app.options.address.listen(app.io, .{ .reuse_address = true }) catch {
            return Error.ListenFailed;
        };
        defer listener.deinit(app.io);
        app.bound_port.store(listener.socket.address.getPort(), .release);
        defer app.bound_port.store(0, .release);
        signal_listener_socket.store(@intCast(listener.socket.handle), .release);
        defer signal_listener_socket.store(-1, .release);

        var old_interrupt: std.posix.Sigaction = undefined;
        var old_terminate: std.posix.Sigaction = undefined;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, &old_interrupt);
        std.posix.sigaction(.TERM, &action, &old_terminate);
        defer {
            std.posix.sigaction(.INT, &old_interrupt, null);
            std.posix.sigaction(.TERM, &old_terminate, null);
        }

        const Bridge = struct {
            fn workerEntry(
                app_pointer: *App,
                context: Ctx,
                request_handler: *const fn (Ctx, *RequestContext) anyerror!void,
                index: usize,
            ) void {
                app_pointer.workerLoop(Ctx, context, request_handler, index);
            }
        };

        var started: usize = 0;
        errdefer {
            app.stopping.store(true, .release);
            app.queue.close(app.io);
            for (app.workers[0..started]) |*slot| {
                if (slot.*) |thread| thread.join();
                slot.* = null;
            }
        }
        for (app.workers, 0..) |*slot, index| {
            slot.* = std.Thread.spawn(.{}, Bridge.workerEntry, .{ app, ctx, handler, index }) catch {
                return Error.Unsupported;
            };
            started += 1;
        }
        for (app.job_slots[0..app.job_count], 0..) |slot, index| {
            if (slot) |job| {
                app.job_threads[index] = std.Thread.spawn(.{}, jobLoop, .{ app, job }) catch {
                    return Error.Unsupported;
                };
            }
        }

        // The accept loop needs a real unit of concurrency: with inline
        // execution the signal wait below would never be reached on 1-core
        // hosts, and the process would ignore TERM until a connection arrived.
        var accept_group: std.Io.Group = .init;
        accept_group.concurrent(app.io, acceptLoop, .{ app, &listener }) catch {
            app.options.on_error(Error.Unsupported, "no unit of concurrency for the accept loop; configure a threaded Io with a higher async limit");
            app.stopping.store(true, .release);
            app.queue.close(app.io);
            for (app.workers) |*slot| {
                if (slot.*) |thread| thread.join();
                slot.* = null;
            }
            app.stopJobs();
            return Error.Unsupported;
        };
        defer accept_group.cancel(app.io);

        // Wait for shutdown: the signal handler shuts the listener down, the
        // accept loop observes it and signals this condition. No polling.
        app.drain_mutex.lockUncancelable(app.io);
        while (!app.stopping.load(.acquire)) {
            app.drain_condition.waitUncancelable(app.io, &app.drain_mutex);
        }
        app.drain_mutex.unlock(app.io);
        accept_group.cancel(app.io);

        // Drain: closing the queue lets workers finish the backlog, then exit
        // on error.Closed. Wait on completion signals up to the deadline.
        app.queue.close(app.io);
        var forced = false;
        const deadline_ns: u64 = app.options.drain_timeout_ms * std.time.ns_per_ms;
        var waited_ns: u64 = 0;
        app.drain_mutex.lockUncancelable(app.io);
        while (app.in_flight.load(.acquire) > 0 or app.queued.load(.acquire) > 0) {
            // Idle keep-alive connections (worker parked between requests)
            // close immediately: nothing is in flight on them, and waiting
            // out the deadline for an idle socket would stall every
            // shutdown. Re-scanned each slice because a worker may still be
            // finishing response bookkeeping when the drain begins.
            for (app.active_sockets, app.active_in_handler) |*socket_slot, *in_handler| {
                const handle = socket_slot.load(.acquire);
                if (handle >= 0 and !in_handler.load(.acquire)) {
                    _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
                }
            }
            if (waited_ns >= deadline_ns) {
                forced = true;
                break;
            }
            const slice_ns: u64 = 50 * std.time.ns_per_ms;
            app.drain_condition.waitTimeout(app.io, &app.drain_mutex, .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(slice_ns) }, .clock = .awake } }) catch {};
            waited_ns += slice_ns;
        }
        app.drain_mutex.unlock(app.io);

        if (forced) {
            for (app.active_sockets) |*slot| {
                const handle = slot.load(.acquire);
                if (handle >= 0) {
                    _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
                    _ = app.counter_forced.fetchAdd(1, .monotonic);
                }
            }
        }
        for (app.workers) |*slot| {
            if (slot.*) |thread| thread.join();
            slot.* = null;
        }
        app.stopJobs();
        return if (forced) Error.ForcedShutdown else {};
    }

    fn stopJobs(app: *App) void {
        app.job_mutex.lockUncancelable(app.io);
        app.job_condition.broadcast(app.io);
        app.job_mutex.unlock(app.io);
        for (&app.job_threads) |*slot| {
            if (slot.*) |thread| thread.join();
            slot.* = null;
        }
    }

    fn acceptLoop(app: *App, listener: *std.Io.net.Server) void {
        while (!signal_requested.load(.acquire)) {
            const stream = listener.accept(app.io) catch |err| {
                if (signal_requested.load(.acquire)) break;
                app.options.on_error(err, "accept failed");
                if (err == error.Canceled) break;
                continue;
            };
            _ = app.counter_accepted.fetchAdd(1, .monotonic);
            _ = app.queued.fetchAdd(1, .acq_rel);
            const put = app.queue.put(app.io, &.{stream}, 0) catch 0;
            if (put == 0) {
                // Queue full or closed: bounded, explicit backpressure. The
                // silent alternative (dropping the connection) reads as a
                // network failure to the client and hides overload from the
                // operator.
                _ = app.queued.fetchSub(1, .acq_rel);
                _ = app.counter_rejections.fetchAdd(1, .monotonic);
                app.writeBusy(stream);
            }
        }
        app.beginStopping();
    }

    fn beginStopping(app: *App) void {
        app.stopping.store(true, .release);
        app.drain_mutex.lockUncancelable(app.io);
        app.drain_condition.broadcast(app.io);
        app.drain_mutex.unlock(app.io);
    }

    fn writeBusy(app: *App, stream: std.Io.net.Stream) void {
        const busy_response = "HTTP/1.1 503 Service Unavailable\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 8\r\n" ++
            "Retry-After: 1\r\n" ++
            "Connection: close\r\n\r\noverload";
        var buffer: [busy_response.len]u8 = undefined;
        var writer = stream.writer(app.io, &buffer);
        writer.interface.writeAll(busy_response) catch {};
        writer.interface.flush() catch {};
        stream.close(app.io);
    }

    fn workerLoop(
        app: *App,
        comptime Ctx: type,
        ctx: Ctx,
        handler: *const fn (Ctx, *RequestContext) anyerror!void,
        index: usize,
    ) void {
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        while (true) {
            const stream = app.queue.getOneUncancelable(app.io) catch break;
            _ = app.queued.fetchSub(1, .acq_rel);
            _ = app.in_flight.fetchAdd(1, .acq_rel);
            app.active_sockets[index].store(@intCast(stream.socket.handle), .release);
            app.serveStream(Ctx, ctx, handler, stream, &arena_state, index);
            app.active_sockets[index].store(-1, .release);
            app.active_in_handler[index].store(false, .release);
            _ = app.in_flight.fetchSub(1, .acq_rel);
            app.drain_mutex.lockUncancelable(app.io);
            app.drain_condition.broadcast(app.io);
            app.drain_mutex.unlock(app.io);
        }
    }

    fn serveStream(
        app: *App,
        comptime Ctx: type,
        ctx: Ctx,
        handler: *const fn (Ctx, *RequestContext) anyerror!void,
        stream: std.Io.net.Stream,
        arena_state: *std.heap.ArenaAllocator,
        worker_index: usize,
    ) void {
        defer stream.close(app.io);

        const Wrapper = struct {
            app_pointer: *App,
            context: Ctx,
            request_handler: *const fn (Ctx, *RequestContext) anyerror!void,
            arena: *std.heap.ArenaAllocator,
            peer: std.Io.net.IpAddress,

            fn handle(wrapper: @This(), request: *std.http.Server.Request) anyerror!void {
                const wrapped_app = wrapper.app_pointer;
                defer _ = wrapper.arena.reset(.{ .retain_with_limit = 256 * 1024 });
                _ = wrapped_app.counter_requests.fetchAdd(1, .monotonic);
                var request_context: RequestContext = .{
                    .arena = wrapper.arena.allocator(),
                    .request = request,
                    .io = wrapped_app.io,
                    .app = wrapped_app,
                    .peer_address = wrapper.peer,
                };
                const started = std.Io.Timestamp.now(wrapped_app.io, .awake);
                if (wrapped_app.options.healthz and request.head.method == .GET and
                    std.mem.eql(u8, requestPath(request.head.target), "/healthz"))
                {
                    try wrapped_app.respondHealthz(&request_context);
                } else {
                    wrapper.request_handler(wrapper.context, &request_context) catch |err| {
                        _ = wrapped_app.counter_5xx.fetchAdd(1, .monotonic);
                        wrapped_app.options.on_error(err, request.head.target);
                        respondServerError(request) catch {};
                        return;
                    };
                }
                if (wrapped_app.options.on_request) |on_request| {
                    const finished = std.Io.Timestamp.now(wrapped_app.io, .awake);
                    on_request(.{
                        .method = request.head.method,
                        .target = request.head.target,
                        // The lifecycle does not parse the response the
                        // handler wrote; applications that need exact status
                        // logging record it in their handler.
                        .status = .ok,
                        .duration_ns = @intCast(@max(0, started.durationTo(finished).nanoseconds)),
                    });
                }
            }
        };
        const wrapper: Wrapper = .{
            .app_pointer = app,
            .context = ctx,
            .request_handler = handler,
            .arena = arena_state,
            .peer = stream.socket.address,
        };

        var request_buffer: [16 * 1024]u8 = undefined;
        var response_buffer: [16 * 1024]u8 = undefined;
        var connection_reader = stream.reader(app.io, &request_buffer);
        var connection_writer = stream.writer(app.io, &response_buffer);

        // The per-connection loop lives here (not in web_server) because the
        // idle gate below must run before every blocking receive: socket
        // timeouts (SO_RCVTIMEO) are not an option, the std Io treats EAGAIN
        // from a blocking socket as a bug.
        var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);
        var handled: usize = 0;
        const maximum_requests = app.options.connection.maximum_requests;
        while (handled < maximum_requests) {
            app.active_in_handler[worker_index].store(false, .release);
            if (connection_reader.interface.bufferedLen() == 0) {
                if (!app.waitReadable(stream)) return;
            }
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                error.HttpHeadersOversize => {
                    web_server.writeHeaderTooLarge(&connection_writer.interface) catch {};
                    return;
                },
                error.ReadFailed => return,
                else => {
                    app.options.on_error(err, "receive head");
                    return;
                },
            };
            app.active_in_handler[worker_index].store(true, .release);
            handled += 1;
            if (handled == maximum_requests) request.head.keep_alive = false;
            Wrapper.handle(wrapper, &request) catch |err| switch (err) {
                error.ReadFailed, error.WriteFailed, error.EndOfStream => return,
                else => {
                    app.options.on_error(err, "connection loop");
                    return;
                },
            };
            if (!request.head.keep_alive) return;
        }
    }

    /// Idle gate: true when the socket has readable data (or closed input —
    /// the receive path handles that), false when `idle_timeout_ms` passed
    /// with nothing to read. A stalled or idle peer therefore costs one
    /// worker at most the idle timeout, without violating the blocking-socket
    /// contract of the Io implementation.
    fn waitReadable(app: *App, stream: std.Io.net.Stream) bool {
        const timeout_ms = app.options.idle_timeout_ms;
        if (timeout_ms == 0) return true;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = @intCast(stream.socket.handle),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, @intCast(@min(timeout_ms, std.math.maxInt(i32) - 1))) catch return false;
        return ready > 0;
    }

    fn respondHealthz(app: *App, context: *RequestContext) !void {
        if (!isLoopback(context.peer_address)) {
            try context.request.respond("{\"error\":\"forbidden\"}", .{
                .status = .forbidden,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        const snapshot = app.counters();
        var body_buffer: [512]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buffer,
            "{{\"status\":\"ok\",\"accepted\":{d},\"requests\":{d},\"responses_5xx\":{d},\"queue_rejections\":{d},\"forced_closes\":{d}}}",
            .{ snapshot.connections_accepted, snapshot.requests, snapshot.responses_5xx, snapshot.queue_rejections, snapshot.forced_closes },
        ) catch unreachable;
        try context.request.respond(body, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }

    fn jobLoop(app: *App, job: Job) void {
        var context: JobContext = .{ .gpa = app.gpa, .io = app.io, .app = app };
        app.job_mutex.lockUncancelable(app.io);
        while (!app.stopping.load(.acquire)) {
            app.job_mutex.unlock(app.io);
            job.run(&context) catch |err| app.options.on_error(err, job.name);
            app.job_mutex.lockUncancelable(app.io);
            if (app.stopping.load(.acquire)) break;
            const interval_ns: i96 = @intCast(job.interval_ms * std.time.ns_per_ms);
            app.job_condition.waitTimeout(app.io, &app.job_mutex, .{ .duration = .{ .raw = .{ .nanoseconds = interval_ns }, .clock = .awake } }) catch {};
        }
        app.job_mutex.unlock(app.io);
    }
};

/// Routed dispatch over a comptime-validated table. `Route` needs `method`,
/// `pattern`, and a `handler: *const fn (Ctx, *RequestContext, web_router.Params) anyerror!void`
/// field. `fallback` answers not-found and method-not-allowed.
pub fn runRouted(
    app: *App,
    comptime Route: type,
    comptime routes: []const Route,
    comptime Ctx: type,
    ctx: Ctx,
    fallback: *const fn (Ctx, *RequestContext, web_router.Result(Route)) anyerror!void,
) Error!void {
    comptime web_router.validateRoutes(Route, routes);
    const Dispatch = struct {
        context: Ctx,
        fallback_handler: *const fn (Ctx, *RequestContext, web_router.Result(Route)) anyerror!void,

        fn handle(dispatch: @This(), request_context: *RequestContext) anyerror!void {
            const path = requestPath(request_context.request.head.target);
            const result = web_router.match(Route, routes, request_context.request.head.method, path);
            switch (result) {
                .matched => |matched| try matched.route.handler(dispatch.context, request_context, matched.params),
                .method_not_allowed, .not_found => try dispatch.fallback_handler(dispatch.context, request_context, result),
            }
        }
    };
    const dispatch: Dispatch = .{ .context = ctx, .fallback_handler = fallback };
    return app.run(Dispatch, dispatch, Dispatch.handle);
}

fn requestPath(target: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query];
}

fn respondServerError(request: *std.http.Server.Request) !void {
    try request.respond("internal error", .{
        .status = .internal_server_error,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

fn sleepMillisecond(io: std.Io) void {
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = std.time.ns_per_ms }, .clock = .awake } }, io) catch {};
}

fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| loopback_ip6: {
            const v6_loopback: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            const v4_mapped_prefix: [12]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            break :loopback_ip6 std.mem.eql(u8, &ip6.bytes, &v6_loopback) or
                (std.mem.eql(u8, ip6.bytes[0..12], &v4_mapped_prefix) and ip6.bytes[12] == 127);
        },
    };
}

// -- journeys ---------------------------------------------------------------
// Real sockets on port 0, real threads, outcome assertions. These run in
// `zig build test` like every other module test.

const TestHarness = struct {
    var noted_errors: std.atomic.Value(u64) = .init(0);

    fn onError(err: anyerror, note: []const u8) void {
        _ = @errorName(err);
        _ = note;
        _ = noted_errors.fetchAdd(1, .monotonic);
    }

    fn okHandler(_: u8, context: *RequestContext) anyerror!void {
        try context.request.respond("journey body", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
    }

    fn boot(app: *App, comptime handler: fn (u8, *RequestContext) anyerror!void) !std.Thread {
        const Runner = struct {
            fn main(app_pointer: *App, result: *anyerror!void) void {
                result.* = app_pointer.run(u8, 0, handler);
            }
        };
        const thread = try std.Thread.spawn(.{}, Runner.main, .{ app, &run_result });
        var attempts: usize = 0;
        while (app.boundPort() == 0) : (attempts += 1) {
            if (attempts > 2_000) return error.ServerNeverBound;
            sleepMillisecond(app.io);
        }
        return thread;
    }

    var run_result: anyerror!void = {};

    /// Reads one response's bytes until the header terminator plus a small
    /// body window; enough for tests that only need completion.
    fn readOne(reader: *std.Io.Reader) !usize {
        var seen: usize = 0;
        var byte: [1]u8 = undefined;
        var window: [4]u8 = @splat(0);
        while (true) {
            const n = try reader.readSliceShort(&byte);
            if (n == 0) return error.EndOfStream;
            seen += 1;
            window[0] = window[1];
            window[1] = window[2];
            window[2] = window[3];
            window[3] = byte[0];
            if (std.mem.eql(u8, &window, "\r\n\r\n")) break;
        }
        // Drain the fixed body the ok handler writes.
        var body: [64]u8 = undefined;
        _ = try reader.readSliceShort(body[0.."journey body".len]);
        return seen;
    }

    fn request(io: std.Io, port: u16, raw: []const u8, response_storage: []u8) ![]const u8 {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(raw);
        try writer.interface.flush();
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var total: usize = 0;
        while (total < response_storage.len) {
            const chunk = reader.interface.readSliceShort(response_storage[total..]) catch break;
            if (chunk == 0) break;
            total += chunk;
        }
        return response_storage[0..total];
    }
};

test "boot, serve, keep-alive reuse, healthz, clean shutdown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 2,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    const server_thread = try TestHarness.boot(&app, TestHarness.okHandler);

    var storage: [4096]u8 = undefined;
    // Two requests on one connection prove keep-alive; the second still
    // answers after the first completed.
    const both = try TestHarness.request(io, app.boundPort(), "GET /a HTTP/1.1\r\nhost: t\r\n\r\nGET /b HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.count(u8, both, "journey body") == 2);

    const health = try TestHarness.request(io, app.boundPort(), "GET /healthz HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"requests\":") != null);

    app.requestShutdown();
    server_thread.join();
    try TestHarness.run_result;
    try std.testing.expect(app.counters().requests >= 3);
    try std.testing.expectEqual(@as(u64, 0), app.counters().forced_closes);
}

test "queue saturation answers 503 with retry-after instead of dropping" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Gate = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn slowHandler(_: u8, context: *RequestContext) anyerror!void {
            while (!release.load(.acquire)) sleepMillisecond(context.io);
            try context.request.respond("slow done", .{});
        }
    };
    Gate.release.store(false, .release);

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .queue_depth = 1,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    const server_thread = try TestHarness.boot(&app, Gate.slowHandler);
    const port = app.boundPort();

    // One request occupies the worker; one sits in the queue; further
    // connections must be told to back off explicitly.
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var held = try address.connect(io, .{ .mode = .stream });
    defer held.close(io);
    var held_writer_buffer: [256]u8 = undefined;
    var held_writer = held.writer(io, &held_writer_buffer);
    try held_writer.interface.writeAll("GET /hold HTTP/1.1\r\nhost: t\r\n\r\n");
    try held_writer.interface.flush();
    var queued = try address.connect(io, .{ .mode = .stream });
    defer queued.close(io);
    var queued_writer_buffer: [256]u8 = undefined;
    var queued_writer = queued.writer(io, &queued_writer_buffer);
    try queued_writer.interface.writeAll("GET /queued HTTP/1.1\r\nhost: t\r\n\r\n");
    try queued_writer.interface.flush();

    var rejected: usize = 0;
    var storage: [1024]u8 = undefined;
    var attempts: usize = 0;
    while (rejected == 0) : (attempts += 1) {
        if (attempts > 200) return error.NeverSaturated;
        const response = try TestHarness.request(io, port, "GET /extra HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
        if (std.mem.indexOf(u8, response, "503") != null) {
            try std.testing.expect(std.mem.indexOf(u8, response, "retry-after: 1") != null or
                std.mem.indexOf(u8, response, "Retry-After: 1") != null);
            rejected += 1;
        }
    }
    try std.testing.expect(app.counters().queue_rejections >= 1);

    Gate.release.store(true, .release);
    app.requestShutdown();
    server_thread.join();
    TestHarness.run_result catch {};
}

test "drain deadline force-closes a stalled handler and reports it" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Stall = struct {
        fn handler(_: u8, context: *RequestContext) anyerror!void {
            // Blocks reading a request body the client never sends. Only the
            // drain's force-close (or the idle timeout, set far higher here)
            // can unblock it.
            var transfer_buffer: [256]u8 = undefined;
            const reader = try context.request.readerExpectContinue(&transfer_buffer);
            var sink: [16]u8 = undefined;
            _ = try reader.readSliceShort(&sink);
            try context.request.respond("late", .{});
        }
    };

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .drain_timeout_ms = 300,
        .idle_timeout_ms = 60_000,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    const server_thread = try TestHarness.boot(&app, Stall.handler);
    const port = app.boundPort();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stalled = try address.connect(io, .{ .mode = .stream });
    defer stalled.close(io);
    var stalled_writer_buffer: [256]u8 = undefined;
    var stalled_writer = stalled.writer(io, &stalled_writer_buffer);
    try stalled_writer.interface.writeAll("POST /stall HTTP/1.1\r\nhost: t\r\ncontent-length: 5\r\n\r\n");
    try stalled_writer.interface.flush();
    // Give the worker a moment to pick the connection up.
    var attempts: usize = 0;
    while (app.counters().requests == 0) : (attempts += 1) {
        if (attempts > 1_000) return error.HandlerNeverStarted;
        sleepMillisecond(io);
    }

    app.requestShutdown();
    server_thread.join();
    try std.testing.expectError(Error.ForcedShutdown, TestHarness.run_result);
    try std.testing.expect(app.counters().forced_closes >= 1);
}

test "jobs tick on their interval and stop promptly at shutdown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Tick = struct {
        var count: std.atomic.Value(u64) = .init(0);
        fn run(_: *JobContext) anyerror!void {
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    Tick.count.store(0, .release);

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    try app.addJob(.{ .name = "tick", .interval_ms = 10, .run = Tick.run });
    const server_thread = try TestHarness.boot(&app, TestHarness.okHandler);

    var attempts: usize = 0;
    while (Tick.count.load(.acquire) < 3) : (attempts += 1) {
        if (attempts > 2_000) return error.JobNeverTicked;
        sleepMillisecond(io);
    }

    const shutdown_started = std.Io.Timestamp.now(io, .awake);
    app.requestShutdown();
    server_thread.join();
    try TestHarness.run_result;
    const shutdown_finished = std.Io.Timestamp.now(io, .awake);
    // Joining must not wait out a full interval-less sleep; generous bound
    // for slow CI.
    try std.testing.expect(shutdown_started.durationTo(shutdown_finished).nanoseconds < 5 * std.time.ns_per_s);
}

test "routed dispatch serves matched routes and falls back for the rest" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Routed = struct {
        const Route = struct {
            method: std.http.Method,
            pattern: []const u8,
            handler: *const fn (u8, *RequestContext, web_router.Params) anyerror!void,
        };
        fn item(_: u8, context: *RequestContext, params: web_router.Params) anyerror!void {
            var body: [128]u8 = undefined;
            const rendered = try std.fmt.bufPrint(&body, "item={s}", .{params.get("id").?});
            try context.request.respond(rendered, .{});
        }
        fn fallback(_: u8, context: *RequestContext, result: web_router.Result(Route)) anyerror!void {
            const status: std.http.Status = switch (result) {
                .method_not_allowed => .method_not_allowed,
                else => .not_found,
            };
            try context.request.respond("fallback", .{ .status = status });
        }
        const routes = [_]Route{
            .{ .method = .GET, .pattern = "/items/:id", .handler = item },
        };
    };

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 2,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    const Runner = struct {
        fn main(app_pointer: *App, result: *anyerror!void) void {
            result.* = runRouted(app_pointer, Routed.Route, &Routed.routes, u8, 0, Routed.fallback);
        }
    };
    TestHarness.run_result = {};
    const server_thread = try std.Thread.spawn(.{}, Runner.main, .{ &app, &TestHarness.run_result });
    var attempts: usize = 0;
    while (app.boundPort() == 0) : (attempts += 1) {
        if (attempts > 2_000) return error.ServerNeverBound;
        sleepMillisecond(io);
    }

    var storage: [2048]u8 = undefined;
    const matched = try TestHarness.request(io, app.boundPort(), "GET /items/42 HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, matched, "item=42") != null);
    const missing = try TestHarness.request(io, app.boundPort(), "GET /unknown HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, missing, "404") != null);
    const wrong_method = try TestHarness.request(io, app.boundPort(), "POST /items/42 HTTP/1.1\r\nhost: t\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, wrong_method, "405") != null);

    app.requestShutdown();
    server_thread.join();
    try TestHarness.run_result;
}

test "an idle keep-alive connection does not stall graceful shutdown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 2,
        .drain_timeout_ms = 5_000,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    const server_thread = try TestHarness.boot(&app, TestHarness.okHandler);
    const port = app.boundPort();

    // Complete one request, then leave the connection idle (keep-alive).
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = idle.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /idle HTTP/1.1\r\nhost: t\r\n\r\n");
    try writer.interface.flush();
    var read_buffer: [1024]u8 = undefined;
    var reader = idle.reader(io, &read_buffer);
    _ = try TestHarness.readOne(&reader.interface);

    const started = std.Io.Timestamp.now(io, .awake);
    app.requestShutdown();
    server_thread.join();
    const finished = std.Io.Timestamp.now(io, .awake);
    try TestHarness.run_result;
    // Idle connections close at drain start, far inside the deadline, and
    // are not counted as forced.
    try std.testing.expect(started.durationTo(finished).nanoseconds < 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), app.counters().forced_closes);
}
