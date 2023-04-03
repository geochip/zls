const std = @import("std");
const Ast = std.zig.Ast;
const log = std.log.scoped(.zls_references);

const DocumentStore = @import("../DocumentStore.zig");
const Analyser = @import("../analysis.zig");
const types = @import("../lsp.zig");
const offsets = @import("../offsets.zig");
const ast = @import("../ast.zig");
const tracy = @import("../tracy.zig");

pub fn labelReferences(
    allocator: std.mem.Allocator,
    decl: Analyser.DeclWithHandle,
    encoding: offsets.Encoding,
    include_decl: bool,
) error{OutOfMemory}!std.ArrayListUnmanaged(types.Location) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    std.debug.assert(decl.decl.* == .label_decl); // use `symbolReferences` instead
    const handle = decl.handle;
    const tree = handle.tree;
    const token_tags = tree.tokens.items(.tag);

    // Find while / for / block from label -> iterate over children nodes, find break and continues, change their labels if they match.
    // This case can be implemented just by scanning tokens.
    const first_tok = decl.decl.label_decl.label;
    const last_tok = ast.lastToken(tree, decl.decl.label_decl.block);

    var locations = std.ArrayListUnmanaged(types.Location){};
    errdefer locations.deinit(allocator);

    if (include_decl) {
        // The first token is always going to be the label
        try locations.append(allocator, .{
            .uri = handle.uri,
            .range = offsets.tokenToRange(handle.tree, first_tok, encoding),
        });
    }

    var curr_tok = first_tok + 1;
    while (curr_tok < last_tok - 2) : (curr_tok += 1) {
        const curr_id = token_tags[curr_tok];

        if (curr_id != .keyword_break and curr_id != .keyword_continue) continue;
        if (token_tags[curr_tok + 1] != .colon) continue;
        if (token_tags[curr_tok + 2] != .identifier) continue;

        if (!std.mem.eql(u8, tree.tokenSlice(curr_tok + 2), tree.tokenSlice(first_tok))) continue;

        try locations.append(allocator, .{
            .uri = handle.uri,
            .range = offsets.tokenToRange(handle.tree, curr_tok + 2, encoding),
        });
    }

    return locations;
}

