"""Layered read-only view of Source game content.

Lookup order, most specific first:

  BSP pakfile  the map's own embedded content - always wins, that is the point
               of embedding it
  .gma         Garry's Mod Workshop archives. An addon ships its map and all
               its custom content in one archive and expects to override the
               base game
  VPKs         the game's shipped archives
  loose files  a game directory on disk, and legacy addons unpacked into one
"""
import io, os, zipfile, glob
from .vpk import Vpk


class SourceFs:
    def __init__(self, game_dirs, pakfile_bytes=None, archives=()):
        self.zips, self.vpks, self.roots = [], [], []
        self.archives = list(archives)
        if pakfile_bytes:
            self.zips.append(zipfile.ZipFile(io.BytesIO(pakfile_bytes)))
        for d in game_dirs:
            if not os.path.isdir(d):
                continue
            self.roots.append(d)
            for v in sorted(glob.glob(os.path.join(d, '*_dir.vpk'))):
                try:
                    self.vpks.append(Vpk(v))
                except Exception as ex:
                    print(f'  ! vpk {os.path.basename(v)}: {ex}')
        self._zip_index = {}
        for z in self.zips:
            for n in z.namelist():
                self._zip_index.setdefault(n.lower().replace('\\', '/'), (z, n))

    def read(self, path):
        p = path.lower().replace('\\', '/').lstrip('/')
        hit = self._zip_index.get(p)
        if hit:
            z, n = hit
            return z.read(n)
        for g in self.archives:
            d = g.read(p)
            if d is not None:
                return d
        for v in self.vpks:
            d = v.read(p)
            if d is not None:
                return d
        for r in self.roots:
            fp = os.path.join(r, p)
            if os.path.isfile(fp):
                with open(fp, 'rb') as f:
                    return f.read()
        return None

    def stats(self):
        st = dict(zip_entries=len(self._zip_index),
                  vpks=len(self.vpks),
                  vpk_entries=sum(len(v.entries) for v in self.vpks),
                  roots=len(self.roots))
        if self.archives:
            st['gma'] = len(self.archives)
            st['gma_entries'] = sum(len(g.entries) for g in self.archives)
        return st
