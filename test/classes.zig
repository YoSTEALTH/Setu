//! The classes of `setu_classes` (`setu_classes.zig`), a test-only extension with one `setu.Class`
//! per protocol hook family that Shakti itself does not use (comparisons, numbers, containers,
//! `__call__`, iterators, attributes, descriptors, static / class methods, class attributes,
//! weakrefs, `__dict__`, pickling, generics, `__finalize__`). `class_test.py` drives it.

const std = @import("std");
const setu = @import("setu");

const c = setu.c;
const py = setu.py;
const Object = c.Object;
const Error = py.Error;

/// Setu settings: the classes are `setu_classes.<Name>`.
pub const setu_options: setu.Options = .{ .module = "setu_classes" };

/// A 2D vector with integer coordinates: comparisons, hashing, numbers, pickling.
pub const Vec = struct {
    x: i64 = 0,
    y: i64 = 0,

    pub const basetype = true;
    pub const pickle = true;
    /// How many coordinates a `Vec` has.
    pub const DIMS = 2;
    /// What `__repr__` starts with.
    pub const NAME = "Vec";
    /// The scale factor `unit()` uses.
    pub const UNIT = 1.0;

    /// Sets the coordinates.
    pub fn __init__(self: *Vec, a: struct { x: i64 = 0, y: i64 = 0 }) void {
        self.x = a.x;
        self.y = a.y;
    }

    /// `Vec(x, y)`.
    pub fn __repr__(self: *const Vec) Error!*Object {
        var buf: [64]u8 = undefined; // fits 2 x 20 digits
        const text = std.fmt.bufPrint(&buf, "Vec({d}, {d})", .{ self.x, self.y }) catch unreachable;
        return py.new(text);
    }

    /// `(x, y)`.
    pub fn __str__(self: *const Vec) Error!*Object {
        var buf: [64]u8 = undefined; // fits 2 x 20 digits
        const text = std.fmt.bufPrint(&buf, "({d}, {d})", .{ self.x, self.y }) catch unreachable;
        return py.new(text);
    }

    /// Same coordinates?
    pub fn __eq__(self: *const Vec, other: *const Vec) bool {
        return self.x == other.x and self.y == other.y;
    }

    /// Shorter (squared length), then by `x`?
    pub fn __lt__(self: *const Vec, other: *const Vec) bool {
        if (self.norm2() != other.norm2()) return self.norm2() < other.norm2();
        return self.x < other.x;
    }

    /// From the coordinates, like `hash((x, y))` would be.
    pub fn __hash__(self: *const Vec) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&[2]i64{ self.x, self.y }));
    }

    /// Not the zero vector?
    pub fn __bool__(self: *const Vec) bool {
        return self.x != 0 or self.y != 0;
    }

    /// The sum.
    pub fn __add__(self: *const Vec, other: *const Vec) Error!*Object {
        return VecType.new(.{ .x = self.x + other.x, .y = self.y + other.y });
    }

    /// The difference.
    pub fn __sub__(self: *const Vec, other: *const Vec) Error!*Object {
        return VecType.new(.{ .x = self.x - other.x, .y = self.y - other.y });
    }

    /// Scaled by `k`.
    pub fn __mul__(self: *const Vec, k: i64) Error!*Object {
        return VecType.new(.{ .x = self.x * k, .y = self.y * k });
    }

    /// Scaled by `k` (`k * v`).
    pub fn __rmul__(self: *const Vec, k: i64) Error!*Object {
        return VecType.new(.{ .x = self.x * k, .y = self.y * k });
    }

    /// Adds `other` in place.
    pub fn __iadd__(self: *Vec, other: *const Vec) void {
        self.x += other.x;
        self.y += other.y;
    }

    /// Pointing the other way.
    pub fn __neg__(self: *const Vec) Error!*Object {
        return VecType.new(.{ .x = -self.x, .y = -self.y });
    }

    /// The length.
    pub fn __abs__(self: *const Vec) f64 {
        // cast: test values are small
        return @sqrt(@as(f64, @floatFromInt(self.norm2())));
    }

    /// The squared length.
    pub fn norm2(self: *const Vec) i64 {
        return self.x * self.x + self.y * self.y;
    }

    /// A new vector of the class `cls` (a subclass too).
    ///
    /// Example
    ///     >>> Vec.from_pair(1, 2)
    ///     Vec(1, 2)
    pub fn from_pair(cls: *c.TypeObject, x: i64, y: i64) Error!*Object {
        const obj = c.PyObject_CallNoArgs(@ptrCast(cls)) orelse return error.PythonError;
        VecType.data(obj).* = .{ .x = x, .y = y };
        return obj;
    }

    /// The dot product of two vectors.
    ///
    /// Example
    ///     >>> Vec.dot(Vec(1, 2), Vec(3, 4))
    ///     11
    pub fn dot(a: *const Vec, b: *const Vec) i64 {
        return a.x * b.x + a.y * b.y;
    }

    /// Releases the buffer the last call kept, then keeps `buf` (a method's `py.OwnedWritableBuffer`)
    /// until the next call and fills it with `x`; `fill_into()` only releases. Returns how many bytes.
    ///
    /// Example
    ///     >>> b = bytearray(2)
    ///     >>> Vec(7).fill_into(b)
    ///     2
    ///     >>> b
    ///     bytearray(b'\x07\x07')
    ///     >>> b.append(1)
    ///     BufferError: Existing exports of data: object cannot be re-sized
    pub fn fill_into(self: *const Vec, buf: ?py.OwnedWritableBuffer, scale: ?u8) usize {
        if (vec_kept) |k| k.deinit();
        vec_kept = buf;
        const b = buf orelse return 0;
        // cast: test values are small
        @memset(b.data, @as(u8, @truncate(@as(u64, @bitCast(self.x)))) *% (scale orelse 1));
        return b.data.len;
    }
};
/// What `Vec.fill_into` keeps.
var vec_kept: ?py.OwnedWritableBuffer = null;
pub const VecType = setu.Class(Vec, @embedFile("classes.zig"));