const Builder = struct {
    allocator: std.mem.Allocator,
    locations: std.ArrayListUnmanaged(types.Location) = .{},
    /// this is the declaration we are searching for
    decl_handle: Analyser.DeclWithHandle,
    analyser: *Analyser,
    encoding: offsets.Encoding,

    const Context = struct {
        builder: *Builder,
        handle: *const DocumentStore.Handle,
    };

    pub fn deinit(self: *Builder) void {
        self.locations.deinit(self.allocator);
    }

    pub fn add(self: *Builder, handle: *const DocumentStore.Handle, token_index: Ast.TokenIndex) error{OutOfMemory}!void {
        try self.locations.append(self.allocator, .{
            .uri = handle.uri,
            .range = offsets.tokenToRange(handle.tree, token_index, self.encoding),
        });
    }

    fn collectReferences(self: *Builder, handle: *const DocumentStore.Handle, node: Ast.Node.Index) error{OutOfMemory}!void {
        const context = Context{
            .builder = self,
            .handle = handle,
        };
        try ast.iterateChildrenRecursive(handle.tree, node, &context, error{OutOfMemory}, referenceNode);
    }

    fn referenceNode(self: *const Context, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!void {
        const builder = self.builder;
        const handle = self.handle;

        const node_tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const starts = tree.tokens.items(.start);

        switch (node_tags[node]) {
            .identifier,
            .test_decl,
            => {
                const identifier_token = Analyser.getDeclNameToken(tree, node).?;
                if (token_tags[identifier_token] != .identifier) return;

                const child = (try builder.analyser.lookupSymbolGlobal(
                    handle,
                    offsets.tokenToSlice(tree, identifier_token),
                    starts[identifier_token],
                )) orelse return;

                if (builder.decl_handle.eql(child)) {
                    try builder.add(handle, identifier_token);
                }
            },
            .field_access => {
                const left_type = try builder.analyser.resolveFieldAccessLhsType(
                    (try builder.analyser.resolveTypeOfNode(.{ .node = datas[node].lhs, .handle = handle })) orelse return,
                );

                const left_type_node = switch (left_type.type.data) {
                    .other => |n| n,
                    else => return,
                };

                const child = (try builder.analyser.lookupSymbolContainer(
                    .{ .node = left_type_node, .handle = left_type.handle },
                    offsets.tokenToSlice(tree, datas[node].rhs),
                    !left_type.type.is_type_val,
                )) orelse return;

                if (builder.decl_handle.eql(child)) {
                    try builder.add(handle, datas[node].rhs);
                }
            },
            else => {},
        }
    }
};

fn gatherReferences(
    allocator: std.mem.Allocator,
    analyser: *Analyser,
    curr_handle: *const DocumentStore.Handle,
    skip_std_references: bool,
    include_decl: bool,
    builder: anytype,
    handle_behavior: enum { get, get_or_load },
) !void {
    var dependencies = std.StringArrayHashMapUnmanaged(void){};
    defer {
        for (dependencies.keys()) |uri| {
            allocator.free(uri);
        }
        dependencies.deinit(allocator);
    }

    for (analyser.store.handles.values()) |handle| {
        if (skip_std_references and std.mem.indexOf(u8, handle.uri, "std") != null) {
            if (!include_decl or !std.mem.eql(u8, handle.uri, curr_handle.uri))
                continue;
        }

        var handle_dependencies = std.ArrayListUnmanaged([]const u8){};
        defer handle_dependencies.deinit(allocator);
        try analyser.store.collectDependencies(allocator, handle.*, &handle_dependencies);

        try dependencies.ensureUnusedCapacity(allocator, handle_dependencies.items.len);
        for (handle_dependencies.items) |uri| {
            var gop = dependencies.getOrPutAssumeCapacity(uri);
            if (gop.found_existing) {
                allocator.free(uri);
            }
        }
    }

    for (dependencies.keys()) |uri| {
        if (std.mem.eql(u8, uri, curr_handle.uri)) continue;
        const handle = switch (handle_behavior) {
            .get => analyser.store.getHandle(uri),
            .get_or_load => analyser.store.getOrLoadHandle(uri),
        } orelse continue;

        try builder.collectReferences(handle, 0);
    }
}

pub fn symbolReferences(
    allocator: std.mem.Allocator,
    analyser: *Analyser,
    decl_handle: Analyser.DeclWithHandle,
    encoding: offsets.Encoding,
    /// add `decl_handle` as a references
    include_decl: bool,
    /// exclude references from the std library
    skip_std_references: bool,
    /// search other files for references
    workspace: bool,
) error{OutOfMemory}!std.ArrayListUnmanaged(types.Location) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    std.debug.assert(decl_handle.decl.* != .label_decl); // use `labelReferences` instead

    var builder = Builder{
        .allocator = allocator,
        .analyser = analyser,
        .decl_handle = decl_handle,
        .encoding = encoding,
    };
    errdefer builder.deinit();

    const curr_handle = decl_handle.handle;
    if (include_decl) try builder.add(curr_handle, decl_handle.nameToken());

    switch (decl_handle.decl.*) {
        .ast_node,
        .pointer_payload,
        .switch_payload,
        .array_payload,
        .array_index,
        => {
            try builder.collectReferences(curr_handle, 0);

            if (decl_handle.decl.* != .ast_node or !workspace) return builder.locations;

            try gatherReferences(allocator, analyser, curr_handle, skip_std_references, include_decl, &builder, .get);
        },
        .param_payload => |payload| blk: {
            // Rename the param tok.
            for (curr_handle.document_scope.scopes.items(.data)) |scope_data| {
                if (scope_data != .function) continue;

                const proto = scope_data.function;

                var buf: [1]Ast.Node.Index = undefined;
                const fn_proto = curr_handle.tree.fullFnProto(&buf, proto).?;

                var it = fn_proto.iterate(&curr_handle.tree);
                while (ast.nextFnParam(&it)) |candidate| {
                    if (!std.meta.eql(candidate, payload.param)) continue;

                    if (curr_handle.tree.nodes.items(.tag)[proto] != .fn_decl) break :blk;
                    try builder.collectReferences(curr_handle, curr_handle.tree.nodes.items(.data)[proto].rhs);
                    break :blk;
                }
            }
            log.warn("Could not find param decl's function", .{});
        },
        .label_decl => unreachable, // handled separately by labelReferences
        .error_token => {},
    }

    return builder.locations;
}

