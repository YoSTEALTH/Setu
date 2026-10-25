'''The fixture's example hooks (`hooks` in `pyproject.toml`): one of each kind, checked by `tools/check_docs.py`.'''

FIXTURES = {}


def fixture(*names):
    '''Register an `[async] def setup(ns)` for the examples of `names`.'''

    def register(fn):
        for name in names:
            FIXTURES[name] = fn
        return fn

    return register


@fixture('seq_sum')
async def _numbers(ns):
    ns['numbers'] = [1, 2, 3]
    ns['_cleanup'].append(lambda: ns.pop('numbers'))


SKIP = {('buffer_len', 'buffer_len(None)'): 'shows skipping'}
LOOSE = {('vec_self', 'vec_self(v) is v')}
NAMESPACE = {'helper': 'from NAMESPACE'}
