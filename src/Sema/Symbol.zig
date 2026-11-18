const std = @import("std");
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

const typet = @import("Type.zig");
const Type = typet.Type;

const Token = @import("../lex.zig").Token;

pub const Symbol = @This();

pub const Scope = struct {
    parent: ?*const Scope,
    symbols: StringHashMapUnmanaged(Symbol) = .empty,
    kind: Kind,

    pub const Kind = union {
        root: null,
        function: Type.Handle,
        loop: null,
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
};

name: []const u8,
ty: Type.Handle,
kind: Kind,
mut: bool = false,
root: Token.Handle,

pub const Kind = enum {
    variable,
    param,
    function,
    module,
};
