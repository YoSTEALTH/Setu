'''`setu.Class` protocol hooks, through the test extension `setu_classes` (`test/classes.zig`).'''

import array
import gc
import copy
import inspect
import operator
import pickle
import sys
import sysconfig
import types
import weakref
import pytest
import setu_classes as sc
from setu_classes import Vec, Labeled, Ordered, Num, Bag, Countdown, Adder, Dyn, Slot, Watch


def test_one_binary():
    '''The one `setu_classes.so` (no ABI tag) loads here; free-threaded builds keep the GIL off.'''
    assert sc.__file__.endswith('setu_classes.so')
    if sysconfig.get_config_var('Py_GIL_DISABLED'):
        assert not sys._is_gil_enabled()


def test_str_repr():
    v = Vec(1, 2)
    assert repr(v) == 'Vec(1, 2)'
    assert str(v) == '(1, 2)'
    assert f'{v}' == '(1, 2)'


def test_compare():
    assert Vec(1, 2) == Vec(1, 2)
    assert Vec(1, 2) != Vec(2, 1)  # no `__ne__`: `not __eq__`
    assert not (Vec(1, 2) != Vec(1, 2))
    assert Vec(1, 0) < Vec(1, 1)
    assert Vec(1, 1) > Vec(1, 0)  # reflected `__lt__`
    assert Vec(0, 1) < Vec(1, 0) and not Vec(1, 0) < Vec(0, 1)  # same length: by `x`
    assert sorted([Vec(3, 0), Vec(0, 1), Vec(2, 0)]) == [Vec(0, 1), Vec(2, 0), Vec(3, 0)]
    # Another type: `NotImplemented`, so `==` falls back to identity and `<` raises.
    assert Vec(1, 2) != (1, 2)
    assert (Vec(1, 2) == 'x') is False
    assert (Vec(1, 2) == None) is False and Vec(1, 2) != None  # noqa: E711
    assert Vec(1, 2) not in [None, 'x', (1, 2)]
    assert Vec(0, 0) == Labeled('a')  # a subclass instance is a `Vec`
    with pytest.raises(TypeError, match="'<' not supported"):
        Vec(1, 2) < 3
    with pytest.raises(TypeError, match="'<' not supported"):
        Vec(1, 2) < None
    with pytest.raises(TypeError):
        Vec(1, 2) <= Vec(1, 2)  # no `__le__`


def test_hash():
    assert hash(Vec(1, 2)) == hash(Vec(1, 2))
    assert hash(Vec(1, 2)) != hash(Vec(2, 1))
    assert {Vec(1, 2), Vec(1, 2), Vec(0, 0)} == {Vec(1, 2), Vec(0, 0)}
    # Only `__lt__`: still hashable by identity, like a Python class.
    a, b = Ordered(1), Ordered(2)
    assert a < b and not b < a
    assert hash(a) == hash(a) and len({a, b}) == 2
    assert a == a and a != b


def test_eq_without_hash_is_unhashable():
    class Eq(Vec):
        def __eq__(self, other):
            return True

    assert Eq.__hash__ is None
    with pytest.raises(TypeError, match='unhashable'):
        hash(Eq())


def test_numbers():
    v = Vec(1, 2)
    assert v + Vec(3, 4) == Vec(4, 6)
    assert v - Vec(1, 1) == Vec(0, 1)
    assert v * 3 == Vec(3, 6)
    assert 3 * v == Vec(3, 6)  # `__rmul__`
    assert -v == Vec(-1, -2)
    assert abs(Vec(3, 4)) == 5.0
    assert bool(Vec()) is False and bool(v) is True
    with pytest.raises(TypeError, match='unsupported operand'):
        v + 1
    with pytest.raises(TypeError, match="can't multiply sequence"):
        v * 'x'  # `__mul__` gave `NotImplemented`, then `str` refuses a non-int
    w = v
    w += Vec(1, 1)  # `__iadd__` returns `void`: `self`
    assert w is v and v == Vec(2, 3)
    with pytest.raises(TypeError, match=r'unsupported operand type\(s\) for \+='):
        w += 1  # `__iadd__` gave `NotImplemented`, then `__add__` too
    assert w is v and v == Vec(2, 3)
    with pytest.raises(OverflowError, match=r'`Vec.__mul__\(other\)` = 18446744073709551616 is out of range'):
        v * 2**64


