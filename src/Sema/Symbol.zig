const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

const Ast = @import("../Ast.zig");

const typet = @import("Type.zig");
const Type = typet.Type;

const Token = @import("../lex.zig").Token;
const ErrorLogger = @import("../error.zig").ErrorLogger;

pub const Symbol = @This();

pub const Scope = struct {
    parent: ?*const Scope = null,
    symbols: StringHashMapUnmanaged(Symbol) = .empty,
    kind: Scope.Kind = .{ .root = 0 },

    pub const Kind = union(enum) {
        root: u0,
        function: Type.Handle,
        loop: u0,
    };

    pub fn lookup(self: *const Scope, target: []const u8) ?Symbol {
        var curr: ?*const Scope = self;
        while (curr) |s| : (curr = s.parent) {
            if (s.symbols.get(target)) |sym| {
                return sym;
            }
        }
        return null;
    }

    /// Panics if there is none since thats a compiler bug
    pub fn enclosingFn(self: *const Scope) *const Scope {
        var curr: ?*const Scope = self;
        while (curr) |s| : (curr = s.parent) {
            if (s.kind != .function)
                continue;
            return s;
        }
        @panic("unexpted no enclosing function");
    }

    pub fn define(self: *Scope, name: []const u8, sym: Symbol, allocator: Allocator) !void {
        if (self.lookup(name) != null) {
            return error.AlreadyDefined;
        }
        try self.symbols.put(allocator, name, sym);
    }
};

ty: Type.Handle,
kind: Kind,
data: Data = .{ .empty = 0 },
mut: bool = false,
root: Token.Handle,

pub const Kind = enum {
    variable,
    param,
    function,
    module,
};

// just in case theres ever more
pub const Data = union {
    empty: u0,
    module: *Ast,
};