/// A `Vec` with a label: a Setu subclass, pickled with its base's fields.
pub const Labeled = struct {
    label: ?*Object = null,

    pub const base = VecType;
    pub const pickle = true;

    /// Sets the label (the coordinates stay 0).
    pub fn __init__(self: *Labeled, label: ?*Object) void {
        if (label) |l| py.incref(l);
        py.decref(self.label);
        self.label = label;
    }

    /// The label.
    pub fn get_label(self: *const Labeled) *Object {
        const l = self.label orelse py.none();
        py.incref(l);
        return l;
    }
};
pub const LabeledType = setu.Class(Labeled, @embedFile("classes.zig"));

/// Only `__lt__`: still hashable (by identity), as a Python class would be.
pub const Ordered = struct {
    rank: i64 = 0,

    /// Sets the rank.
    pub fn __init__(self: *Ordered, rank: i64) void {
        self.rank = rank;
    }

    /// Lower rank?
    pub fn __lt__(self: *const Ordered, other: *const Ordered) bool {
        return self.rank < other.rank;
    }

    /// The rank (an int property).
    ///
    /// Example
    ///     >>> o = Ordered(1)
    ///     >>> o.rank = 3
    ///     >>> o.rank
    ///     3
    pub fn get_rank(self: *const Ordered) i64 {
        return self.rank;
    }

    /// Sets the rank.
    pub fn set_rank(self: *Ordered, value: i64) void {
        self.rank = value;
    }
};
pub const OrderedType = setu.Class(Ordered, @embedFile("classes.zig"));

