"""Valve Material (VMT) / KeyValues parser with $patch support."""
import re

_TOK = re.compile(r'"([^"]*)"|(\{)|(\})|([^\s{}"]+)')


def parse_kv(text):
    """Parse KeyValues text into nested dicts (lower-cased keys)."""
    if isinstance(text, bytes):
        text = text.decode('utf-8', 'replace')
    # strip // comments but not inside quotes
    out_lines = []
    for line in text.splitlines():
        q = False; cut = None
        for i, c in enumerate(line):
            if c == '"':
                q = not q
            elif c == '/' and not q and i + 1 < len(line) and line[i + 1] == '/':
                cut = i; break
        out_lines.append(line[:cut] if cut is not None else line)
    text = '\n'.join(out_lines)

    toks = []
    for m in _TOK.finditer(text):
        s, ob, cb, w = m.groups()
        toks.append(('s', s) if s is not None else
                    ('{', None) if ob else ('}', None) if cb else ('s', w))
    pos = 0

    def block():
        nonlocal pos
        d = {}
        while pos < len(toks):
            t, v = toks[pos]
            if t == '}':
                pos += 1
                return d
            pos += 1
            if t != 's':
                continue
            key = v.lower()
            if pos < len(toks) and toks[pos][0] == '{':
                pos += 1
                val = block()
            elif pos < len(toks) and toks[pos][0] == 's':
                val = toks[pos][1]; pos += 1
            else:
                val = ''
            if key in d and isinstance(d[key], dict) and isinstance(val, dict):
                d[key].update(val)
            else:
                d[key] = val
        return d

    root = {}
    while pos < len(toks):
        t, v = toks[pos]
        pos += 1
        if t != 's':
            continue
        name = v.lower()
        if pos < len(toks) and toks[pos][0] == '{':
            pos += 1
            root[name] = block()
        else:
            root[name] = toks[pos][1] if pos < len(toks) and toks[pos][0] == 's' else ''
    return root


class Vmt:
    """A resolved material: .shader (lower) and .kv (flat dict of $params)."""

    def __init__(self, shader, kv):
        self.shader = shader
        self.kv = kv

    def get(self, key, default=None):
        return self.kv.get(key.lower(), default)

    def flt(self, key, default=0.0):
        try:
            return float(str(self.get(key, default)).strip('"[] '))
        except (TypeError, ValueError):
            return default

    def intv(self, key, default=0):
        try:
            return int(float(str(self.get(key, default)).strip('"[] ')))
        except (TypeError, ValueError):
            return default

    def vec(self, key, default=(1., 1., 1.)):
        raw = self.get(key)
        if raw is None:
            return tuple(default)
        parts = str(raw).replace('[', ' ').replace(']', ' ').replace('{', ' ') \
                        .replace('}', ' ').split()
        try:
            v = [float(p) for p in parts[:3]]
        except ValueError:
            return tuple(default)
        if len(v) != 3:
            return tuple(default)
        # Source has two forms and they are NOT interchangeable:
        #   {255 255 255}   integers, 0-255
        #   [1 1 1]         floats, and DELIBERATELY allowed above 1.0
        # The bracket form above 1 is a brightening tint, paired with the
        # map's baked lightmap. Treating "> 1 means it must be 0-255" turned
        # gm_br_pitfalls' $color "[1.3 1.25 1.5]" into 0.005 and painted the
        # whole backrooms pure black - 50 of its materials use it.
        # A bare value with no delimiters is genuinely ambiguous; only then is
        # the magnitude used, and only well clear of any plausible float tint.
        s = str(raw)
        if '{' in s or ('[' not in s and max(v) > 8.0):
            v = [x / 255.0 for x in v]
        return tuple(v)

    def tex(self, key):
        v = self.get(key)
        if not v:
            return None
        return str(v).strip().strip('"').replace('\\', '/').lstrip('/')

    def __repr__(self):
        return f'<Vmt {self.shader} {list(self.kv)[:6]}>'


def load_vmt(fs, name, mapname=None, _depth=0):
    """Resolve a material name (e.g. 'stone/infflra') to a Vmt, following $patch."""
    if _depth > 6:
        return None
    name = name.lower().replace('\\', '/').strip()
    cands = []
    if mapname:
        cands.append(f'materials/maps/{mapname}/{name}_wvt_patch.vmt')
    cands.append(f'materials/{name}.vmt')
    raw = None
    for c in cands:
        raw = fs.read(c)
        if raw is not None:
            break
    if raw is None:
        return None
    kv = parse_kv(raw)
    if not kv:
        return None
    shader = next(iter(kv))
    body = kv[shader]
    if not isinstance(body, dict):
        return None
    if shader == 'patch':
        inc = body.get('include')
        base = load_vmt(fs, str(inc).replace('materials/', '')
                        .replace('.vmt', ''), mapname, _depth + 1) if inc else None
        if base is None:
            return None
        merged = dict(base.kv)
        for sect in ('replace', 'insert'):
            s = body.get(sect)
            if isinstance(s, dict):
                merged.update({k: v for k, v in s.items()})
        return Vmt(base.shader, merged)
    flat = {k: v for k, v in body.items() if not isinstance(v, dict)}
    # keep nested blocks we may care about
    for k, v in body.items():
        if isinstance(v, dict):
            flat.setdefault('_' + k, v)
    return Vmt(shader, flat)
