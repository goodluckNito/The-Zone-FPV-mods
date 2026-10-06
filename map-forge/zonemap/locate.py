"""Find Steam libraries and game content, on Windows, Linux or macOS.

The converter needs three things and none of them are in fixed places:
  * a game's content roots (the folders holding .vpk archives), or props and
    most textures silently resolve to nothing
  * the map folder
  * The Zone's custom_maps folder, for --install
"""
import os, sys, glob, re

# game key -> (steamapps/common folder, maps subdir, content root subdirs)
GAMES = {
    'css':  ('Counter-Strike Source', 'cstrike/maps', ['cstrike', 'hl2']),
    'csgo': ('Counter-Strike Global Offensive', 'csgo/maps', ['csgo']),
    'hl2':  ('Half-Life 2', 'hl2/maps', ['hl2', 'episodic', 'ep2']),
    'tf2':  ('Team Fortress 2', 'tf/maps', ['tf', 'hl2']),
    'portal': ('Portal', 'portal/maps', ['portal', 'hl2']),
    # GMod keeps its own content in garrysmod/ but mounts HL2's and CS:S's
    # out of sourceengine/ - a Workshop map that reuses hl2 or cstrike
    # textures finds nothing without it.
    'gmod': ('GarrysMod', 'garrysmod/maps',
             ['garrysmod', 'sourceengine', 'platform']),
    'vtmb': ('Vampire The Masquerade - Bloodlines', 'Vampire/maps', ['Vampire']),
}
ZONE_DIR = 'The Zone FPV'


def _dedup(paths):
    out, seen = [], set()
    for p in paths:
        if not p:
            continue
        n = os.path.normpath(p)
        k = n.lower()
        if k not in seen and os.path.isdir(n):
            seen.add(k)
            out.append(n)
    return out


def steam_roots():
    """Every Steam library folder we can find."""
    cands = []
    # 1. the registry (Windows)
    if sys.platform.startswith('win'):
        try:
            import winreg
            for hive, key in ((winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam'),
                              (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam')):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        for name in ('SteamPath', 'InstallPath'):
                            try:
                                cands.append(winreg.QueryValueEx(k, name)[0])
                            except OSError:
                                pass
                except OSError:
                    pass
        except ImportError:
            pass
        for d in 'CDEFGH':
            cands += [rf'{d}:\Program Files (x86)\Steam', rf'{d}:\Program Files\Steam',
                      rf'{d}:\Steam', rf'{d}:\SteamLibrary', rf'{d}:\Games\Steam']
    else:
        home = os.path.expanduser('~')
        cands += [os.path.join(home, '.steam', 'steam'),
                  os.path.join(home, '.steam', 'root'),
                  os.path.join(home, '.local', 'share', 'Steam'),
                  os.path.join(home, 'Library', 'Application Support', 'Steam'),
                  '/usr/share/steam']

    roots = _dedup(cands)

    # 2. libraryfolders.vdf lists the other libraries
    found = list(roots)
    for r in roots:
        for vdf in (os.path.join(r, 'steamapps', 'libraryfolders.vdf'),
                    os.path.join(r, 'config', 'libraryfolders.vdf')):
            if not os.path.isfile(vdf):
                continue
            try:
                txt = open(vdf, 'r', encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for m in re.finditer(r'"path"\s*"([^"]+)"', txt):
                found.append(m.group(1).replace('\\\\', '\\'))
            for m in re.finditer(r'^\s*"\d+"\s*"([A-Za-z]:[^"]+)"', txt, re.M):
                found.append(m.group(1).replace('\\\\', '\\'))

    # 3. this sandbox mounts connected folders under ~/mnt
    mnt = os.path.expanduser('~/mnt')
    if os.path.isdir(mnt):
        found.append(mnt)

    return _dedup(found)


def _commons(roots):
    out = []
    for r in roots:
        out += [os.path.join(r, 'steamapps', 'common'), r]
    return _dedup(out)


def find_game(key, explicit=None):
    """-> (maps_dir, [content_roots]). Raises with the searched paths on failure."""
    folder, maps_sub, content = GAMES[key]
    bases = []
    if explicit:
        bases.append(explicit)
    for c in _commons(steam_roots()):
        bases.append(os.path.join(c, folder))
    bases = _dedup(bases)
    for b in bases:
        maps_dir = os.path.join(b, *maps_sub.split('/'))
        roots = [os.path.join(b, s) for s in content]
        roots = [r for r in roots if os.path.isdir(r)]
        if roots and (os.path.isdir(maps_dir) or explicit):
            return maps_dir, roots
    raise SystemExit(
        f"could not find {folder!r}.\nSearched:\n  " +
        "\n  ".join(bases or ['(no Steam library found)']) +
        f"\nPass --game-dir \"<path to {folder}>\" explicitly.")


def guess_game(bsp_path):
    """Work out which game a .bsp belongs to from its path.

    Without this, `forge.py <path to a TF2 map>` silently runs with the default
    -g css and every TF2 texture and model resolves to nothing: the map
    converts "successfully" and comes out empty.

    Three tests, strongest first:

    1. The maps directory itself. `.../tf/maps/x.bsp` is TF2, `.../cstrike/maps`
       is CS:S. This is exact and is what settles the ambiguous cases.
    2. The Steam folder name as a path component.
    3. Which game's own content directory sits beside the map.

    Test 3 has a trap worth spelling out: TF2, CS:S and Portal all ship an
    `hl2/` folder, so a naive "does hl2/ exist" check identifies every one of
    them as Half-Life 2 - which is exactly what happened to ctf_2fort, losing
    all 318 prop models. `hl2` is therefore only ever accepted as a last
    resort, after every game with a distinctive folder has been ruled out.
    """
    p = os.path.abspath(bsp_path).replace('\\', '/')
    d = os.path.dirname(p).rstrip('/').lower()

    # 1. the maps directory is decisive
    for key, (_folder, maps_sub, _content) in GAMES.items():
        if d.endswith('/' + maps_sub.lower()):
            return key

    # 2. the Steam folder name
    parts = [x.lower() for x in p.split('/')]
    for key, (folder, _maps, _content) in GAMES.items():
        if folder.lower() in parts:
            return key

    # 3. content layout, distinctive folders first
    generic = {'hl2', 'episodic', 'ep2'}
    ordered = ([k for k in GAMES if GAMES[k][2][0].lower() not in generic]
               + [k for k in GAMES if GAMES[k][2][0].lower() in generic])
    cur = os.path.dirname(p)
    for _ in range(6):
        for key in ordered:
            if os.path.isdir(os.path.join(cur, GAMES[key][2][0])):
                return key
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return None


def content_roots_for_bsp(bsp_path, key, explicit=None):
    """Content roots, preferring the library the .bsp itself lives in."""
    folder, maps_sub, content = GAMES[key]
    p = os.path.abspath(bsp_path)
    # walk up looking for the game folder the map belongs to
    cur = os.path.dirname(p)
    for _ in range(6):
        roots = [os.path.join(cur, s) for s in content]
        roots = [r for r in roots if os.path.isdir(r)]
        if roots:
            return roots
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return find_game(key, explicit)[1]


def find_zone_custom_maps(explicit=None):
    if explicit:
        return explicit
    for c in _commons(steam_roots()):
        d = os.path.join(c, ZONE_DIR, 'custom_maps')
        if os.path.isdir(d):
            return d
    raise SystemExit(
        f"could not find {ZONE_DIR}/custom_maps. Pass --install \"<path>\".")
