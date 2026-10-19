//! The slice of the CPython 3.15 C API that Shakti uses, declared by hand.
//!
//! Every object is opaque: nothing here depends on the layout of `PyObject`,
//! which differs between the default and free-threaded builds. Types are
//! created from `PySlot` arrays (PEP 793), instance data lives behind
//! `Py_tp_extra_basicsize` (PEP 697), and refcounts go through `Py_IncRef` /
//! `Py_DecRef`. That keeps the build free of `Python.h` and translate-c.
//!
//! Numeric constants are copied from the 3.15 headers. `tools/check_abi.py`
//! compares them against the headers of the interpreter you build for, so
//! a renumbering in a later 3.15 pre-release is caught before it bites.

pub const Object = opaque {};
pub const TypeObject = opaque {};
pub const ThreadState = opaque {};
pub const ssize = isize;

// --- function pointer types ----------------------------------------------------

pub const FastCallKw = *const fn (?*Object, ?[*]const *Object, ssize, ?*Object) callconv(.c) ?*Object;
pub const Getter = *const fn (*Object, ?*anyopaque) callconv(.c) ?*Object;
pub const Setter = *const fn (*Object, ?*Object, ?*anyopaque) callconv(.c) c_int;
pub const SendFunc = *const fn (*Object, ?*Object, *?*Object) callconv(.c) c_int;
pub const NewFunc = *const fn (*TypeObject, *Object, ?*Object) callconv(.c) ?*Object;
pub const Destructor = *const fn (*Object) callconv(.c) void;
pub const Inquiry = *const fn (*Object) callconv(.c) c_int;
pub const VisitProc = *const fn (*Object, ?*anyopaque) callconv(.c) c_int;
pub const TraverseProc = *const fn (*Object, VisitProc, ?*anyopaque) callconv(.c) c_int;
pub const FreeFunc = *const fn (?*anyopaque) callconv(.c) void;
pub const ModExec = *const fn (*Object) callconv(.c) c_int;
pub const UnaryFunc = *const fn (*Object) callconv(.c) ?*Object;
pub const BinaryFunc = *const fn (*Object, *Object) callconv(.c) ?*Object;
pub const TernaryFunc = *const fn (*Object, *Object, *Object) callconv(.c) ?*Object;

// --- ABI structs -----------------------------------------------------------------

pub const MethodDef = extern struct {
    name: ?[*:0]const u8,
    meth: ?*const anyopaque,
    flags: c_int,
    doc: ?[*:0]const u8,
};

pub const GetSetDef = extern struct {
    name: ?[*:0]const u8,
    get: ?Getter,
    set: ?Setter,
    doc: ?[*:0]const u8,
    closure: ?*anyopaque,
};

/// `struct PySlot` (3.15). `value` is the anonymous union in C.
pub const Slot = extern struct {
    id: u16,
    flags: u16 = 0,
    reserved: u32 = 0,
    value: extern union {
        ptr: ?*const anyopaque,
        size: ssize,
        int64: i64,
        uint64: u64,
    } = .{ .uint64 = 0 },

    pub const end: Slot = .{ .id = slot_end };

    /// `PySlot_DATA`: a pointer the interpreter may keep (names, docs, abi info).
    pub fn data(id: u16, ptr: *const anyopaque) Slot {
        return .{ .id = id, .flags = SLOT_INTPTR, .value = .{ .ptr = ptr } };
    }
    /// `PySlot_STATIC_DATA`: a static table (methods, getset, members).
    pub fn static(id: u16, ptr: *const anyopaque) Slot {
        return .{ .id = id, .flags = SLOT_STATIC, .value = .{ .ptr = ptr } };
    }
    /// `PySlot_FUNC`.
    pub fn func(id: u16, f: *const anyopaque) Slot {
        return .{ .id = id, .value = .{ .ptr = f } };
    }
    /// A slot whose value is a size (`Py_tp_extra_basicsize`, ...).
    pub fn size(id: u16, n: ssize) Slot {
        return .{ .id = id, .value = .{ .size = n } };
    }
    /// A slot whose value is an unsigned integer (`Py_tp_flags`, `Py_mod_gil`, ...).
    pub fn uint(id: u16, n: u64) Slot {
        return .{ .id = id, .value = .{ .uint64 = n } };
    }
};

/// `PyCriticalSection`: a per-object lock in the free-threaded build (a no-op in
/// the regular build).
///
/// Example
///     >>> var cs: c.CriticalSection = undefined;
///     >>> c.PyCriticalSection_Begin(&cs, obj);
///     >>> defer c.PyCriticalSection_End(&cs);
///
/// Note
///     - It is linked into the thread state while held, so it must stay on the stack
///       of the function that called `PyCriticalSection_Begin`.
pub const CriticalSection = extern struct {
    prev: usize,
    mutex: ?*anyopaque,
};