def test_number_ops():
    n = Num(7)
    for op, want in [
        (n + 1, 8),
        (1 + n, 8),
        (n - 2, 5),
        (10 - n, 3),
        (n * 3, 21),
        (n // 2, 3),
        (n % 4, 3),
        (n**2, 49),
        (n << 2, 28),
        (n >> 1, 3),
        (n & 3, 3),
        (n | 8, 15),
        (n ^ 1, 6),
        (~n, -8),
    ]:
        assert type(op) is Num and int(op) == want
    assert n / 2 == 3.5
    assert divmod(n, 3) == (2, 1)
    assert n @ Num(3) == 21
    assert +n == 7
    assert int(n) == 7 and float(n) == 7.0
    assert [10, 11, 12, 13, 14, 15, 16, 17][n] == 17  # `__index__`
    assert operator.index(n) == 7
    with pytest.raises(ZeroDivisionError):
        n // 0
    with pytest.raises(TypeError, match='modulus'):
        pow(n, 2, 5)
    m = n
    m -= 2  # `__isub__`
    assert m is n and int(n) == 5
    m **= 2  # `__ipow__`
    assert m is n and int(n) == 25
    m += 1  # no `__iadd__`: `__add__` makes a new one
    assert m is not n and int(m) == 26 and int(n) == 25
    assert Num(3) * 'ab' == 'ababab'  # `__index__`: `str` repeats it
    with pytest.raises(TypeError, match='unsupported operand'):
        n * 1.5
    with pytest.raises(TypeError, match='unsupported operand'):
        'x' - n


def test_container():
    b = Bag(1, 2, 3)
    assert len(b) == 3
    assert b[0] == 1 and b[2] == 3
    with pytest.raises(IndexError):
        b[3]
    b[1] = 'two'
    assert list(b) == [1, 'two', 3]
    del b[0]
    assert list(b) == ['two', 3] and len(b) == 2
    assert 3 in b and 'two' in b and 1 not in b
    with pytest.raises(OverflowError):
        b[-1]
    with pytest.raises(ValueError, match='at most 4'):
        Bag(1, 2, 3, 4, 5)
    with pytest.raises(TypeError, match='does not support item assignment'):
        Vec()[0] = 1


def test_iterators():
    assert list(Countdown(3)) == [3, 2, 1]
    c = Countdown(2)
    assert iter(c) is c
    assert next(c) == 2 and next(c) == 1
    with pytest.raises(StopIteration):
        next(c)
    assert len(Countdown(2**63 - 1)) == 2**63 - 1
    with pytest.raises(OverflowError, match=r'^`len\(\)` of a `Countdown` is too large$'):
        len(Countdown(2**63))
    it = iter(Bag('a', 'b'))
    assert type(it).__name__ == 'BagIter' and iter(it) is it
    assert list(it) == ['a', 'b']
    with pytest.raises(TypeError):
        type(it)()  # not instantiable


@pytest.mark.parametrize('result', [(1, 2), (), ('one',), [3], 7, None])
def test_awaitable_result(result):
    '''`await` / `next()` give the `__poll__` result as is; a tuple is not unpacked (3.14 uses `tp_iternext`).'''

    async def run(w):
        return await w

    w = sc.Later(result)
    coro = run(w)
    assert coro.send(None) is w  # pending: yields itself to the event loop
    with pytest.raises(StopIteration) as e:
        coro.send(None)
    assert e.value.value == result

    w = sc.Later(result)
    assert next(w) is w
    with pytest.raises(StopIteration) as e:
        next(w)
    assert e.value.value == result
    with pytest.raises(RuntimeError):
        next(w)  # already awaited


def test_positional_only_rest_kwargs():
    a = Adder(10)
    assert a.collect(1) == (11, (), {})
    assert a.collect(1, 2, 3, x=4, y=5) == (11, (2, 3), {'x': 4, 'y': 5})
    assert str(inspect.signature(a.collect)) == '(first, /, *rest, **extra)'
    with pytest.raises(TypeError):
        a.collect()  # `first` is required
    assert a.collect(1, first=2) == (11, (), {'first': 2})  # positional-only: the name is free
    assert a.collect(1, **{'': 5}) == (11, (), {'': 5})  # no parameter is named ''
    assert a.count() == 0
    assert a.count(1, 2, 3) == 3  # a leading `*args` on a method
    assert str(inspect.signature(a.count)) == '(*args)'
    with pytest.raises(TypeError, match='takes no keyword arguments'):
        a.count(**{'': 1})


def test_plain_methods():
    c = Countdown(3)
    assert c.get_left() == 3  # a method, though named like a getter
    assert not hasattr(c, 'left')


def test_call():
    add = Adder(10)
    assert add(1) == 11
    assert add(1, 2) == 13
    assert add(a=1, b=5) == 16
    assert callable(add)
    with pytest.raises(TypeError, match="missing required argument 'a'"):
        add()
    with pytest.raises(TypeError, match="unexpected keyword argument 'c'$"):
        add(1, c=2)


def test_argument_errors():
    '''Too many positional arguments, an unknown keyword, a parameter given twice: module functions and `__init__`.'''
    v = Vec(3, 4)
    with pytest.raises(TypeError, match=r'^vec_norm2\(\) takes at most 1 positional arguments \(2 given\)$'):
        sc.vec_norm2(v, 1)
    with pytest.raises(TypeError, match=r"^vec_norm2\(\) got an unexpected keyword argument 'zz'$"):
        sc.vec_norm2(v, zz=1)
    with pytest.raises(TypeError, match=r"^Vec\(\) got an unexpected keyword argument 'é'$"):
        Vec(**{'é': 1})
    for call in (sc.vec_norm2, Vec):  # a name with no UTF-8 form is left out
        with pytest.raises(TypeError, match=r'^\w+\(\) got an unexpected keyword argument$'):
            call(**{'\udc80': 1})
    with pytest.raises(TypeError, match=r"^vec_norm2\(\) got multiple values for argument 'v'$"):
        sc.vec_norm2(v, v=v)
    with pytest.raises(TypeError, match=r"^Vec\(\) got multiple values for argument 'x'$"):
        Vec(1, x=2)


def test_attributes():
    d = Dyn()
    assert d.hello == 5  # `__getattr__`: normal lookup failed
    assert d.sets == 0  # a property: found normally
    with pytest.raises(AttributeError, match='no attribute `no_such`'):
        d.no_such
    assert getattr(d, 'no_x', 'dflt') == 'dflt'
    d.anything = 1
    d.sets = 3  # `__setattr__` takes every assignment, properties too
    assert d.sets == 2
    del d.anything
    assert d.dels == 1
    assert d.__getattr__('abc') == 3  # as a method (`super().__getattr__` in a subclass)


def test_descriptor():
    class Owner:
        size = Slot(4)

    assert isinstance(Owner.size, Slot)  # read from the class: the descriptor itself
    o = Owner()
    assert o.size == 4
    o.size = 9
    assert o.size == 9 and Owner().size == 9  # one value per descriptor
    del o.size
    assert o.size == 0
    with pytest.raises(OverflowError):
        o.size = 2**64


def test_static_and_class_methods():
    assert Vec.dot(Vec(1, 2), Vec(3, 4)) == 11
    assert Vec(0, 0).dot(Vec(1, 2), Vec(3, 4)) == 11  # also through an instance
    assert isinstance(inspect.getattr_static(Vec, 'dot'), staticmethod)
    with pytest.raises(TypeError, match=r"^dot\(\) argument 'a' must be `Vec`$"):
        Vec.dot(1, 2)
    assert Vec.from_pair(1, 2) == Vec(1, 2)
    assert isinstance(inspect.getattr_static(Vec, 'from_pair'), types.ClassMethodDescriptorType)

    class Sub(Vec):
        pass

    s = Sub.from_pair(3, 4)
    assert type(s) is Sub and s == Vec(3, 4)
    assert str(inspect.signature(Vec.dot)) == '(a, b)'
    assert str(inspect.signature(Vec.from_pair)) == '(x, y)'


def test_class_attributes():
    assert Vec.DIMS == 2 and Vec.NAME == 'Vec' and Vec.UNIT == 1.0
    assert Vec().DIMS == 2
    assert Labeled.DIMS == 2  # inherited


def test_weakref_and_dict():
    b = Bag(1)
    r = weakref.ref(b)
    assert r() is b
    b.note = 'hi'
    assert b.__dict__ == {'note': 'hi'}
    del b
    gc.collect()
    assert r() is None
    with pytest.raises(TypeError, match='weak reference'):
        weakref.ref(Vec())
    with pytest.raises(AttributeError):
        Vec().note = 1


def test_finalize():
    seen = []
    w = Watch(lambda: seen.append(1))
    del w
    assert seen == [1]  # once, at dealloc
    w = Watch(lambda: seen.append(2))
    assert w.link is None
    w.link = w  # a cycle: the GC finalizes it before clearing the fields
    del w
    gc.collect()
    assert seen == [1, 2]


def test_finalize_keeps_exception(monkeypatch):
    seen = []
    monkeypatch.setattr(sys, 'unraisablehook', lambda u: seen.append(u.exc_type))
    try:
        raise KeyError('kept')
    except KeyError:
        Watch(lambda: 1 / 0)  # finalized at once: its error is unraisable, `KeyError` stays
        assert isinstance(sys.exception(), KeyError)
    assert seen == [ZeroDivisionError]


def test_traverse_stops():
    '''`gc.get_referrers` stops a traversal at the first match (its visitor returns 1).'''
    marker = object()
    labeled = Labeled(marker)
    assert any(o is labeled for o in gc.get_referrers(marker))


def test_dict_cycle_is_collected():
    b = Bag()
    b.me = b  # a cycle through the `__dict__`
    r = weakref.ref(b)
    del b
    gc.collect()
    assert r() is None


def test_dict_visited_once():
    '''The `__dict__` is visited once, also for a Python subclass (CPython leaves it to the base).'''
    marker = object()
    b = Bag()
    b.x = marker
    assert sum(o is marker or (type(o) is dict and marker in o.values()) for o in gc.get_referents(b)) == 1

    class Sub(Bag):
        pass

    s = Sub()
    s.x = marker
    assert sum(o is marker or (type(o) is dict and marker in o.values()) for o in gc.get_referents(s)) == 1
    s.me = s
    r = weakref.ref(s)
    del s
    gc.collect()
    assert r() is None


def test_pickle():
    v = Vec(3, -4)
    assert v.__getstate__() == (3, -4)
    for p in range(2, pickle.HIGHEST_PROTOCOL + 1):
        w = pickle.loads(pickle.dumps(v, p))
        assert type(w) is Vec and w == v
    assert copy.copy(v) == v and copy.copy(v) is not v
    assert copy.deepcopy(v) == v
    with pytest.raises(TypeError, match='cannot be interpreted as an integer'):
        v.__setstate__((1, 'y'))


def test_pickle_with_base():
    lab = Labeled(['x'])
    assert lab.__getstate__() == (0, 0, ['x'])
    w = copy.deepcopy(lab)
    assert type(w) is Labeled and w.label == ['x'] and w.label is not lab.label
    w.__setstate__((1, 2, None))
    assert w.label is None and w == Vec(1, 2)
    with pytest.raises(TypeError, match='tuple of 3 items'):
        w.__setstate__((1, 2))
    with pytest.raises(OverflowError):
        w.__setstate__((2**64, 2, None))


def test_setter_error():
    lab = Labeled('a')
    lab.label = 'b'
    assert lab.label == 'b'
    with pytest.raises(RuntimeError, match='^NoLabel$'):  # a plain Zig error, not `SystemError`
        lab.label = None
    assert lab.label == 'b'
    with pytest.raises(AttributeError, match='^can not delete `label`$'):
        del lab.label
    assert lab.label == 'b'


def test_generic():
    alias = Bag[int]
    assert isinstance(alias, types.GenericAlias)
    assert alias.__origin__ is Bag and alias.__args__ == (int,)
    with pytest.raises(TypeError, match='not subscriptable'):
        Vec[int]


def test_subclass_keeps_hooks():
    class Sub(Vec):
        def __repr__(self):
            return 'Sub'

    s = Sub(1, 2)
    assert repr(s) == 'Sub' and str(s) == '(1, 2)'
    assert s == Vec(1, 2) and hash(s) == hash(Vec(1, 2))
    assert s + Vec(1, 1) == Vec(2, 3)


def test_class_parameters():
    '''A `*T` / `*const T` / `?*T` parameter takes an instance of the class or a subclass.'''

    class Sub(Vec):
        pass

    assert sc.vec_norm2(Vec(3, 4)) == 25
    assert sc.vec_norm2(Labeled('a')) == 0  # a Setu subclass
    assert sc.vec_norm2(Sub(1, 1)) == 2  # a Python subclass
    v = Vec(1, 2)
    sc.vec_scale(v, 3)  # `*Vec`: changes the instance
    assert v == Vec(3, 6)
    assert sc.vec_self(v) is v
    s = Sub()
    assert sc.vec_self(s) is s
    assert Vec.dot(Vec(1, 2), Vec(3, 4)) == 11
    assert sc.label_of(Labeled('x')) == 'x'
    assert sc.label_of(None) is None
    assert sc.label_of() is None
    with pytest.raises(TypeError, match=r"^vec_norm2\(\) argument 'v' must be `Vec`$"):
        sc.vec_norm2((3, 4))
    with pytest.raises(TypeError, match="must be `Vec`"):
        sc.vec_norm2(None)
    with pytest.raises(TypeError, match=r"^label_of\(\) argument 'v' must be `Labeled`$"):
        sc.label_of(Vec())  # the base is not the subclass
    with pytest.raises(TypeError, match=r"^dot\(\) argument 'b' must be `Vec`$"):
        Vec.dot(Vec(), 1)
    assert str(inspect.signature(sc.label_of)) == '(v=None)'


def test_buffer_parameters():
    '''`py.Buffer` takes any bytes-like object, `py.WritableBuffer` a writable one; both are released.'''
    assert sc.buffer_sum(b'abc') == 294
    assert sc.buffer_sum(bytearray(b'abc')) == 294
    assert sc.buffer_sum(memoryview(b'abc')[1:]) == 197
    assert sc.buffer_sum(array.array('H', [1, 2])) == 3
    assert sc.buffer_sum(b'') == 0
    assert sc.buffer_len(b'xy') == 2
    assert sc.buffer_len(None) is None
    assert sc.buffer_len() is None
    b = bytearray(3)
    assert sc.buffer_fill(b, 7) == 3
    assert b == b'\x07\x07\x07'
    b.extend(b'z')  # released after the call, so it can resize
    with memoryview(b) as m:
        sc.buffer_fill(m[1:3], 1)
    assert b == b'\x07\x01\x01z'
    with pytest.raises(OverflowError):
        sc.buffer_fill(b, 300)  # `value` fails after `buf` was taken
    b.append(0)  # released on that error too
    sc.buffer_sum(b)
    b.append(0)
    with pytest.raises(TypeError, match=r"^buffer_sum\(\) argument 'data' must be a bytes-like object$"):
        sc.buffer_sum('abc')
    for read_only in (b'abc', memoryview(b'abc'), 'abc'):
        with pytest.raises(TypeError, match=r"^buffer_fill\(\) argument 'buf' must be a writable bytes-like object$"):
            sc.buffer_fill(read_only, 1)
    with pytest.raises(BufferError, match='not C-contiguous'):
        sc.buffer_fill(memoryview(bytearray(4))[::2], 1)
    with pytest.raises(BufferError, match='not C-contiguous'):
        sc.buffer_sum(memoryview(b'abcd')[::2])


def test_sequence_parameters():
    '''`py.Sequence(T)` takes any sequence, converting each item like a `T` parameter.'''
    assert sc.seq_sum([1, 2, 3]) == 6
    assert sc.seq_sum((1, 2)) == 3
    assert sc.seq_sum(range(4)) == 6
    assert sc.seq_sum([]) == 0
    assert sc.seq_join([b'ab', b'c']) == b'abc'
    assert sc.seq_join(()) == b''
    assert sc.seq_norm2([Vec(3, 4), Labeled('a'), Vec(1, 0)]) == 26
    b = bytearray(3)
    assert sc.seq_buffer_len([b'ab', b]) == 5
    assert sc.seq_buffer_len(None) is None
    b.append(1)  # the item buffers are released after the call
    with pytest.raises(TypeError, match=r"^seq_buffer_len\(\) argument 'bufs' must be a sequence of `Buffer`$"):
        sc.seq_buffer_len([b, 'x'])
    b.append(1)  # and when a later item fails
    for bad in (1, {1, 2}, ['a'], [1.5]):
        with pytest.raises(TypeError, match=r"^seq_sum\(\) argument 'values' must be a sequence of `int`$"):
            sc.seq_sum(bad)
    with pytest.raises(OverflowError, match=r'^`seq_sum\(values\)` item = -2 is out of range 0\.\.4294967295$'):
        sc.seq_sum([1, -2])
    with pytest.raises(TypeError, match='must be a sequence of `bytes`'):
        sc.seq_join([b'a', 'b'])
    with pytest.raises(TypeError, match='must be a sequence of `Vec`'):
        sc.seq_norm2([Vec(), 1])


def test_take():
    '''A parameter kept with `take` stays locked (and alive) past the call, until the caller releases it.'''
    b, d, items = bytearray(3), bytearray(2), [bytearray(1), b'x']
    refs = [sys.getrefcount(b), sys.getrefcount(d)]
    sc.hold(b, d, items)
    for o in (b, d, items[0]):
        with pytest.raises(BufferError):
            o.append(1)
    del o
    sc.hold()
    items[0].append(1)
    b.append(1)
    d.append(1)
    assert [sys.getrefcount(b), sys.getrefcount(d)] == refs
    sc.hold(memoryview(b))  # `buf` only; a `memoryview` locks its `bytearray` too
    with pytest.raises(BufferError):
        b.append(1)
    sc.hold()
    b.append(1)
    sc.hold(bufs=[])  # nothing to take but the sequence itself
    sc.hold()
    with pytest.raises(TypeError):
        sc.hold(b, 'x')  # a later argument fails: `hold` is not called, nothing taken
    b.append(1)

    class Exporter:
        '''A buffer from Python (`__buffer__`), `limit` views of it.'''

        def __init__(self, limit):
            self.data, self.limit = bytearray(b'xy'), limit

        def __buffer__(self, flags):
            if self.limit == 0:
                raise BufferError('no more views')
            self.limit -= 1
            return memoryview(self.data)

    e = Exporter(2)
    sc.hold(e)  # `take` gets its view from `e`, not from CPython's wrapper in the first view
    with pytest.raises(BufferError):
        e.data.append(1)
    sc.hold()
    e.data.append(1)
    with pytest.raises(BufferError, match='^no more views$'):
        sc.hold(bufs=[b, Exporter(1)])  # the second item's `take` fails: the first one's is released
    b.append(1)


def test_owned_buffers():
    '''`py.OwnedBuffer` / `py.OwnedWritableBuffer` stay locked past the call, until the function releases them.'''
    b, d = bytearray(3), bytearray(2)
    refs = [sys.getrefcount(b), sys.getrefcount(d)]
    sc.own(b, d)
    for o in (b, d):
        with pytest.raises(BufferError):
            o.append(1)
    del o
    sc.own()
    b.append(1)
    d.append(1)
    assert [sys.getrefcount(b), sys.getrefcount(d)] == refs
    sc.own(memoryview(b))  # a `memoryview` locks its `bytearray` too
    with pytest.raises(BufferError):
        b.append(1)
    sc.own()
    b.append(1)
    sc.own(b, d, drop=True)  # released by the function itself
    b.append(1)
    d.append(1)

    class Bad:
        def __bool__(self):
            raise ZeroDivisionError

    with pytest.raises(ZeroDivisionError):
        sc.own(b, d, Bad())  # a later argument fails: `own` is not called, Setu releases both
    b.append(1)
    d.append(1)
    assert [sys.getrefcount(b), sys.getrefcount(d)] == refs
    with pytest.raises(TypeError, match=r"^own\(\) argument 'buf' must be a writable bytes-like object$"):
        sc.own(b'abc')
    with pytest.raises(TypeError, match=r"^owned_sum\(\) argument 'data' must be a bytes-like object$"):
        sc.owned_sum('abc')
    assert sc.owned_sum(b) == sum(b)
    assert sc.owned_sum(b'abc') == 294
    b.append(1)


def test_owned_buffer_method():
    '''A method takes a `py.OwnedWritableBuffer` like a module function: kept past the call, released on failure.'''
    b = bytearray(2)
    ref = sys.getrefcount(b)
    assert Vec(7).fill_into(b) == 2
    assert b == b'\x07\x07'
    with pytest.raises(BufferError):
        b.append(1)
    assert Vec().fill_into() == 0
    b.append(1)
    with pytest.raises(OverflowError):
        Vec(1).fill_into(b, 300)  # `scale` fails after `buf` was converted: Setu releases it
    b.append(1)
    with pytest.raises(TypeError, match=r"^fill_into\(\) argument 'buf' must be a writable bytes-like object$"):
        Vec().fill_into(b'ab')
    assert sys.getrefcount(b) == ref


def test_check_errno():
    '''`py.checkErrno` passes a result `>= 0` through and raises the errno of a negative one.'''
    assert sc.check_errno(0) == 0
    assert sc.check_errno(2**40) == 2**40
    with pytest.raises(FileNotFoundError) as e:
        sc.check_errno(-2)
    assert e.value.errno == 2 and e.value.strerror
    with pytest.raises(BlockingIOError):
        sc.check_errno(-11)
    with pytest.raises(PermissionError):
        sc.check_errno(-1)
    with pytest.raises(OSError) as e:
        sc.check_errno(-(2**31 - 1))
    assert e.value.errno == 2**31 - 1
    with pytest.raises(OverflowError, match=r'^result -2147483648 is out of errno range$'):
        sc.check_errno(-(2**31))


def test_long_message_is_cut():
    '''A formatted exception message keeps at most 511 bytes: the prefix that fits, nothing past it.'''
    with pytest.raises(ValueError, match='^abc$'):
        sc.raise_long('abc')
    text = ''.join(chr(ord('a') + i % 26) for i in range(1000))
    with pytest.raises(ValueError) as e:
        sc.raise_long(text)
    assert str(e.value) == text[:511]
    with pytest.raises(TypeError, match=r"^raise_long\(\) argument 'text' must be `str`$"):
        sc.raise_long(b'abc')
    with pytest.raises(TypeError, match=r"^text_tuple\(\) argument 'text' must be `bytes`$"):
        sc.text_tuple(1, 'x', 2)


def test_out_of_memory():
    '''`py.raiseNoMemory()` and a returned `error.OutOfMemory` both raise `MemoryError`.'''
    for zig_error in (False, True):
        with pytest.raises(MemoryError):
            sc.no_memory(zig_error)


def test_int_parameters():
    '''Ints convert to the exact parameter type, from `int` or `__index__`, else `OverflowError` / `TypeError`.'''

    class Index:
        def __index__(self):
            return 7

    assert sc.int_pair(0, -1) == (0, -1)
    assert sc.int_pair(2**63, 127) == (2**63, 127)
    assert sc.int_pair(2**64 - 1, -128) == (2**64 - 1, -128)
    assert sc.int_pair(Index(), Index()) == (7, 7)
    assert sc.int_pair(True, False) == (1, 0)
    for big, small, message in [
        (-1, 0, r'`int_pair\(big\)` = -1 is out of range 0\.\.18446744073709551615'),
        (2**64, 0, r'`int_pair\(big\)` = 18446744073709551616 is out of range 0\.\.18446744073709551615'),
        (-(2**63) - 1, 0, r'`int_pair\(big\)` = -9223372036854775809 is out of range'),
        (0, 128, r'`int_pair\(small\)` = 128 is out of range -128\.\.127'),
        (0, -(2**63), r'`int_pair\(small\)` = -9223372036854775808 is out of range -128\.\.127'),
        (2**200, 0, f'`int_pair\\(big\\)` = {2**200} is out of range'),  # past 128 bits: up to 32 bytes in digits
        (-(2**250), 0, f'`int_pair\\(big\\)` = {-(2**250)} is out of range'),
        (2**300, 0, r'`int_pair\(big\)` = an int of 38 bytes is out of range 0\.\.18446744073709551615'),
    ]:
        with pytest.raises(OverflowError, match=f'^{message}'):
            sc.int_pair(big, small)
    with pytest.raises(TypeError):
        sc.int_pair('1', 0)
    with pytest.raises(TypeError):
        sc.int_pair(1.0, 0)
    o = Ordered(1)
    o.rank = -(2**63)
    assert o.rank == -(2**63)
    with pytest.raises(OverflowError, match=r'^`Ordered.rank` = 9223372036854775808 is out of range'):
        o.rank = 2**63


def test_result_fails_midway():
    '''A list / tuple result whose item fails to convert raises, and drops the items not yet in it.'''
    assert sc.text_list(False) == ['a', 'b', 'c']
    assert sc.text_tuple(1, b'x', 2) == (1, 'x', 2)
    with pytest.raises(UnicodeDecodeError):
        sc.text_list(True)
    first, last = object(), object()
    before = sys.getrefcount(first), sys.getrefcount(last)
    with pytest.raises(UnicodeDecodeError):
        sc.text_tuple(first, b'\xff', last)
    assert (sys.getrefcount(first), sys.getrefcount(last)) == before


def test_module_constants():
    '''The UPPER_CASE `pub const` ints, floats, `bool`s, strings and enum fields of a file.'''
    assert (sc.ANSWER, sc.NEGATIVE, sc.ALL_ONES) == (42, -5, 2**64 - 1)
    assert (sc.RED, sc.GREEN, sc.BLUE) == (1, 2, 9)
    assert (sc.PI, sc.FLAG, sc.NAME, sc.EMPTY) == (3.25, True, 'setu', '')
    assert type(sc.FLAG) is bool and type(sc.PI) is float
    assert not hasattr(sc, 'lower_case') and not hasattr(sc, 'other') and not hasattr(sc, 'COUNTER')


def test_exceptions():
    '''`setu.Exception`: classes of the module, raised from Zig (`raise`, `raiseWith`), matched (`matches`).'''
    assert issubclass(sc.ExtraError, OSError) and issubclass(sc.PlainError, Exception)
    assert not issubclass(sc.PlainError, OSError)
    for exc in (sc.ExtraError, sc.PlainError):
        assert exc.__module__ == 'setu_classes'
        assert exc.__qualname__ == exc.__name__
    assert sc.ExtraError.__doc__.startswith('An `OSError` of the extension')
    assert sc.PlainError.__doc__ == 'A plain `Exception` subclass.'
    with pytest.raises(sc.ExtraError) as e:
        sc.raise_extra(95, 'not here')
    assert (e.value.errno, e.value.strerror) == (95, 'not here')
    assert str(e.value) == '[Errno 95] not here'
    with pytest.raises(sc.PlainError, match='^plain 3$'):
        sc.raise_plain(3)
    assert sc.is_plain(sc.PlainError('x')) and sc.is_plain(sc.PlainError)
    assert not sc.is_plain(ValueError()) and not sc.is_plain(sc.ExtraError(1, 'x'))

    class Sub(sc.PlainError):
        pass

    assert sc.is_plain(Sub())


def test_hidden_class():
    '''`hidden = true`: the type exists (Zig hands out instances) but is no module attribute.'''
    s = sc.make_secret(3)
    assert type(s).__name__ == 'Secret' and type(s).__module__ == 'setu_classes'
    assert s.value == 3 and sc.secret_value(s) == 3
    assert not hasattr(sc, 'Secret') and not hasattr(sc, 'SecretType')
    with pytest.raises(TypeError):
        type(s)()  # `instantiable = false`
    with pytest.raises(TypeError, match='must be `Secret`'):
        sc.secret_value(3)


def test_module_declaration():
    '''`setu_classes.zig`'s `module`: doc from `//!`, `__version__`, `init` after Setu's part, `methods` wins.'''
    assert sc.__doc__.startswith("Setu's test extension: module functions and constants")
    assert sc.__version__ == '0.0'
    assert sc.initialized is True  # `init` ran after the classes were created
    assert sc.BY_HAND == 1  # `py.addConstants` in `init`
    assert sc.overridden() == 2  # `Module.methods` replaces `extra.zig`'s `overridden` (1)


def test_example_numbers():
    '''Repeated `Example` headers are numbered in the docstring (`help()`), a single one is not.'''
    doc = sc.vec_scale.__doc__
    assert '\nExample #1\n    >>> v = Vec(1, 2)\n' in doc and '\nExample #2\n    # a second block' in doc
    assert '\nExample\n    >>> vec_norm2(Vec(3, 4))\n' in sc.vec_norm2.__doc__


def test_scan_filters():
    '''What the `from` entries leave out: `.exclude`, `.prefixes`, `.only`, `.functions = false`, `_` names.'''
    assert not hasattr(sc, 'excluded')  # `.exclude`
    assert (sc.K_ONE, sc.K_TWO) == (1, 2) and not hasattr(sc, 'OTHER')  # `.prefixes`
    assert sc.PICKED == 5 and not hasattr(sc, 'DROPPED')  # `.only`
    assert not hasattr(sc, 'not_exported')  # `.functions = false` (a function in `classes.zig`)
    assert not hasattr(sc, 'newSecret')  # a camelCase Zig helper is never exported
    for name in ('_Scratch', 'Scratch', '_ScratchType', '_LIMIT', 'kernel', 'picked', 'Plain'):
        assert not hasattr(sc, name)
    assert not hasattr(sc, 'Vec' + 'Type') and not hasattr(sc, 'COUNTER')


def test_int_enum():
    '''An entry with `.enums = .int_enum`: each `pub const E = enum` is an `IntEnum` with every field.'''
    import enum

    assert issubclass(sc.Mode, enum.IntEnum)
    assert [(m.name, m.value) for m in sc.Mode] == [('plain', 1), ('with_errno', 2), ('OTHER', 7)]
    assert sc.Mode(2) is sc.Mode.with_errno and sc.Mode.plain == 1
    assert sc.Mode.__module__ == 'setu_classes' and sc.Mode.__qualname__ == 'Mode'
    assert sc.Mode.__doc__.startswith('How a call ended: an `IntEnum`')
    assert pickle.loads(pickle.dumps(sc.Mode.OTHER)) is sc.Mode.OTHER


def test_new_only():
    '''A class with only `__new__` takes its arguments there; the stub declares `__new__`.'''
    assert sc.Pair(1).pair == (1, 1)
    assert sc.Pair(1, b=2).pair == (1, 2)
    assert str(inspect.signature(sc.Pair)) == '(a, b=None)'
    with pytest.raises(TypeError):
        sc.Pair()


def test_stub_matches_module():
    '''`setu_classes.pyi` (`setu.stub.module`) lists every class; `__text_signature__`s come from the Zig source.'''
    import pathlib

    stub = (pathlib.Path(sc.__file__).parent / 'setu_classes.pyi').read_text()
    assert stub.startswith('# Type stubs for `setu_classes`, generated by Setu from the Zig source')
    assert '\nfrom enum import IntEnum\n' in stub and 'import os' not in stub  # only what it uses
    assert '\ninitialized: bool\nBY_HAND: int\n\n__version__: str\n' in stub  # `stub_extra`, `version`
    assert '\nclass Mode(IntEnum):\n' in stub and '    with_errno = 2\n' in stub
    assert 'def overridden() -> int:' in stub  # the `from` function's stub, though `methods` replaces it
    for name in ('excluded', 'OTHER', 'DROPPED', 'not_exported', 'newSecret', '_Scratch', 'Scratch', '_LIMIT'):
        assert f'def {name}(' not in stub and f'class {name}' not in stub and f'\n{name}:' not in stub
    for cls in (Vec, Labeled, Ordered, Num, Bag, Countdown, Adder, Dyn, Slot):
        assert f'class {cls.__name__}' in stub
    assert 'class Bag[T]:' in stub
    assert '    DIMS: ClassVar[int]\n' in stub
    assert '    @staticmethod\n    def dot(a: Vec, b: Vec) -> int:' in stub
    assert 'def vec_scale(v: Vec, k: int) -> None:' in stub
    assert 'def label_of(v: Labeled | None = None) -> object:' in stub
    assert 'def buffer_len(data: Buffer | None = None) -> int | None:' in stub
    assert 'def buffer_fill(buf: Buffer, value: int) -> int:' in stub
    assert 'def seq_sum(values: Sequence[int]) -> int:' in stub
    assert '    def __new__(cls, a: int, b: int | None = None) -> Self: ...' in stub
    assert 'def seq_buffer_len(bufs: Sequence[Buffer] | None = None) -> int | None:' in stub
    assert '\nANSWER: int\nNEGATIVE: int\nALL_ONES: int\nPI: float\nFLAG: bool\nNAME: str\nEMPTY: str\n' in stub
    assert '\nRED: int\nGREEN: int\nBLUE: int\n' in stub
    assert "class ExtraError(OSError):\n    '''An `OSError` of the extension's own" in stub
    assert "class PlainError(Exception):\n    '''A plain `Exception` subclass.'''" in stub
    assert 'class Secret' not in stub and 'def secret_value(s: Any) -> int:' in stub
    assert '    @classmethod\n    def from_pair(cls, x: int, y: int)' in stub
    assert '    def __eq__(self, other: object, /) -> bool: ...' in stub
    assert '    def __iadd__(self, other: Vec, /) -> Self: ...' in stub
    assert '    def __next__(self) -> int: ...' in stub
