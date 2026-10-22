//! Profile-5 successful busy-lock scopes and rules-2 actual failed claims. This proof consumes actual facts
//! and independent operation obligations; no serialized lane merge is a clock.
const std = @import("std");
const format = @import("causal_recording_format.zig");

/// Ops is a comptime adapter with charge/reserve/release/emit functions over
/// the caller's ORIGINAL Dependencies. No private ledger or budget is created.
/// Call closeOperation only after actual Worker end or Control Binding.finished
/// == 7. Those boundaries authorize retirement of duplicate-detection rows.
pub fn TicketProof(comptime Point: type, comptime Error: type, comptime Ops: type) type {
    return struct {
        const Self = @This();
        pub const Scope = struct {
            key: format.OperationKey,
            owner: @FieldType(format.ServiceExclusion, "owner"),
            claim: Point,
            release: Point,
        };
        const Entry = struct {
            key: format.OperationKey,
            owner: @FieldType(format.ServiceExclusion, "owner"),
            ticket: ?u64 = null,
            scope: ?Scope = null,
            expected_order: u64 = 0,
            linked: bool = false,
            token: ?u64 = null,
            release_progress: ?Point = null,
        };
        const Claim = struct {
            key: format.OperationKey,
            kind: format.ServiceClaimKind,
            actual: ?format.ServiceClaimAttempt = null,
            expected: ?struct { at: Point, busy: bool, ordinal: u64 } = null,
            ticket: ?u64 = null,
        };
        const ReleaseRead = struct {
            key: format.OperationKey,
            token: u64,
            after_claims: u64,
            at: Point,
            lower: bool = false,
            upper: bool = false,
            watermark: bool = false,
        };
        release_reads: [format.max_dependencies]ReleaseRead = undefined,
        release_read_count: usize = 0,
        release_publications: u64 = 0,
        release_observed_token: u64 = 0,
        release_read_operation: u64 = 0,
        release_read_floor: u64 = 0,
        released_through_ticket: u64 = 0,
        release_source_closed: bool = false,
        rules_version: u16 = 1,
        claims: [format.max_dependencies]Claim = undefined,
        claim_count: usize = 0,
        actual_claims: [3]u64 = @splat(0),
        expected_claims: [3]u64 = @splat(0),
        actual_claim_operation: [3]u64 = @splat(0),
        expected_claim_operation: [3]u64 = @splat(0),
        paired_control: u64 = 0,
        // Only paired actual Control observations advance this lower bound.
        // A Worker end, later ticket, or lane arrival never advances it.
        control_watermark: u64 = 0,
        capacity: usize = 0,
        entries: [format.max_dependencies]Entry = undefined,
        count: usize = 0,
        frontier: u64 = 0,
        last_release: ?Point = null,
        closed: [3]u64 = @splat(0),
        fact_operation: [3]u64 = @splat(0),
        fact_ticket: [3]u64 = @splat(0),
        expected_operation: [3]u64 = @splat(0),
        expected_order: [3]u64 = @splat(0),
        failed: bool = false,
        finished: bool = false,

        pub fn initInto(self: *Self, capacity: u32) Error!void {
            return self.initIntoRules(capacity, 1);
        }
        pub fn initIntoRules(self: *Self, capacity: u32, rules_version: u16) Error!void {
            if (rules_version != 1 and rules_version != 2) return error.UnknownVersion;
            self.rules_version = rules_version;
            self.release_read_count = 0;
            self.release_publications = 0;
            self.release_observed_token = 0;
            self.release_read_operation = 0;
            self.release_read_floor = 0;
            self.released_through_ticket = 0;
            self.release_source_closed = false;
            self.claim_count = 0;
            self.actual_claims = @splat(0);
            self.expected_claims = @splat(0);
            self.actual_claim_operation = @splat(0);
            self.expected_claim_operation = @splat(0);
            self.paired_control = 0;
            self.control_watermark = 0;
            if (capacity == 0 or capacity > format.max_dependencies) return error.InvalidLimits;
            self.capacity = capacity;
            // Entries are written completely by entry() before count exposes
            // them. Avoid copying a 256-entry temporary onto the init stack.
            self.count = 0;
            self.frontier = 0;
            self.last_release = null;
            self.closed = @splat(0);
            self.fact_operation = @splat(0);
            self.fact_ticket = @splat(0);
            self.expected_operation = @splat(0);
            self.expected_order = @splat(0);
            self.failed = false;
            self.finished = false;
        }
        fn begin(self: *Self, deps: anytype) Error!void {
            if (self.failed or self.finished or self.capacity == 0) return error.Incomplete;
            try Ops.charge(deps);
        }
        fn identity(key: format.OperationKey, owner: @FieldType(format.ServiceExclusion, "owner")) Error!void {
            if (key.ordinal == 0) return error.InvalidEvidence;
            switch (owner) {
                .worker => if (key.role != .worker) return error.InvalidEvidence,
                .stream_close => |value| if (key.role != .control or value.handle.generation == 0) return error.InvalidEvidence,
                // Its real ticket is never skipped. Active preparation needs
                // its own operation admission before this helper can certify.
                .prepare_asset => return error.UnrepresentedCut,
            }
        }
        fn validateScope(scope: Scope) Error!void {
            try identity(scope.key, scope.owner);
            const a = scope.claim;
            const b = scope.release;
            if (a.role != scope.key.role or b.role != scope.key.role or a.operation != scope.key.ordinal or b.operation != scope.key.ordinal or a.edge != .before or b.edge != .after or a.occurrence == 0 or b.occurrence == 0) return error.InvalidEvidence;
            switch (scope.owner) {
                .worker => |value| if (a.site != .worker_claim or b.site != .worker_idle or a.index != 0 or b.index != 0 or a.generation != 0 or b.generation != value.job or a.occurrence != 1 or b.occurrence != 1) return error.InvalidEvidence,
                .stream_close => |value| if (a.site != .stream_close_claim or b.site != .stream_close_idle or a.index != value.handle.index or b.index != value.handle.index or a.generation != value.handle.generation or b.generation != value.handle.generation or b.occurrence > a.occurrence) return error.InvalidEvidence,
                .prepare_asset => unreachable,
            }
        }
        fn entry(self: *Self, deps: anytype, key: format.OperationKey, owner: @FieldType(format.ServiceExclusion, "owner")) Error!usize {
            for (self.entries[0..self.count], 0..) |value, i| {
                try Ops.charge(deps);
                if (std.meta.eql(value.key, key) and std.meta.eql(value.owner, owner)) return i;
            }
            if (self.count == self.capacity) return error.DependencyCapacity;
            try Ops.reserve(deps);
            const i = self.count;
            self.entries[i] = .{ .key = key, .owner = owner };
            self.count += 1;
            return i;
        }
        fn roleOrder(self: *Self, deps: anytype, i: usize) Error!void {
            const current = self.entries[i];
            const ticket = current.ticket orelse return;
            if (current.scope == null) return;
            // Both extractors have their own genuine producer FIFO. Compare
            // only one role's scope order, never the inter-role merge order.
            for (self.entries[0..self.count], 0..) |other, j| {
                try Ops.charge(deps);
                if (i == j or other.key.role != current.key.role or other.scope == null or other.ticket == null) continue;
                if ((other.expected_order < current.expected_order and other.ticket.? >= ticket) or
                    (other.expected_order > current.expected_order and other.ticket.? <= ticket)) return error.FutureReference;
            }
        }
        fn retireClosed(self: *Self, deps: anytype) Error!void {
            var i: usize = 0;
            while (i < self.count) {
                try Ops.charge(deps);
                const value = self.entries[i];
                // The last release remains one charged obligation until its
                // successor links, or finish proves there is no missing scope.
                if (value.linked and value.ticket.? < self.frontier and value.key.ordinal <= self.closed[@intFromEnum(value.key.role)] and (self.rules_version == 1 or (value.token != null and value.ticket.? < self.control_watermark and (value.key.role != .worker or (value.release_progress != null and value.token.? / 4 < self.release_read_floor))))) {
                    self.count -= 1;
                    self.entries[i] = self.entries[self.count];
                    Ops.release(deps);
                } else i += 1;
            }
        }
        fn advance(self: *Self, deps: anytype) Error!void {
            while (self.frontier != std.math.maxInt(u64)) {
                const next = self.frontier + 1;
                var found: ?usize = null;
                for (self.entries[0..self.count], 0..) |value, i| {
                    try Ops.charge(deps);
                    if (value.ticket == next and value.scope != null) {
                        found = i;
                        break;
                    }
                }
                const i = found orelse break;
                const scope = self.entries[i].scope.?;
                if (self.last_release) |previous| try Ops.emit(deps, previous, scope.claim);
                self.last_release = scope.release;
                self.frontier = next;
                self.entries[i].linked = true;
            }
            if (self.rules_version == 2) try self.resolveClaims(deps);
            try self.retireClosed(deps);
        }
        pub fn observeFact(self: *Self, deps: anytype, key: format.OperationKey, fact: format.ServiceExclusion) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            try identity(key, fact.owner);
            if (fact.ticket == 0) return error.InvalidEvidence;
            const role = @intFromEnum(key.role);
            if (key.ordinal <= self.closed[role] or fact.ticket <= self.frontier or fact.ticket == self.fact_ticket[role]) return error.DuplicatePublication;
            if (key.ordinal < self.fact_operation[role] or fact.ticket < self.fact_ticket[role]) return error.FutureReference;
            if (key.role == .worker and key.ordinal == self.fact_operation[role]) return error.DuplicatePublication;
            for (self.entries[0..self.count]) |value| {
                try Ops.charge(deps);
                if (value.ticket == fact.ticket) return error.DuplicatePublication;
            }
            const i = try self.entry(deps, key, fact.owner);
            if (self.entries[i].ticket != null) return error.DuplicatePublication;
            self.entries[i].ticket = fact.ticket;
            self.fact_operation[role] = key.ordinal;
            self.fact_ticket[role] = fact.ticket;
            try self.roleOrder(deps, i);
            try self.advance(deps);
        }
        pub fn expectScope(self: *Self, deps: anytype, scope: Scope) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            try validateScope(scope);
            const role = @intFromEnum(scope.key.role);
            if (scope.key.ordinal <= self.closed[role]) return error.DuplicateAcquisition;
            if (scope.key.ordinal < self.expected_operation[role]) return error.FutureReference;
            if (scope.key.role == .worker and scope.key.ordinal == self.expected_operation[role]) return error.DuplicateAcquisition;
            const i = try self.entry(deps, scope.key, scope.owner);
            if (self.entries[i].scope != null) return error.DuplicateAcquisition;
            self.expected_order[role] = std.math.add(u64, self.expected_order[role], 1) catch return error.WorkBudget;
            self.expected_operation[role] = scope.key.ordinal;
            self.entries[i].scope = scope;
            self.entries[i].expected_order = self.expected_order[role];
            if (self.rules_version == 2) try self.expectClaim(deps, scope.key, ownerKind(scope.owner), scope.claim, false);
            try self.roleOrder(deps, i);
            try self.advance(deps);
        }
        pub fn closeOperation(self: *Self, deps: anytype, key: format.OperationKey) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            if (key.role == .render or key.ordinal == 0) return error.InvalidEvidence;
            const role = @intFromEnum(key.role);
            if (key.ordinal <= self.closed[role]) return error.DuplicateAcquisition;
            var worker_seen = false;
            for (self.entries[0..self.count]) |value| {
                try Ops.charge(deps);
                if (value.key.role != key.role or value.key.ordinal > key.ordinal) continue;
                if (value.scope == null) return error.MissingAcquisition;
                if (value.ticket == null) return error.MissingPublication;
                if (self.rules_version == 2 and value.key.role == .worker and value.release_progress == null) return error.MissingPublication;
                if (std.meta.eql(value.key, key)) worker_seen = true;
            }
            if (key.role == .worker and !worker_seen) return error.MissingAcquisition;
            if (self.rules_version == 2) for (self.claims[0..self.claim_count]) |claim| {
                try Ops.charge(deps);
                if (claim.key.role != key.role or claim.key.ordinal > key.ordinal) continue;
                if (claim.actual == null) return error.MissingPublication;
                if (claim.expected == null) return error.MissingAcquisition;
            };
            self.closed[role] = key.ordinal;
            try self.advance(deps);
        }
        fn ownerKind(owner: @FieldType(format.ServiceExclusion, "owner")) format.ServiceClaimKind {
            return switch (owner) {
                .worker => .worker,
                .stream_close => |value| .{ .stream_close = .{ .handle = value.handle, .parent_attempt = value.parent_attempt } },
                .prepare_asset => |value| .{ .prepare_asset = .{ .sound_index = value.sound_index, .asset = value.asset, .encoded_hash = value.encoded_hash } },
            };
        }
        fn claimIdentity(key: format.OperationKey, kind: format.ServiceClaimKind) Error!void {
            if (key.ordinal == 0) return error.InvalidEvidence;
            switch (kind) {
                .worker => if (key.role != .worker) return error.InvalidEvidence,
                .stream_close => |value| if (key.role != .control or value.handle.generation == 0) return error.InvalidEvidence,
                .prepare_asset => return error.UnrepresentedCut,
            }
        }
        fn claimRow(self: *Self, deps: anytype, key: format.OperationKey, kind: format.ServiceClaimKind) Error!usize {
            for (self.claims[0..self.claim_count], 0..) |claim, i| {
                try Ops.charge(deps);
                if (std.meta.eql(claim.key, key) and std.meta.eql(claim.kind, kind)) return i;
            }
            if (self.claim_count == self.capacity) return error.DependencyCapacity;
            try Ops.reserve(deps);
            const i = self.claim_count;
            self.claims[i] = .{ .key = key, .kind = kind };
            self.claim_count += 1;
            return i;
        }
        fn removeClaim(self: *Self, deps: anytype, i: usize) void {
            self.claim_count -= 1;
            self.claims[i] = self.claims[self.claim_count];
            Ops.release(deps);
        }
        fn expectClaim(self: *Self, deps: anytype, key: format.OperationKey, kind: format.ServiceClaimKind, at: Point, busy: bool) Error!void {
            try claimIdentity(key, kind);
            const role = @intFromEnum(key.role);
            if (key.ordinal <= self.closed[role]) return error.DuplicateAcquisition;
            if (key.ordinal < self.expected_claim_operation[role]) return error.FutureReference;
            const i = try self.claimRow(deps, key, kind);
            if (self.claims[i].expected != null) return error.DuplicateAcquisition;
            const ordinal = std.math.add(u64, self.expected_claims[role], 1) catch return error.WorkBudget;
            self.claims[i].expected = .{ .at = at, .busy = busy, .ordinal = ordinal };
            self.expected_claims[role] = ordinal;
            self.expected_claim_operation[role] = key.ordinal;
        }
        pub fn observeClaim(self: *Self, deps: anytype, key: format.OperationKey, actual: format.ServiceClaimAttempt) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            if (self.rules_version != 2) return error.UnsupportedOperation;
            try claimIdentity(key, actual.kind);
            const role = @intFromEnum(key.role);
            if (key.ordinal <= self.closed[role]) return error.DuplicatePublication;
            if (key.ordinal < self.actual_claim_operation[role]) return error.FutureReference;
            if (format.serviceClaimRole(actual.token) != key.role) return error.InvalidEvidence;
            if (actual.token / 4 != self.actual_claims[role] + 1) return error.InvalidEvidence;
            if (actual.observed != 0) {
                if (format.serviceClaimRole(actual.observed) == null or actual.observed == actual.token) return error.InvalidEvidence;
                // WorkerBusy has no admitted public Worker result/prefix.
                if (actual.kind == .worker) return error.UnrepresentedCut;
                // One actual Control FIFO cannot overlap itself inside a CAS.
                if (format.serviceClaimRole(actual.observed) == key.role) return error.InvalidEvidence;
            }
            const i = try self.claimRow(deps, key, actual.kind);
            if (self.claims[i].actual != null) return error.DuplicatePublication;
            self.claims[i].actual = actual;
            self.actual_claims[role] += 1;
            self.actual_claim_operation[role] = key.ordinal;
            try self.advance(deps);
        }
        pub fn expectBusyClose(self: *Self, deps: anytype, key: format.OperationKey, kind: format.ServiceClaimKind, at: Point) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            if (self.rules_version != 2) return error.UnsupportedOperation;
            try claimIdentity(key, kind);
            if (kind != .stream_close or at.role != .control or at.operation != key.ordinal or at.site != .stream_close_claim or at.edge != .before or at.occurrence == 0 or at.index != kind.stream_close.handle.index or at.generation != kind.stream_close.handle.generation) return error.InvalidEvidence;
            try self.expectClaim(deps, key, kind, at, true);
            try self.advance(deps);
        }
        fn resolveClaims(self: *Self, deps: anytype) Error!void {
            // Pair successful claims first, so a failed attempt can find a
            // holder whose facts arrived later in another producer lane.
            var i: usize = 0;
            while (i < self.claim_count) {
                try Ops.charge(deps);
                const claim = self.claims[i];
                const actual = claim.actual orelse {
                    i += 1;
                    continue;
                };
                const expected = claim.expected orelse {
                    i += 1;
                    continue;
                };
                if (actual.token / 4 != expected.ordinal or expected.busy != (actual.observed != 0)) return error.InvalidEvidence;
                if (expected.busy or claim.ticket != null) {
                    i += 1;
                    continue;
                }
                for (self.entries[0..self.count]) |*holder| {
                    try Ops.charge(deps);
                    if (!std.meta.eql(holder.key, claim.key) or !std.meta.eql(ownerKind(holder.owner), claim.kind)) continue;
                    const scope = holder.scope orelse break;
                    const ticket = holder.ticket orelse break;
                    if (!std.meta.eql(scope.claim, expected.at)) return error.InvalidEvidence;
                    if (holder.token != null) return error.DuplicatePublication;
                    holder.token = actual.token;
                    self.claims[i].ticket = ticket;
                    break;
                }
                if (claim.key.role == .worker and self.claims[i].ticket != null) self.removeClaim(deps, i) else i += 1;
            }
            for (self.claims[0..self.claim_count]) |*claim| {
                try Ops.charge(deps);
                if (claim.ticket != null) continue;
                const actual = claim.actual orelse continue;
                const expected = claim.expected orelse continue;
                if (!expected.busy) continue;
                for (self.entries[0..self.count]) |holder| {
                    try Ops.charge(deps);
                    if (holder.token != actual.observed) continue;
                    const scope = holder.scope orelse return error.MissingAcquisition;
                    const ticket = holder.ticket orelse return error.MissingPublication;
                    if (scope.key.role == claim.key.role) return error.InvalidEvidence;
                    var acquired = scope.claim;
                    acquired.edge = .after;
                    var observed = expected.at;
                    observed.edge = .after;
                    var release = scope.release;
                    release.edge = .before;
                    try Ops.emit(deps, acquired, expected.at);
                    try Ops.emit(deps, observed, release);
                    claim.ticket = ticket;
                    break;
                }
            }
            // Both sources are genuine Control FIFO streams. Only their
            // contiguous paired prefix excludes earlier future busy reads.
            while (true) {
                try self.resolveReleaseReads(deps);
                // An earlier actual Control acquire whose source publication
                // is delayed must be proved before pairing any later claim.
                for (self.release_reads[0..self.release_read_count]) |read| {
                    try Ops.charge(deps);
                    if (!read.watermark and read.after_claims <= self.paired_control) return;
                }
                var next: ?usize = null;
                for (self.claims[0..self.claim_count], 0..) |claim, j| {
                    try Ops.charge(deps);
                    if (claim.key.role == .control and claim.expected != null and claim.expected.?.ordinal == self.paired_control + 1 and claim.ticket != null) {
                        next = j;
                        break;
                    }
                }
                const j = next orelse break;
                const ticket = self.claims[j].ticket.?;
                if (ticket < self.control_watermark or ticket <= self.released_through_ticket) return error.FutureReference;
                self.control_watermark = ticket;
                self.paired_control += 1;
                self.removeClaim(deps, j);
            }
        }
        pub fn observeWorkerRelease(self: *Self, deps: anytype, key: format.OperationKey, value: format.ServiceWorkerRelease, at: Point) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            if (self.rules_version != 2) return error.UnsupportedOperation;
            if (self.release_source_closed or key.role != .worker or key.ordinal == 0 or key.ordinal <= self.closed[@intFromEnum(format.Role.worker)] or format.serviceClaimRole(value.token) != .worker or value.ticket == 0) return error.InvalidEvidence;
            if (value.token / 4 != self.release_publications + 1) return error.InvalidEvidence;
            if (at.role != .worker or at.operation != key.ordinal or at.site != .worker_release_progress or at.index != value.token or at.generation != value.ticket or at.occurrence != 1 or at.edge != .after) return error.InvalidEvidence;
            var found = false;
            for (self.entries[0..self.count]) |*holder| {
                try Ops.charge(deps);
                if (!std.meta.eql(holder.key, key) or holder.owner != .worker) continue;
                _ = holder.scope orelse return error.MissingAcquisition;
                if (holder.token != value.token or holder.ticket != value.ticket) return error.InvalidEvidence;
                if (holder.release_progress != null) return error.DuplicatePublication;
                // The recorded post-unlock store is its own checkpoint. The
                // preceding unlock point must never substitute for this store.
                holder.release_progress = at;
                found = true;
                break;
            }
            if (!found) return error.MissingPublication;
            self.release_publications += 1;
            try self.advance(deps);
        }
        pub fn observeReleaseRead(self: *Self, deps: anytype, key: format.OperationKey, token: u64, after_claims: u64, at: Point) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            if (self.rules_version != 2) return error.UnsupportedOperation;
            if (key.role != .control or key.ordinal == 0 or (token != 0 and format.serviceClaimRole(token) != .worker) or at.role != .control or at.operation != key.ordinal or at.site != .control_release_progress or at.index != 0 or at.generation != 0 or at.occurrence != 1 or at.edge != .before) return error.InvalidEvidence;
            if (key.ordinal <= self.closed[@intFromEnum(format.Role.control)] or key.ordinal <= self.release_read_operation or token < self.release_observed_token or after_claims != self.actual_claims[@intFromEnum(format.Role.control)]) return error.FutureReference;
            self.release_read_operation = key.ordinal;
            self.release_observed_token = token;
            // Same-role program order transfers only an already proved lower
            // cut's unresolved upper bound. The new read keeps its comparator.
            for (self.release_reads[0..self.release_read_count]) |*read| {
                try Ops.charge(deps);
                if (read.token == token and read.lower and read.watermark and !read.upper) {
                    read.* = .{ .key = key, .token = token, .after_claims = after_claims, .at = at };
                    return self.advance(deps);
                }
            }
            if (self.release_read_count == self.capacity) return error.DependencyCapacity;
            try Ops.reserve(deps);
            self.release_reads[self.release_read_count] = .{ .key = key, .token = token, .after_claims = after_claims, .at = at };
            self.release_read_count += 1;
            try self.advance(deps);
        }
        fn resolveReleaseReads(self: *Self, deps: anytype) Error!void {
            var i: usize = 0;
            while (i < self.release_read_count) {
                try Ops.charge(deps);
                var read = self.release_reads[i];
                const ordinal = read.token / 4;
                var lower: ?Entry = null;
                var upper: ?Point = null;
                for (self.entries[0..self.count]) |holder| {
                    try Ops.charge(deps);
                    const published = holder.release_progress orelse continue;
                    const published_ordinal = holder.token.? / 4;
                    if (read.token != 0 and holder.token.? == read.token) lower = holder;
                    if (published_ordinal == ordinal + 1) upper = published;
                }
                if (!read.lower) {
                    if (read.token == 0) read.lower = true else if (lower) |holder| {
                        try Ops.emit(deps, holder.release_progress.?, read.at);
                        read.lower = true;
                    } else if (ordinal <= self.release_publications) return error.MissingPublication;
                }
                if (!read.upper) if (upper) |published| {
                    var after = read.at;
                    after.edge = .after;
                    var before = published;
                    before.edge = .before;
                    try Ops.emit(deps, after, before);
                    read.upper = true;
                } else if (ordinal < self.release_publications) return error.MissingPublication;
                if (!read.watermark and read.lower and read.after_claims <= self.paired_control) {
                    if (read.token != 0) {
                        const holder = lower orelse return error.MissingPublication;
                        self.control_watermark = @max(self.control_watermark, holder.ticket.?);
                        self.released_through_ticket = @max(self.released_through_ticket, holder.ticket.?);
                        self.release_read_floor = @max(self.release_read_floor, ordinal);
                    }
                    read.watermark = true;
                }
                if (read.lower and (read.upper or self.release_source_closed) and read.watermark) {
                    self.release_read_count -= 1;
                    self.release_reads[i] = self.release_reads[self.release_read_count];
                    Ops.release(deps);
                } else {
                    self.release_reads[i] = read;
                    i += 1;
                }
            }
        }
        pub fn finish(self: *Self, deps: anytype) Error!void {
            errdefer self.failed = true;
            try self.begin(deps);
            if (self.rules_version == 2) {
                if (self.release_publications != self.actual_claims[@intFromEnum(format.Role.worker)]) return error.MissingPublication;
                self.release_source_closed = true;
            }
            try self.advance(deps);
            if (self.release_read_count != 0) return error.MissingPublication;
            for (self.entries[0..self.count]) |value| {
                try Ops.charge(deps);
                if (value.scope == null) return error.MissingAcquisition;
                if (value.ticket == null or !value.linked or (self.rules_version == 2 and value.token == null)) return error.MissingPublication;
                if (value.key.ordinal > self.closed[@intFromEnum(value.key.role)]) return error.MissingAcquisition;
            }
            for (self.claims[0..self.claim_count]) |claim| {
                try Ops.charge(deps);
                if (claim.expected == null) return error.MissingAcquisition;
                return error.MissingPublication;
            }
            while (self.count != 0) {
                self.count -= 1;
                Ops.release(deps);
            }
            self.last_release = null;
            self.finished = true;
        }
    };
}
