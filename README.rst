Setu
====

Setu (सेतु, "bridge"): a generic Zig <-> CPython binding layer for Python 3.15 / 3.15t
(PEP 793 module export, PEP 697 type data, critical sections). No ``Python.h``: the C API
is declared by hand in ``src/capi.zig``. Zig 0.17.0, Linux.

Used by Shakti and Liburing as a dependency. It never imports either.

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
    zig build develop                     # test extension + stubs into test/ (-Dfree-threaded=false for 3.15)
    tools/check.sh                        # every check, on both interpreters

Wheels: ``tools/setu_build.py``
-------------------------------

A PEP 517 build backend (no setuptools) that builds a Zig + Setu extension's wheels with ``zig build``.
A backend must sit in the project's own tree, so each project keeps a byte-identical copy in its
``tools/``, never edited there: what differs per project goes in ``[tool.setu_build]`` in its
``pyproject.toml`` (the keys are listed in the script's docstring). Setu tests the script itself:
``tools/check.sh`` builds glibc and musl wheels of ``test/wheel/`` for both ABIs (``tools/check_wheels.py``).

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