/// An integer with every number operator, to check the slots and the reflected ones.
pub const Num = struct {
    v: i64 = 0,

    /// Sets the value.
    pub fn __init__(self: *Num, v: i64) void {
        self.v = v;
    }

    /// A new `Num`.
    fn make(v: i64) Error!*Object {
        return NumType.new(.{ .v = v });
    }

    /// `self + other`.
    pub fn __add__(self: *const Num, other: i64) Error!*Object {
        return make(self.v + other);
    }
    /// `other + self`.
    pub fn __radd__(self: *const Num, other: i64) Error!*Object {
        return make(other + self.v);
    }
    /// `self - other`.
    pub fn __sub__(self: *const Num, other: i64) Error!*Object {
        return make(self.v - other);
    }
    /// `other - self`.
    pub fn __rsub__(self: *const Num, other: i64) Error!*Object {
        return make(other - self.v);
    }
    /// `self * other`.
    pub fn __mul__(self: *const Num, other: i64) Error!*Object {
        return make(self.v * other);
    }
    /// `self / other`.
    pub fn __truediv__(self: *const Num, other: i64) Error!f64 {
        if (other == 0) return py.raise(c.PyExc_ZeroDivisionError, "division by zero", .{});
        // cast: test values are small
        return @as(f64, @floatFromInt(self.v)) / @as(f64, @floatFromInt(other));
    }
    /// `self // other`.
    pub fn __floordiv__(self: *const Num, other: i64) Error!*Object {
        if (other == 0) return py.raise(c.PyExc_ZeroDivisionError, "division by zero", .{});
        return make(@divFloor(self.v, other));
    }
    /// `self % other`.
    pub fn __mod__(self: *const Num, other: i64) Error!*Object {
        if (other == 0) return py.raise(c.PyExc_ZeroDivisionError, "division by zero", .{});
        return make(@mod(self.v, other));
    }
    /// `divmod(self, other)`.
    pub fn __divmod__(self: *const Num, other: i64) Error!struct { i64, i64 } {
        if (other == 0) return py.raise(c.PyExc_ZeroDivisionError, "division by zero", .{});
        return .{ @divFloor(self.v, other), @mod(self.v, other) };
    }
    /// `self ** other`.
    pub fn __pow__(self: *const Num, other: u6) Error!*Object {
        return make(std.math.pow(i64, self.v, other));
    }
    /// `self << other`.
    pub fn __lshift__(self: *const Num, other: u6) Error!*Object {
        return make(self.v << other);
    }
    /// `self >> other`.
    pub fn __rshift__(self: *const Num, other: u6) Error!*Object {
        return make(self.v >> other);
    }
    /// `self & other`.
    pub fn __and__(self: *const Num, other: i64) Error!*Object {
        return make(self.v & other);
    }
    /// `self | other`.
    pub fn __or__(self: *const Num, other: i64) Error!*Object {
        return make(self.v | other);
    }
    /// `self ^ other`.
    pub fn __xor__(self: *const Num, other: i64) Error!*Object {
        return make(self.v ^ other);
    }
    /// `self @ other`: the product of two `Num`s.
    pub fn __matmul__(self: *const Num, other: *const Num) i64 {
        return self.v * other.v;
    }
    /// `self -= other`, in place.
    pub fn __isub__(self: *Num, other: i64) void {
        self.v -= other;
    }
    /// `self **= other`, in place.
    pub fn __ipow__(self: *Num, other: u6) void {
        self.v = std.math.pow(i64, self.v, other);
    }
    /// `+self`: the value as an `int`.
    pub fn __pos__(self: *const Num) i64 {
        return self.v;
    }
    /// `~self`.
    pub fn __invert__(self: *const Num) Error!*Object {
        return make(~self.v);
    }
    /// `int(self)`.
    pub fn __int__(self: *const Num) i64 {
        return self.v;
    }
    /// `float(self)`.
    pub fn __float__(self: *const Num) f64 {
        return @floatFromInt(self.v); // cast: test values are small
    }
    /// `operator.index(self)`: usable as a list index.
    pub fn __index__(self: *const Num) i64 {
        return self.v;
    }
};
pub const NumType = setu.Class(Num, @embedFile("classes.zig"));

