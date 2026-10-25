# Guide

A Markdown page with each feature `setu_docs.py` renders, **bold**, *emphasis* and a link to
[the classes](classes.md#Vec) or [home](index.md).

## Tables

| Name | Value | Note |
| :--- | ---: | :---: |
| `ANSWER` | 42 | an `int` |
| `PI` | 3.25 | a \| pipe |

## Code

```sh
zig build develop  # the extension
python3 -m pytest
```

```pycon
>>> vec_norm2(Vec(3, 4))
25
```

```c
int main(void) { return 0; }
```

## Lists

- one
- two, with
  a second line
  - nested
- three

1. first
2. second

> A quote, with `code`.

---

<p class="muted">Raw HTML passes through.</p>

## Chart

<!-- chart group="^(C \w+|\w+)" -->
| server | req/s | |
|:--|--:|:--|
| C liburing | 627,427 | `███████` |
| Liburing, 3.15 `--tmpl` | **501k** | `█████▋` |
| epoll, 3.15 | 499,194 | `█████▋` |