/// `Py_buffer`. `obj` is an owned reference, dropped by `PyBuffer_Release`.
pub const Buffer = extern struct {
    buf: ?*anyopaque,
    obj: ?*Object,
    len: ssize,
    itemsize: ssize,
    readonly: c_int,
    ndim: c_int,
    format: ?[*:0]u8,
    shape: ?*ssize,
    strides: ?*ssize,
    suboffsets: ?*ssize,
    internal: ?*anyopaque,
};

/// `struct PyABIInfo` (3.15): which ABI the module was built for (`Py_mod_abi`).
pub const ABIInfo = extern struct {
    major: u8 = 1,
    minor: u8 = 0,
    flags: u16,
    build_version: u32,
    abi_version: u32,
};

// --- constants ---------------------------------------------------------------------

pub const SLOT_OPTIONAL: u16 = 0x0001;
pub const SLOT_STATIC: u16 = 0x0002;
pub const SLOT_INTPTR: u16 = 0x0004;

pub const slot_end: u16 = 0;
pub const Py_mp_subscript: u16 = 5;
pub const Py_mp_ass_subscript: u16 = 90;
pub const Py_mp_length: u16 = 91;
pub const Py_sq_contains: u16 = 41;
pub const Py_nb_absolute: u16 = 6;
pub const Py_nb_add: u16 = 7;
pub const Py_nb_and: u16 = 8;
pub const Py_nb_divmod: u16 = 10;
pub const Py_nb_float: u16 = 11;
pub const Py_nb_floor_divide: u16 = 12;
pub const Py_nb_index: u16 = 13;
pub const Py_nb_inplace_add: u16 = 14;
pub const Py_nb_inplace_and: u16 = 15;
pub const Py_nb_inplace_floor_divide: u16 = 16;
pub const Py_nb_inplace_lshift: u16 = 17;
pub const Py_nb_inplace_multiply: u16 = 18;
pub const Py_nb_inplace_or: u16 = 19;
pub const Py_nb_inplace_power: u16 = 20;
pub const Py_nb_inplace_remainder: u16 = 21;
pub const Py_nb_inplace_rshift: u16 = 22;
pub const Py_nb_inplace_subtract: u16 = 23;
pub const Py_nb_inplace_true_divide: u16 = 24;
pub const Py_nb_inplace_xor: u16 = 25;
pub const Py_nb_int: u16 = 26;
pub const Py_nb_invert: u16 = 27;
pub const Py_nb_lshift: u16 = 28;
pub const Py_nb_multiply: u16 = 29;
pub const Py_nb_negative: u16 = 30;
pub const Py_nb_or: u16 = 31;
pub const Py_nb_positive: u16 = 32;
pub const Py_nb_power: u16 = 33;
pub const Py_nb_remainder: u16 = 34;
pub const Py_nb_rshift: u16 = 35;
pub const Py_nb_subtract: u16 = 36;
pub const Py_nb_true_divide: u16 = 37;
pub const Py_nb_xor: u16 = 38;
pub const Py_nb_matrix_multiply: u16 = 75;
pub const Py_nb_inplace_matrix_multiply: u16 = 76;
pub const Py_tp_call: u16 = 50;
pub const Py_tp_descr_get: u16 = 54;
pub const Py_tp_descr_set: u16 = 55;
pub const Py_tp_getattro: u16 = 58;
pub const Py_tp_hash: u16 = 59;
pub const Py_tp_richcompare: u16 = 67;
pub const Py_tp_setattro: u16 = 69;
pub const Py_tp_str: u16 = 70;
pub const Py_tp_clear: u16 = 51;
pub const Py_tp_dealloc: u16 = 52;
pub const Py_tp_finalize: u16 = 80;
pub const Py_tp_doc: u16 = 56;
pub const Py_tp_init: u16 = 60;
pub const Py_tp_base: u16 = 48;
pub const Py_nb_bool: u16 = 9;
pub const Py_tp_methods: u16 = 64;
pub const Py_tp_new: u16 = 65;
pub const Py_tp_traverse: u16 = 71;
pub const Py_tp_iter: u16 = 62;
pub const Py_tp_iternext: u16 = 63;
pub const Py_tp_repr: u16 = 66;
pub const Py_tp_getset: u16 = 73;
pub const Py_tp_free: u16 = 74;
pub const Py_tp_name: u16 = 95;
pub const Py_tp_extra_basicsize: u16 = 97;
pub const Py_tp_flags: u16 = 99;
pub const Py_am_await: u16 = 77;
pub const Py_am_send: u16 = 81;
pub const Py_mod_exec: u16 = 85;
pub const Py_mod_multiple_interpreters: u16 = 86;
pub const Py_mod_gil: u16 = 87;
pub const Py_mod_name: u16 = 100;
pub const Py_mod_doc: u16 = 101;
pub const Py_mod_methods: u16 = 103;
pub const Py_mod_abi: u16 = 109;