/// A fixed-size container of up to 4 objects: `len`, `[]`, `in`, `del`, iteration;
/// generic (`Bag[int]`), with weakrefs and a `__dict__`.
pub const Bag = struct {
    items: [4]?*Object = @splat(null),
    len: usize = 0,

    pub const basetype = true;
    pub const weakref = true;
    pub const dict = true;
    pub const type_params = "T";

    /// Puts each positional argument in (at most 4).
    pub fn __init__(self: *Bag, a: setu.CallArgs) Error!void {
        if (a.kwargs) |kw| if (c.PyDict_Size(kw) > 0) return py.raiseTypeError("Bag() takes no keyword arguments", .{});
        const n: usize = @intCast(c.PyTuple_Size(a.args)); // cast: a size, never < 0
        if (n > self.items.len) return py.raiseValueError("at most 4 items", .{});
        for (0..n) |i| {
            const o = c.PyTuple_GetItem(a.args, @intCast(i)).?; // cast: an index < 4
            py.incref(o);
            self.items[i] = o;
        }
        self.len = n;
    }

    /// How many items.
    pub fn __len__(self: *const Bag) usize {
        return self.len;
    }

    /// The item at `index`.
    ///
    /// Type
    ///     return: T
    pub fn __getitem__(self: *const Bag, index: usize) Error!*Object {
        if (index >= self.len) return py.raiseIndexError("Bag index out of range", .{});
        const o = self.items[index].?;
        py.incref(o);
        return o;
    }

    /// Replaces the item at `index`.
    ///
    /// Type
    ///     value: T
    pub fn __setitem__(self: *Bag, index: usize, value: *Object) Error!void {
        if (index >= self.len) return py.raiseIndexError("Bag index out of range", .{});
        py.incref(value);
        py.decref(self.items[index]);
        self.items[index] = value;
    }

    /// Removes the item at `index`.
    pub fn __delitem__(self: *Bag, index: usize) Error!void {
        if (index >= self.len) return py.raiseIndexError("Bag index out of range", .{});
        const old = self.items[index];
        std.mem.copyForwards(?*Object, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
        self.len -= 1;
        self.items[self.len] = null;
        py.decref(old);
    }

    /// Is an item equal to `item`?
    pub fn __contains__(self: *const Bag, item: *Object) Error!bool {
        for (self.items[0..self.len]) |o| {
            const r = c.PyObject_RichCompareBool(o.?, item, c.Py_EQ);
            if (r < 0) return error.PythonError;
            if (r != 0) return true;
        }
        return false;
    }

    /// An iterator over the items.
    ///
    /// Type
    ///     return: Iterator[T]
    pub fn __iter__(self: *Object) Error!*Object {
        py.incref(self);
        return BagIterType.new(.{ .bag = self });
    }
};
pub const BagType = setu.Class(Bag, @embedFile("classes.zig"));

/// Iterates a `Bag` (its own iterator: `__next__` without `__iter__`).
pub const BagIter = struct {
    bag: ?*Object = null,
    at: usize = 0,

    pub const instantiable = false;

    /// The next item, or `null` at the end.
    pub fn __next__(self: *BagIter) ?*Object {
        const b = BagType.data(self.bag.?);
        if (self.at >= b.len) return null;
        const o = b.items[self.at].?;
        self.at += 1;
        py.incref(o);
        return o;
    }
};
pub const BagIterType = setu.Class(BagIter, @embedFile("classes.zig"));

/// Counts down from `start` to 1 (`__next__` returning `?i64`); `get_left()` is a method
/// (`plain_methods`), not a property.
pub const Countdown = struct {
    pub const plain_methods = .{"get_left"};
    left: u32 = 0,

    /// How many numbers are left (a method, though it is named like a getter).
    pub fn get_left(self: *const Countdown) u32 {
        return self.left;
    }

    /// Starts at `start`.
    pub fn __init__(self: *Countdown, start: u32) void {
        self.left = start;
    }

    /// The next number, or `null` after 1.
    pub fn __next__(self: *Countdown) ?u32 {
        if (self.left == 0) return null;
        defer self.left -= 1;
        return self.left;
    }
};
pub const CountdownType = setu.Class(Countdown, @embedFile("classes.zig"));

/// Adds `base` to what it is called with (`__call__`).
pub const Adder = struct {
    base: i64 = 0,

    /// Sets `base`.
    pub fn __init__(self: *Adder, base: i64) void {
        self.base = base;
    }

    /// `base + a + b`.
    ///
    /// Example
    ///     >>> Adder(10)(1, b=2)
    ///     13
    pub fn __call__(self: *const Adder, a: i64, o: struct { b: i64 = 0 }) i64 {
        return self.base + a + o.b;
    }

    /// `(first + base, rest, extra)`: a positional-only parameter, then `*rest` and `**extra`.
    ///
    /// Type
    ///     rest:   int
    ///     extra:  int
    ///     return: tuple[int, tuple[int, ...], dict[str, int]]
    pub fn collect(self: *const Adder, first: i64, rest: py.Rest, extra: py.Kwargs) Error!*Object {
        const t = try rest.tuple();
        const d = if (extra.dict) |x| blk: {
            py.incref(x);
            break :blk x;
        } else c.PyDict_New() orelse {
            py.decref(t);
            return error.PythonError;
        };
        return py.new(.{ first + self.base, t, d });
    }
};
pub const AdderType = setu.Class(Adder, @embedFile("classes.zig"));

/// Dynamic attributes: unknown names read as their length; assignments and deletions are
/// counted (`__getattr__`, `__setattr__`, `__delattr__`).
pub const Dyn = struct {
    sets: u32 = 0,
    dels: u32 = 0,

    /// The length of `name`; `AttributeError` for names starting with `no_`.
    pub fn __getattr__(self: *const Dyn, name: []const u8) Error!usize {
        _ = self;
        if (std.mem.startsWith(u8, name, "no_")) return py.raiseAttributeError("no attribute `{s}`", .{name});
        return name.len;
    }

    /// Counts the assignment (stores nothing).
    pub fn __setattr__(self: *Dyn, name: []const u8, value: *Object) void {
        _ = name;
        _ = value;
        self.sets += 1;
    }

    /// Counts the deletion.
    pub fn __delattr__(self: *Dyn, name: []const u8) void {
        _ = name;
        self.dels += 1;
    }

    /// How many assignments.
    pub fn get_sets(self: *const Dyn) u32 {
        return self.sets;
    }

    /// How many deletions.
    pub fn get_dels(self: *const Dyn) u32 {
        return self.dels;
    }
};
pub const DynType = setu.Class(Dyn, @embedFile("classes.zig"));

/// A descriptor holding one int: read from the class it is itself, from an instance its
/// value; `__set__` stores, `__delete__` resets to 0.
pub const Slot = struct {
    value: i64 = 0,

    /// Sets the value.
    pub fn __init__(self: *Slot, value: i64) void {
        self.value = value;
    }

    /// The value (or the descriptor itself when read from the class).
    pub fn __get__(self: *Object, instance: ?*Object, owner: ?*Object) Error!*Object {
        _ = owner;
        if (instance == null) {
            py.incref(self);
            return self;
        }
        return py.new(SlotType.data(self).value);
    }

    /// Stores `value`.
    pub fn __set__(self: *Slot, instance: *Object, value: i64) void {
        _ = instance;
        self.value = value;
    }

    /// Resets to 0.
    pub fn __delete__(self: *Slot, instance: *Object) void {
        _ = instance;
        self.value = 0;
    }
};
pub const SlotType = setu.Class(Slot, @embedFile("classes.zig"));

/// Calls `callback()` when finalized (`__finalize__`), with its fields still set; `link` makes a
/// reference cycle for the GC to break.
pub const Watch = struct {
    callback: ?*Object = null,
    link: ?*Object = null,

    /// Keeps `callback`.
    pub fn __init__(self: *Watch, callback: *Object) void {
        py.incref(callback);
        self.callback = callback;
    }

    /// Calls `callback()`; an error goes to `sys.unraisablehook`.
    pub fn __finalize__(self: *Object) void {
        const cb = WatchType.data(self).callback orelse return;
        const r = c.PyObject_CallNoArgs(cb) orelse return c.PyErr_WriteUnraisable(self);
        py.decref(r);
    }

    /// Any object (`None` by default).
    ///
    /// Type
    ///     return: object
    pub fn get_link(self: *const Watch) *Object {
        const o = self.link orelse py.none();
        py.incref(o);
        return o;
    }

    /// Sets `link`.
    ///
    /// Type
    ///     value: object
    pub fn set_link(self: *Watch, value: *Object) void {
        py.incref(value);
        if (self.link) |old| py.decref(old);
        self.link = value;
    }
};
pub const WatchType = setu.Class(Watch, @embedFile("classes.zig"));

/// An awaitable (`__poll__`) that waits once in the event loop, then gives `result`.
pub const Later = struct {
    result: ?*Object = null,

    /// Keeps `result`.
    ///
    /// Type
    ///     result: object
    pub fn __init__(self: *Later, result: *Object) void {
        py.incref(result);
        self.result = result;
    }

    /// Pending on the first send, then ready with `result`.
    ///
    /// Type
    ///     return: object
    pub fn __poll__(self: *Later, sent: ?*Object) setu.Poll {
        if (sent == null) return .pending;
        const r = self.result orelse py.none();
        py.incref(r);
        return .{ .ready = r };
    }
};
pub const LaterType = setu.Class(Later, @embedFile("classes.zig"));

/// Two ints set in `__new__` only (no `__init__`): the stub declares `__new__`.
///
/// Type
///     b: int | None - `a` when not given
pub const Pair = struct {
    a: i64 = 0,
    b: i64 = 0,

    /// Sets `a` and `b` (`b` defaults to `a`).
    pub fn __new__(self: *Pair, a: i64, b: ?i64) void {
        self.a = a;
        self.b = b orelse a;
    }

    /// `(a, b)`.
    pub fn get_pair(self: *const Pair) struct { i64, i64 } {
        return .{ self.a, self.b };
    }
};
pub const PairType = setu.Class(Pair, @embedFile("classes.zig"));

/// The classes, bases first (also the stub order).
pub const classes = .{
    VecType,
    LabeledType,
    OrderedType,
    NumType,
    BagType,
    BagIterType,
    CountdownType,
    AdderType,
    DynType,
    SlotType,
    WatchType,
    LaterType,
    PairType,
};