pub const Callsite = struct {
    uri: []const u8,
    call_node: Ast.Node.Index,
};

const CallBuilder = struct {
    allocator: std.mem.Allocator,
    callsites: std.ArrayListUnmanaged(Callsite) = .{},
    /// this is the declaration we are searching for
    decl_handle: Analyser.DeclWithHandle,
    analyser: *Analyser,

    const Context = struct {
        builder: *CallBuilder,
        handle: *const DocumentStore.Handle,
    };

    pub fn deinit(self: *CallBuilder) void {
        self.callsites.deinit(self.allocator);
    }

    pub fn add(self: *CallBuilder, handle: *const DocumentStore.Handle, call_node: Ast.Node.Index) error{OutOfMemory}!void {
        try self.callsites.append(self.allocator, .{
            .uri = handle.uri,
            .call_node = call_node,
        });
    }

    fn collectReferences(self: *CallBuilder, handle: *const DocumentStore.Handle, node: Ast.Node.Index) error{OutOfMemory}!void {
        const context = Context{
            .builder = self,
            .handle = handle,
        };
        try ast.iterateChildrenRecursive(handle.tree, node, &context, error{OutOfMemory}, referenceNode);
    }

    fn referenceNode(self: *const Context, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!void {
        const builder = self.builder;
        const handle = self.handle;

        const node_tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        // const token_tags = tree.tokens.items(.tag);
        const starts = tree.tokens.items(.start);

        switch (node_tags[node]) {
            .call,
            .call_comma,
            .async_call,
            .async_call_comma,
            .call_one,
            .call_one_comma,
            .async_call_one,
            .async_call_one_comma,
            => {
                var buf: [1]Ast.Node.Index = undefined;
                var call = tree.fullCall(&buf, node).?;

                const called_node = call.ast.fn_expr;

                switch (node_tags[called_node]) {
                    .identifier => {
                        const identifier_token = Analyser.getDeclNameToken(tree, called_node).?;

                        const child = (try builder.analyser.lookupSymbolGlobal(
                            handle,
                            offsets.tokenToSlice(tree, identifier_token),
                            starts[identifier_token],
                        )) orelse return;

                        if (builder.decl_handle.eql(child)) {
                            try builder.add(handle, node);
                        }
                    },
                    .field_access => {
                        const left_type = try builder.analyser.resolveFieldAccessLhsType(
                            (try builder.analyser.resolveTypeOfNode(.{ .node = datas[called_node].lhs, .handle = handle })) orelse return,
                        );

                        const left_type_node = switch (left_type.type.data) {
                            .other => |n| n,
                            else => return,
                        };

                        const child = (try builder.analyser.lookupSymbolContainer(
                            .{ .node = left_type_node, .handle = left_type.handle },
                            offsets.tokenToSlice(tree, datas[called_node].rhs),
                            !left_type.type.is_type_val,
                        )) orelse return;

                        if (builder.decl_handle.eql(child)) {
                            try builder.add(handle, node);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

pub fn callsiteReferences(
    allocator: std.mem.Allocator,
    analyser: *Analyser,
    decl_handle: Analyser.DeclWithHandle,
    /// add `decl_handle` as a references
    include_decl: bool,
    /// exclude references from the std library
    skip_std_references: bool,
    /// search other files for references
    workspace: bool,
) error{OutOfMemory}!std.ArrayListUnmanaged(Callsite) {
    std.debug.assert(decl_handle.decl.* == .ast_node);

    var builder = CallBuilder{
        .allocator = allocator,
        .analyser = analyser,
        .decl_handle = decl_handle,
    };
    errdefer builder.deinit();

    const curr_handle = decl_handle.handle;
    if (include_decl) try builder.add(curr_handle, decl_handle.nameToken());

    try builder.collectReferences(curr_handle, 0);

    if (!workspace) return builder.callsites;

    try gatherReferences(allocator, analyser, curr_handle, skip_std_references, include_decl, &builder, .get_or_load);

    return builder.callsites;
}