/// `Py_mod_gil` value: the module needs the GIL (3.15t enables it on import); for state that is not
/// thread-safe.
pub const Py_MOD_GIL_USED: u64 = 0;
/// `Py_mod_gil` value: the module is safe to run without the GIL.
pub const Py_MOD_GIL_NOT_USED: u64 = 1;
pub const Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED: u64 = 0;

pub const PyABIInfo_GIL: u16 = 0x0002;
pub const PyABIInfo_FREETHREADED: u16 = 0x0004;
/// `_Py_PACK_VERSION(3, 15)`
pub const version_3_15: u32 = 0x030F0000;

pub const Py_TPFLAGS_DEFAULT: u64 = 0;
pub const Py_TPFLAGS_MANAGED_WEAKREF: u64 = 1 << 3;
pub const Py_TPFLAGS_MANAGED_DICT: u64 = 1 << 4;
pub const Py_TPFLAGS_DISALLOW_INSTANTIATION: u64 = 1 << 7;
pub const Py_TPFLAGS_BASETYPE: u64 = 1 << 10;
pub const Py_TPFLAGS_HAVE_GC: u64 = 1 << 14;

pub const METH_NOARGS: c_int = 0x0004;
pub const METH_O: c_int = 0x0008;
pub const METH_FASTCALL: c_int = 0x0080;
pub const METH_KEYWORDS: c_int = 0x0002;
pub const METH_CLASS: c_int = 0x0010;
pub const METH_STATIC: c_int = 0x0020;

pub const PyBUF_SIMPLE: c_int = 0;
pub const PyBUF_WRITABLE: c_int = 0x0001;

pub const PYGEN_RETURN: c_int = 0;
pub const PYGEN_ERROR: c_int = -1;
pub const PYGEN_NEXT: c_int = 1;

pub const Py_CONSTANT_NONE: c_uint = 0;
pub const Py_CONSTANT_FALSE: c_uint = 1;
pub const Py_CONSTANT_TRUE: c_uint = 2;
pub const Py_CONSTANT_NOT_IMPLEMENTED: c_uint = 4;

pub const Py_LT: c_int = 0;
pub const Py_LE: c_int = 1;
pub const Py_EQ: c_int = 2;
pub const Py_NE: c_int = 3;
pub const Py_GT: c_int = 4;
pub const Py_GE: c_int = 5;

// --- functions ----------------------------------------------------------------------

pub extern fn Py_IncRef(?*Object) void;
pub extern fn Py_DecRef(?*Object) void;
pub extern fn Py_GetConstantBorrowed(c_uint) *Object;
pub extern fn Py_TYPE(*Object) *TypeObject;

pub extern fn PyErr_SetString(*Object, [*:0]const u8) void;
pub extern fn PyErr_SetObject(*Object, *Object) void;
pub extern fn PyErr_SetFromErrno(*Object) ?*Object;
pub extern fn PyErr_Occurred() ?*Object;
pub extern fn PyErr_NoMemory() ?*Object;
pub extern fn PyErr_CheckSignals() c_int;
pub extern fn PyErr_GetRaisedException() ?*Object;
pub extern fn PyErr_SetRaisedException(?*Object) void;
pub extern fn PyErr_ExceptionMatches(*Object) c_int;
pub extern fn PyErr_Clear() void;
pub extern fn PyErr_WriteUnraisable(?*Object) void;
pub extern fn PyErr_GivenExceptionMatches(?*Object, ?*Object) c_int;
pub extern fn PyErr_FormatUnraisable([*:0]const u8, ...) void;

pub extern fn PyEval_SaveThread() ?*ThreadState;
pub extern fn PyEval_RestoreThread(?*ThreadState) void;
pub extern fn PyCriticalSection_Begin(*CriticalSection, *Object) void;
pub extern fn PyCriticalSection_End(*CriticalSection) void;

