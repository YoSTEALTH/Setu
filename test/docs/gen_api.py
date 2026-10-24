'''The `mkdocs-gen-files` script of the docs fixture: the API pages of `setu_classes.pyi`.'''

import sys

sys.path.insert(0, '../../tools')
import setu_docs  # noqa: E402

setu_docs.write_api('pyproject.toml')
