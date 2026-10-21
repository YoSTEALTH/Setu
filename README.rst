Setu
====

Setu (सेतु, "bridge"): a generic Zig <-> CPython binding layer. One build loads on
CPython 3.14, 3.14t, 3.15, 3.15t and later: a single ``<name>.so`` in one ``cp314-abi3.abi3t`` wheel
per platform (the 3.15 stable ABI for free-threading, PEP 803, plus a 3.14 entry point). PEP 697
type data, critical sections. No ``Python.h``: the C API is declared by hand in ``src/capi.zig``.
Zig 0.17.0, Linux.

Setu is mainly for the Shakti and Liburing projects, which use it as a dependency (it never imports
either). For your own extensions, use `PyOZ <https://pyoz.dev>`_ instead: it fills the same role and is
documented and maintained for public use.

::

    src/setu.zig      the module root (``@import("setu")``)
    src/capi.zig      hand-declared C API
    src/py.zig        functions, conversions, errors (``exportFns``)
    src/class.zig     ``setu.Class``: a struct becomes a Python type
    src/stub.zig      ``.pyi`` text at comptime
    test/             ``setu_classes``, a test extension with a class per hook family
    test/wheel/       ``setu_classes`` as a project, for the ``tools/setu_build.py`` wheel checks
    tools/setu_build.py   the wheel build backend (PEP 517) projects copy into their ``tools/``

Commands::

    zig build test                        # unit tests
    zig build develop                     # test extension (setu_classes.so) + stubs into test/
    tools/check.sh                        # every check, on 3.15t, 3.15, 3.14t and 3.14

Wheels: ``tools/setu_build.py``
-------------------------------

A PEP 517 build backend (no setuptools) that builds a Zig + Setu extension's wheels with ``zig build``.
A backend must sit in the project's own tree, so each project keeps a byte-identical copy in its
``tools/``, never edited there: what differs per project goes in ``[tool.setu_build]`` in its
``pyproject.toml`` (the keys are listed in the script's docstring). Setu tests the script itself:
``tools/check.sh`` builds the glibc and musl wheels of ``test/wheel/`` and pip-installs them on every
interpreter (``tools/check_wheels.py``).

A project keeps its copy in step with the Setu it pins with two ``zig build`` steps, from its
``build.zig`` (``setu`` must be in its ``build.zig.zon``)::

    const setu_dep = b.dependency("setu", .{});
    @import("setu").addSetuBuildSteps(b, setu_dep);

``zig build setu-build-sync`` copies the pinned Setu's ``tools/setu_build.py`` into ``tools/`` (run it after
bumping Setu); ``zig build setu-build-check`` fails if the copy differs (run it in the project's checks).

Releases
--------

Tags are ``v<year>.<month>.<day>`` (the ``build.zig.zon`` version). Each tag's notes say whether
``tools/setu_build.py`` changed since the previous tag: if it did, projects run ``zig build setu-build-sync``
after bumping to it. ``git diff --quiet <previous tag> <tag> -- tools/setu_build.py`` tells (exit 1: changed).