pub extern fn PyLong_FromLongLong(c_longlong) ?*Object;
pub extern fn PyLong_FromUnsignedLongLong(c_ulonglong) ?*Object;
/// Copies the int `obj` into `buffer` (`n` bytes, two's complement); returns the bytes the
/// value needs (more than `n`: it did not fit), or -1 with an exception set.
pub extern fn PyLong_AsNativeBytes(obj: *Object, buffer: *anyopaque, n: ssize, flags: c_int) ssize;
pub const Py_ASNATIVEBYTES_NATIVE_ENDIAN: c_int = 3;
pub const Py_ASNATIVEBYTES_ALLOW_INDEX: c_int = 16;
pub extern fn PyNumber_Index(*Object) ?*Object;
pub extern fn PyFloat_FromDouble(f64) ?*Object;
pub extern fn PyFloat_AsDouble(*Object) f64;
pub extern fn PyBool_FromLong(c_long) ?*Object;
pub extern fn PyObject_IsTrue(*Object) c_int;

pub extern fn PyUnicode_EqualToUTF8(*Object, [*:0]const u8) c_int;
pub extern fn PyUnicode_InternFromString([*:0]const u8) ?*Object;
pub extern fn PyUnicode_FromFormat([*:0]const u8, ...) ?*Object;
pub extern fn PyUnicode_FSConverter(?*Object, *?*Object) c_int;
pub extern fn PyBytes_AsString(*Object) ?[*:0]u8;
pub extern fn PyBytes_FromStringAndSize(?[*]const u8, ssize) ?*Object;
pub extern fn PyObject_GetBuffer(*Object, *Buffer, c_int) c_int;
pub extern fn PyBuffer_Release(*Buffer) void;
pub extern fn PyTuple_Size(*Object) ssize;
pub extern fn PyTuple_GetItem(*Object, ssize) ?*Object;
pub extern fn PyTuple_New(ssize) ?*Object;
pub extern fn PySequence_Tuple(*Object) ?*Object;
pub extern fn PySequence_Check(*Object) c_int;
pub extern fn PyMem_Malloc(usize) ?*anyopaque;
pub extern fn PyMem_Free(?*anyopaque) void;
pub extern fn PyTuple_SetItem(*Object, ssize, *Object) c_int;
pub extern fn PyList_New(ssize) ?*Object;
pub extern fn PyList_GetItem(*Object, ssize) ?*Object;
pub extern fn PyList_Size(*Object) ssize;
pub extern fn PyList_Append(*Object, *Object) c_int;
pub extern fn PyList_SetItem(*Object, ssize, *Object) c_int;
pub extern fn PyErr_NewExceptionWithDoc([*:0]const u8, ?[*:0]const u8, ?*Object, ?*Object) ?*Object;
pub extern fn PyUnicode_Decode([*]const u8, ssize, ?[*:0]const u8, ?[*:0]const u8) ?*Object;
pub extern fn PyUnicode_AsEncodedString(*Object, ?[*:0]const u8, ?[*:0]const u8) ?*Object;
pub extern fn PyUnicode_AsUTF8AndSize(*Object, ?*ssize) ?[*:0]const u8;
/// `PyUnicode_Check` (a macro in the headers): is `o` a `str` or a subclass?
/// Done with `PyType_IsSubtype`.
pub fn PyUnicode_Check(o: *Object) c_int {
    return @intFromBool(PyType_IsSubtype(Py_TYPE(o), PyUnicode_Type) != 0);
}
pub const PyUnicode_Type = @extern(*TypeObject, .{ .name = "PyUnicode_Type" });
pub const PyLong_Type = @extern(*TypeObject, .{ .name = "PyLong_Type" });
pub const PyBytes_Type = @extern(*TypeObject, .{ .name = "PyBytes_Type" });
pub const PyTuple_Type = @extern(*TypeObject, .{ .name = "PyTuple_Type" });
/// `PyBytes_Check` (a macro in the headers): is `o` a `bytes` or a subclass?
pub fn PyBytes_Check(o: *Object) c_int {
    return @intFromBool(PyType_IsSubtype(Py_TYPE(o), PyBytes_Type) != 0);
}
/// `PyLong_Check` (a macro in the headers); `bool` is a subclass of `int`.
pub fn PyLong_Check(o: *Object) c_int {
    return @intFromBool(PyType_IsSubtype(Py_TYPE(o), PyLong_Type) != 0);
}
pub extern fn PyObject_CheckBuffer(*Object) c_int;
pub extern fn PyUnicode_FromString([*:0]const u8) ?*Object;
pub extern fn PyUnicode_FromStringAndSize(?[*]const u8, ssize) ?*Object;
pub extern fn PyUnicode_Concat(*Object, *Object) ?*Object;
pub extern fn PyUnicode_GetLength(*Object) ssize;
pub extern fn PyUnicode_ReadChar(*Object, ssize) u32;
pub extern fn PyBytes_AsStringAndSize(*Object, *?[*]u8, *ssize) c_int;
pub extern fn PyTuple_Pack(ssize, ...) ?*Object;
pub extern fn PyLong_FromLong(c_long) ?*Object;
pub extern fn PyObject_Str(*Object) ?*Object;
pub extern fn PyObject_RichCompareBool(*Object, *Object, c_int) c_int;
pub extern fn PyObject_Call(*Object, *Object, ?*Object) ?*Object;
pub extern fn PyImport_ImportModule([*:0]const u8) ?*Object;
pub extern fn PyDict_New() ?*Object;
pub extern fn PyDict_SetItem(*Object, *Object, *Object) c_int;
pub extern fn PyDict_Size(*Object) ssize;
pub extern fn PyDict_Next(*Object, *ssize, *?*Object, *?*Object) c_int;
pub extern fn PyDict_GetItemStringRef(*Object, [*:0]const u8, *?*Object) c_int;

