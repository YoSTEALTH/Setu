Setu
====

Setu (सेतु, "bridge"): a generic Zig <-> CPython binding layer for Python 3.15 / 3.15t
(PEP 793 module export, PEP 697 type data, critical sections). No ``Python.h``: the C API
is declared by hand in ``src/capi.zig``. Zig 0.17.0, Linux.

Used by Shakti as a path dependency. It never imports Shakti.

::

    src/setu.zig      the module root (``@import("setu")``)
    src/capi.zig      hand-declared C API
    src/py.zig        functions, conversions, errors (``exportFns``)
    src/class.zig     ``setu.Class``: a struct becomes a Python type
    src/stub.zig      ``.pyi`` text at comptime
    test/             ``setu_classes``, a test extension with a class per hook family

Commands::

    zig build test                        # unit tests
    zig build develop                     # test extension + stubs into test/ (-Dfree-threaded=false for 3.15)
    tools/check.sh                        # every check, on both interpreters