pub extern fn PyIter_Send(*Object, *Object, *?*Object) c_int;
pub extern fn PyContext_CopyCurrent() ?*Object;
pub extern fn PyContext_Enter(*Object) c_int;
pub extern fn PyContext_Exit(*Object) c_int;
pub extern fn PyObject_GetAttrString(*Object, [*:0]const u8) ?*Object;
pub extern fn PyObject_CallNoArgs(*Object) ?*Object;
pub extern fn PyObject_CallOneArg(*Object, *Object) ?*Object;

pub extern fn PyType_FromSlots([*]const Slot) ?*Object;
pub extern fn PyType_IsSubtype(*TypeObject, *TypeObject) c_int;
pub extern fn PyType_GenericAlloc(*TypeObject, ssize) ?*Object;
pub extern fn PyType_GetSlot(*TypeObject, c_int) ?*anyopaque;
pub extern fn PyObject_GetTypeData(*Object, *TypeObject) ?*anyopaque;
pub extern fn PyObject_GC_UnTrack(*anyopaque) void;
pub extern fn PyObject_GC_Track(*anyopaque) void;
pub extern fn PyObject_GC_IsTracked(*Object) c_int;
pub extern fn PyObject_CallFinalizerFromDealloc(*Object) c_int;
pub extern fn PyObject_GenericGetAttr(*Object, *Object) ?*Object;
pub extern fn PyObject_GenericSetAttr(*Object, *Object, ?*Object) c_int;
pub extern fn PyObject_GenericHash(*Object) ssize;
pub extern fn PyObject_SetAttrString(*Object, [*:0]const u8, ?*Object) c_int;
pub extern fn PyObject_ClearWeakRefs(*Object) void;
pub extern fn PyObject_VisitManagedDict(*Object, VisitProc, ?*anyopaque) c_int;
pub extern fn PyObject_ClearManagedDict(*Object) void;
pub extern fn PyObject_GenericGetDict(*Object, ?*anyopaque) ?*Object;
pub extern fn PyObject_GenericSetDict(*Object, ?*Object, ?*anyopaque) c_int;
pub extern fn Py_GenericAlias(*Object, *Object) ?*Object;

pub extern fn PyModule_AddType(*Object, *TypeObject) c_int;
pub extern fn PyModule_AddObjectRef(*Object, [*:0]const u8, *Object) c_int;
pub extern fn PyModule_AddIntConstant(*Object, [*:0]const u8, c_long) c_int;
pub extern fn PyModule_AddStringConstant(*Object, [*:0]const u8, [*:0]const u8) c_int;

pub extern var PyExc_TypeError: *Object;
pub extern var PyExc_BufferError: *Object;
pub extern var PyExc_ValueError: *Object;
pub extern var PyExc_IndexError: *Object;
pub extern var PyExc_RuntimeError: *Object;
pub extern var PyExc_OverflowError: *Object;
pub extern var PyExc_OSError: *Object;
pub extern var PyExc_TimeoutError: *Object;
pub extern var PyExc_NotImplementedError: *Object;
pub extern var PyExc_StopIteration: *Object;
pub extern var PyExc_Exception: *Object;
pub extern var PyExc_AttributeError: *Object;
pub extern var PyExc_KeyError: *Object;
pub extern var PyExc_ZeroDivisionError: *Object;
pub extern var PyExc_BlockingIOError: *Object;
pub extern var PyExc_FileExistsError: *Object;

/// `types.CoroutineType` (not subclassable, so an exact type check suffices).
pub const PyCoro_Type = @extern(*TypeObject, .{ .name = "PyCoro_Type" });
