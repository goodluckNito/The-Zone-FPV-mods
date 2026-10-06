"""Unreal material (instance) -> glTF material for The Zone.

An Unreal material is a node graph, so there is no "albedo texture" to read
off it; what a cooked package does keep is the instance chain's parameter
values (TextureParameterValues, VectorParameterValues, ...), and on the base
Material the list of textures its graph samples. That is enough for most
art: the base colour is the texture parameter called something like Albedo /
BaseColor / Diffuse, or failing that the referenced texture named *_D / *_BC /
*_col. Tints the game would multiply in are baked into the pixels, because
the game's shader takes albedo colour OR texture, never both (see
materials.py).

Nothing here can evaluate a graph: world-aligned (triplanar) and blended
materials come out as their main texture, with UVs the caller projects.
"""
import re, numpy as np
from PIL import Image
from . import uasset, utex
from .materials import _png, _jpg, _fit
from .cutout import OpaqueMask

_SKIP_TEX = re.compile(
    r'(normal|_n$|_nrm|_nm$|mask|_msk|rough|_r$|_orm|_rma|_srm|srmh|_arm|metallic|metalness|_metal$|_m$|'
    r'_ao$|height|_h$|opacity|_alpha|emiss|detail|noise|ripple|dripping|'
    r'particlecloud|pivotpos|xvector|variation|placeholder|default|^t_?white|'
    r'^t_?black|flatten|_spec|gradient|lut|cube|hdri|puddle|foam|wetness|splat)', re.I)
_SKIP_NRM = re.compile(r'(detail|default|flatten|flat_normal|noise|ripple|placeholder|water)', re.I)
_ALB_PARAM = re.compile(
    r'^(albedo|base ?colou?r|basecolou?r|base_colou?r|diffuse|t_basecolor|'
    r'bark basecolor|basetexture|base texture|base|colou?r ?(map|texture)?|'
    r'texture|tex|maintex|main texture|bc|d|albedo ?map|diffuse ?map|'
    r'leaf basecolor|trunk basecolor)$', re.I)
_ALB_NAME = re.compile(r'((^|[_\- ])(d\d?|bc|basecolou?r|albedo|col|diff(use)?|c|colou?r|dif)'
                       r'([_\- ]|png|tga|$)|basecolor|albedo|diffuse)', re.I)
_NRM_PARAM = re.compile(r'^(normal ?(map)?|t_normal|bark normal|normalmap|'
                        r'nrm|normal texture)$', re.I)
_NRM_NAME = re.compile(r'((^|[_\- ])(n|nrm|normal|nm|norm)([_\- ]|png|tga|$)|normal)', re.I)
_FOLIAGE = re.compile(r'(leaf|leaves|leafs|branch|bush|grass|foliage|flora|fern|ivy|'
                      r'plant|imposter|impostor|fence|chain|grid|decal|hedge|flower|'
                      r'vine|weed|reed|net)', re.I)
_TINT_PARAM = ('albedocolor', 'albedo color', 'colortint', 'color tint',
               'albedotint', 'albedo tint', 'basecolor color adjust',
               'basecolortint', 'base color tint', 'tint', 'diffusetint',
               'colorcorrection', 'color correction')
_ENGINE_DEFAULTS = ('/Engine/',)


def _srgb(c):
    c = np.clip(np.asarray(c, np.float64), 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


# editor-only helpers: the map editor's gizmo / selection meshes and the
# invisible collision proxies some items carry in a section of their own
_HELPER = re.compile(r'(axis_.*collision|_collision$|_collision_inst$|sphereHide|decaldraw|'
                     r'icn_preview|selection)', re.I)
_COLOR_VEC = re.compile(r'colou?r', re.I)
_NOT_ALBEDO_VEC = re.compile(r'(dirt|emiss|sss|subsurface|fresnel|spec|fog|edge|rim|glow|'
                             r'light|shadow|wind|fade|fuzz|sheen|ao|ambient|blend_|overlay)', re.I)


# water: a material whose chain is named for water or ocean - but not the
# props that merely hold it (mi_WaterTank, mi_water_depot, a waterfall sheet)
_WATER_NAME = re.compile(r'(water|ocean)', re.I)
_NOT_WATER = re.compile(r'(tank|depot|bottle|gauge|plant|leak|_can|fall|drop|splash|'
                        r'footprint|particle|board|tower|heater|cooler|pipe|pump|meter)', re.I)
_W_COL = re.compile(r'^(colou?r ?/ ?opacity|water ?colou?r ?a?|water colou?r 1|colou?r|'
                    r'base ?colou?r|shallow ?colou?r)$', re.I)
_W_NRM_BAD = re.compile(r'(foam|algae|leaves|leaf|dirt|splash|drop|tile_normal|default|'
                        r'flat|noise|particle|plant)', re.I)
# measured on Source water in game: 0.15 / 0.55 / 0.95 read 219 / 193 / 135
# out of 255, and the physical ~0.04 turns the whole sheet white (README:
# "Water")
WATER_ROUGHNESS = 0.6
WATER_LUM = 0.04          # the water's own colour, linear luminance
WATER_SKY = (0.29, 0.44, 0.57)   # linear: the pale blue the waves catch


def is_water(names):
    return any(_WATER_NAME.search(n) and not _NOT_WATER.search(n) for n in names)


class MatInfo:
    __slots__ = ('index', 'two_sided', 'mask', 'triplanar', 'name', 'report', 'skip',
                 'water')

    def __init__(self, index, name):
        self.index = index; self.name = name
        self.two_sided = False; self.mask = None; self.triplanar = False
        self.report = {}
        self.skip = False
        self.water = 0.0          # > 0: a water surface, mapped world-aligned
                                  # with a tile this many metres across


class UMaterialBank:
    def __init__(self, glb, paks, albedo_px=512, normal_px=256, normals=True,
                 jpeg_q=90, roughness=0.85):
        self.glb = glb; self.paks = paks
        self.albedo_px = albedo_px; self.normal_px = normal_px
        self.normals = normals; self.jpeg_q = jpeg_q
        self.roughness = roughness
        self.cache = {}
        self._pkg = {}
        self._tex = {}
        self.report = []

    # ---- loading ---------------------------------------------------------
    def pkg(self, path):
        path = path.split('.')[0]
        if path not in self._pkg:
            try:
                self._pkg[path] = uasset.load_package(self.paks, path)
            except Exception:
                self._pkg[path] = None
        return self._pkg[path]

    def texture(self, path, max_px):
        key = (path, max_px)
        if key not in self._tex:
            a = None
            # not through the package cache: a texture package holds its
            # .ubulk, tens of MB for a 4K texture, and a level references
            # hundreds of them
            try:
                p = uasset.load_package(self.paks, path)
            except Exception:
                p = None
            if p is not None:
                ex = [e for e in p.exports if p.class_name(e) == 'Texture2D']
                if ex:
                    try:
                        a = utex.texture_rgba(p, ex[0], max_px=max_px)
                    except Exception:
                        a = None
            self._tex[key] = a
        return self._tex[key]

    def chain(self, path):
        """walk an instance chain: params (child first), blend, flags, refs"""
        out = dict(tex={}, vec={}, scal={}, blend=None, two_sided=None,
                   unlit=False, refs=[], base=None, names=[], switch={},
                   shading=None)
        seen = 0
        while path and seen < 12:
            seen += 1
            p = self.pkg(path)
            if p is None:
                break
            ex = [e for e in p.exports if p.class_name(e) in (
                'MaterialInstanceConstant', 'Material', 'MaterialInstanceDynamic')]
            if not ex:
                break
            e = ex[0]
            pr, _ = p.export_props(e)
            out['names'].append(path.split('/')[-1].split('.')[0])
            for t in pr.get('TextureParameterValues', []) or []:
                try:
                    n = t['ParameterInfo']['Name']; v = t['ParameterValue'][2]
                except (KeyError, TypeError, IndexError):
                    continue
                if v and n not in out['tex']:
                    out['tex'][n] = v
            for t in pr.get('VectorParameterValues', []) or []:
                try:
                    out['vec'].setdefault(t['ParameterInfo']['Name'], tuple(t['ParameterValue']))
                except (KeyError, TypeError):
                    pass
            for t in pr.get('ScalarParameterValues', []) or []:
                try:
                    out['scal'].setdefault(t['ParameterInfo']['Name'], float(t['ParameterValue']))
                except (KeyError, TypeError, ValueError):
                    pass
            sp = pr.get('StaticParameters')
            if isinstance(sp, dict):
                for t in sp.get('StaticSwitchParameters', []) or []:
                    try:
                        out['switch'].setdefault(t['ParameterInfo']['Name'], bool(t['Value']))
                    except (KeyError, TypeError):
                        pass
            bo = pr.get('BasePropertyOverrides')
            if isinstance(bo, dict):
                if bo.get('bOverride_BlendMode') and out['blend'] is None:
                    out['blend'] = bo.get('BlendMode')
                if bo.get('bOverride_TwoSided') and out['two_sided'] is None:
                    out['two_sided'] = bool(bo.get('TwoSided'))
                if bo.get('ShadingModel') == 'MSM_Unlit':
                    out['unlit'] = True
                if bo.get('ShadingModel') and out['shading'] is None:
                    out['shading'] = bo.get('ShadingModel')
            for t in pr.get('CachedReferencedTextures', []) or []:
                if isinstance(t, tuple) and t[2]:
                    out['refs'].append(t[2])
            if p.class_name(e) == 'Material':
                if out['blend'] is None:
                    out['blend'] = pr.get('BlendMode')
                if out['two_sided'] is None:
                    out['two_sided'] = bool(pr.get('TwoSided', False))
                if pr.get('ShadingModel') == 'MSM_Unlit':
                    out['unlit'] = True
                if out['shading'] is None:
                    out['shading'] = pr.get('ShadingModel')
                ced = pr.get('CachedExpressionData')
                if isinstance(ced, dict):
                    for t in ced.get('ReferencedTextures', []) or []:
                        if isinstance(t, tuple) and t[2]:
                            out['refs'].append(t[2])
                    self._defaults(ced.get('Parameters'), out)
                for i in p.imports:
                    if i['class_name'] == 'Texture2D':
                        out['refs'].append(i['name'])
                out['base'] = path
                break
            par = pr.get('Parent')
            path = par[2] if isinstance(par, tuple) and par[2] else None
        return out

    def _splat(self, ch, rep):
        """a splat-map material (the horizon backdrops): its R, G, B, A
        weights blend layer textures that tile far finer than the map, so
        each layer comes in as its mean colour"""
        refs = list(dict.fromkeys(r for r in ch['refs'] if r.startswith('/')))
        sp = next((r for r in refs if 'splat' in r.lower()), None)
        if sp is None:
            return None
        layers = [r for r in refs if r != sp and _ALB_NAME.search(r.split('.')[-1])
                  and not _NRM_NAME.search(r.split('.')[-1])][:4]
        w = self.texture(sp, self.albedo_px)
        cols = []
        for r in layers:
            t = self.texture(r, 64)
            if t is not None:
                cols.append(t[..., :3].reshape(-1, 3).mean(0))
        if w is None or len(cols) < 2:
            return None
        wt = w[..., :len(cols)].astype(np.float32)
        wt /= np.maximum(wt.sum(-1, keepdims=True), 1.0)
        out = np.empty(w.shape[:2] + (4,), np.uint8)
        out[..., :3] = np.clip(wt @ np.array(cols, np.float32), 0, 255).astype(np.uint8)
        out[..., 3] = 255
        rep['splat'] = [r.split('.')[-1] for r in layers[:len(cols)]]
        return out

    @staticmethod
    def _defaults(par, out):
        """the base material's own parameter values (its graph's defaults)"""
        if not isinstance(par, dict):
            return
        kinds = (('RuntimeEntries', 'ScalarValues', 'scal'),
                 ('RuntimeEntries[1]', 'VectorValues', 'vec'),
                 ('RuntimeEntries[2]', 'TextureValues', 'tex'))
        for ek, vk, ok in kinds:
            ent = par.get(ek); vals = par.get(vk)
            if not isinstance(ent, dict) or not isinstance(vals, list):
                continue
            infos = ent.get('ParameterInfos') or []
            for info, v in zip(infos, vals):
                try:
                    n = info['Name']
                except (KeyError, TypeError):
                    continue
                if ok == 'tex':
                    v = v[2] if isinstance(v, tuple) and len(v) > 2 else None
                    if not v:
                        continue
                elif ok == 'vec':
                    v = tuple(v)
                out[ok].setdefault(n, v)

    def _pick(self, ch, param_re, name_re, skip=None, avoid=None):
        def ok(v):
            leaf = v.split('.')[-1].split('/')[-1]
            return not (v.startswith(_ENGINE_DEFAULTS) or (skip and skip.search(leaf))
                        or (avoid and avoid.search(leaf)))
        for n, v in ch['tex'].items():
            if param_re.match(n.strip()) and not v.startswith(_ENGINE_DEFAULTS) \
                    and not (avoid and avoid.search(v.split('.')[-1])):
                return v
        for n, v in ch['tex'].items():
            leaf = v.split('.')[-1]
            if name_re.search(leaf) and ok(v):
                return v
        for v in ch['refs']:
            leaf = v.split('.')[-1].split('/')[-1]
            if name_re.search(leaf) and ok(v):
                return self._full(v, ch)
        return None

    def _full(self, v, ch):
        if v.startswith('/'):
            return v
        # a bare import name: find it next to the base material's package
        p = self.pkg(ch['base']) if ch['base'] else None
        if p is not None:
            for i in p.imports:
                if i['name'] == v and i['class_name'] == 'Texture2D':
                    o = p.imports[-i['outer'] - 1] if i['outer'] < 0 else None
                    if o is not None:
                        return o['name'] + '.' + v
        return None

    # ---- the material ------------------------------------------------------
    def get(self, path, label=None):
        key = path or '<none>'
        if key in self.cache:
            return self.cache[key]
        info = self._build(path, label)
        self.cache[key] = info
        return info

    def _build(self, path, label):
        name = (label or (path or 'none').split('.')[-1])
        rep = {'material': path}
        if not path:
            idx = self.glb.material(name, roughness=self.roughness,
                                    albedo_tex=self.solid(name, (0.5, 0.5, 0.5)))
            mi = MatInfo(idx, name); mi.report = rep; self.report.append(rep)
            return mi
        ch = self.chain(path)
        lname = ' '.join(ch['names']).lower()
        rep['chain'] = ch['names']
        if is_water(ch['names']):
            return self._water(ch, name, rep)
        # a leaf / branch material that also carries its tree's bark texture
        avoid = re.compile('bark', re.I) if (_FOLIAGE.search(lname) and 'bark' not in lname) else None
        alb_path = self._pick(ch, _ALB_PARAM, _ALB_NAME, _SKIP_TEX, avoid)
        nrm_path = self._pick(ch, _NRM_PARAM, _NRM_NAME, _SKIP_NRM, avoid) if self.normals else None
        tint = None
        for n, v in ch['vec'].items():
            if n.strip().lower() in _TINT_PARAM:
                tint = v[:3]
                break
        flat = None
        mixed = None
        if alb_path is None:
            for n in ('Color', 'BaseColor', 'Base Color', 'Albedo', 'Colour',
                      'Color / opacity', 'diffuse color', 'Param'):
                if n in ch['vec']:
                    flat = ch['vec'][n][:3]
                    break
            # a mask whose channels pick between colour parameters
            # (ModularHouses' M_Master_Generic: Albedo_Color_1..3)
            cols = sorted((k, v) for k, v in ch['vec'].items()
                          if re.match(r'^albedo_?colou?r_?\d$', k, re.I))
            mpath = next((v for k, v in ch['tex'].items() if k.lower() == 'mask'), None)
            if len(cols) >= 2 and mpath:
                m = self.texture(mpath, self.albedo_px)
                if m is not None:
                    w = m[..., :len(cols)].astype(np.float32) / 255.0
                    w /= np.maximum(w.sum(-1, keepdims=True), 1e-3)
                    c = np.stack([_srgb(v[:3]) for _, v in cols[:w.shape[-1]]]).astype(np.float32)
                    mixed = np.empty(m.shape[:2] + (4,), np.uint8)
                    mixed[..., :3] = np.clip(w @ c * 255, 0, 255).astype(np.uint8)
                    mixed[..., 3] = 255
                    rep['mixed'] = [k for k, _ in cols]
            if flat is None and mixed is None:
                # any other colour parameter that reads as the surface colour
                for n, v in ch['vec'].items():
                    if _COLOR_VEC.search(n) and not _NOT_ALBEDO_VEC.search(n):
                        flat = v[:3]
                        break
            if flat is None and mixed is None:
                # one plain texture, named nothing in particular (face_ncl1_1)
                cand = [r for r in ch['refs'] if r.startswith('/') and not r.startswith(_ENGINE_DEFAULTS)
                        and not _SKIP_TEX.search(r.split('.')[-1])]
                if len(set(cand)) == 1:
                    alb_path = cand[0]
        if alb_path is None and mixed is None:
            mixed = self._splat(ch, rep)
        blend = ch['blend'] or 'BLEND_Opaque'
        alb = self.texture(alb_path, self.albedo_px) if alb_path else mixed
        rep['albedo'] = alb_path
        alpha_mode = 'OPAQUE'
        alb_tex = None
        base_color = (1.0, 1.0, 1.0, 1.0)
        emissive = None
        if alb is not None:
            rgba = alb.astype(np.float32)
            if tint is not None:
                rgba[..., :3] *= np.asarray(_srgb(tint), np.float32)[None, None, :]
                rep['tint'] = [round(float(x), 3) for x in tint]
            sw = ch['switch']
            a = alb[..., 3].astype(np.float32) / 255.0
            col_mask = sw.get('Use alpha as Color mask', False)
            if sw.get('Add Color Settings') and 'diffuse color' in ch['vec']:
                c = np.asarray(_srgb(ch['vec']['diffuse color'][:3]), np.float32)
                w = a[..., None] if col_mask else 1.0
                rgba[..., :3] *= (1.0 - w) + w * c[None, None, :]
                rep['paint'] = [round(float(x), 3) for x in c]
            rgba = np.clip(rgba, 0, 255).astype(np.uint8)
            opacity = (blend in ('BLEND_Masked', 'BLEND_Translucent') and not col_mask
                       and alb[..., 3].min() < 128
                       and (any(v and re.search('opacity', k, re.I) for k, v in sw.items())
                            or 'Foliage' in str(ch['shading'] or '')
                            or bool(_FOLIAGE.search(lname))))
            if opacity:
                frac = float(((alb[..., 3] > 10) & (alb[..., 3] < 245)).mean())
                alpha_mode = 'MASK' if (blend == 'BLEND_Masked' or frac < 0.15) else 'BLEND'
            else:
                rgba[..., 3] = 255
            img = _fit(rgba, self.albedo_px)
            if alpha_mode == 'OPAQUE':
                alb_tex = self._jpeg(_jpg(img, self.jpeg_q), name)
            else:
                alb_tex = self.glb.image(_png(img), name)
        elif flat is not None:
            c = _srgb(flat)
            base_color = (*[float(min(x, 1.0)) for x in c], 1.0)
            rep['flat'] = [round(x, 3) for x in base_color[:3]]
        else:
            base_color = (0.5, 0.5, 0.5, 1.0)
            rep['flat'] = 'grey (no texture found)'
        if ch['unlit'] or 'emissive' in lname:
            src = flat if flat is not None else (1, 1, 1)
            emissive = tuple(float(min(1.0, x)) for x in _srgb(src))
        if blend == 'BLEND_Translucent' and alb is None:
            alpha_mode = 'BLEND'
            base_color = (*base_color[:3], 0.3)
        if alb_tex is None:
            # a flat colour goes in as a tiny texture, never baseColorFactor:
            # the game's importer turns the factor linear->sRGB and its shader
            # then uses that as linear (albedo_color has no source_color
            # hint), so a factor shows as srgb(factor) - MI_WhiteSimplWall's
            # 0.78 white came out 0.95. The texture is read with source_color,
            # like every other albedo.
            alb_tex = self.solid(name, base_color[:3], base_color[3])
            base_color = (1.0, 1.0, 1.0, 1.0)
        nrm_tex = None
        if nrm_path:
            n = self.texture(nrm_path, self.normal_px)
            if n is not None:
                n = n[..., :3].copy()
                n[..., 1] = 255 - n[..., 1]           # DirectX -> OpenGL green
                nrm_tex = self.glb.image(_png(_fit(n, self.normal_px).convert('RGB'), optimize=False),
                                         name + '_n')
                rep['normal'] = nrm_path
        rough = self.roughness
        for k in ('Roughness', 'roughness', 'Roughness Multiplier', 'RoughnessValue'):
            if k in ch['scal']:
                rough = float(np.clip(ch['scal'][k], 0.5, 1.0))
                break
        idx = self.glb.material(name, albedo_tex=alb_tex, normal_tex=nrm_tex,
                                roughness=rough, metallic=0.0,
                                base_color=base_color, alpha_mode=alpha_mode,
                                emissive=emissive)
        mi = MatInfo(idx, name)
        mi.skip = bool(_HELPER.search(' '.join(ch['names'])))
        mi.two_sided = bool(ch['two_sided']) or alpha_mode == 'MASK'
        if alpha_mode == 'MASK' and alb is not None:
            mi.mask = OpaqueMask(alb[..., 3])
        rep.update(alpha=alpha_mode, two_sided=mi.two_sided, roughness=round(rough, 3))
        mi.report = rep
        self.report.append(rep)
        return mi

    # ---- water ------------------------------------------------------------------
    def _water(self, ch, name, rep):
        """A water surface. Unreal draws water as sky reflection and refraction
        over a near-black colour (MI_Water8_me's is 0.010 / 0.015 / 0.013);
        The Zone's shader has neither, and the flat colour that leaves reads
        as a grey sheet. So the look is baked into one tile: the material's
        wave normal map at two scales - the fine one at the material's own
        world tiling, the coarse one four times larger and transposed, so the
        repeat does not show - and an albedo made from the same normals: the
        water's colour lifted to a visible value, with sky-coloured streaks
        where the waves tilt and a little relief shading. The caller maps it
        world-aligned with MatInfo.water = the tile's size in metres."""
        col = None
        for k, v in ch['vec'].items():
            if _W_COL.match(k.strip()) and max(v[:3]) > 1e-4 and min(v[:3]) < 0.8:
                col = np.asarray(v[:3], np.float64)
                rep['water_colour_param'] = k
                break
        if col is None:
            col = np.array([0.012, 0.02, 0.022])
        npath = None
        for k, v in ch['tex'].items():
            if (re.search('normal', k, re.I) and not v.startswith(_ENGINE_DEFAULTS)
                    and not _W_NRM_BAD.search(v.split('.')[-1])):
                npath = v
                break
        if npath is None:
            cand = [r for r in dict.fromkeys(ch['refs']) if r.startswith('/')
                    and _NRM_NAME.search(r.split('.')[-1])
                    and not _W_NRM_BAD.search(r.split('.')[-1])]
            cand.sort(key=lambda r: (r.startswith(_ENGINE_DEFAULTS),
                                     not re.search(r'(water|wave)', r.split('.')[-1], re.I)))
            npath = cand[0] if cand else None
        fine = 4.0
        for k, v in ch['scal'].items():
            if re.match(r'^tiles? ?world$', k.strip(), re.I) and 0 < v < 0.05:
                fine = 0.01 / v
                break
        fine = float(np.clip(fine, 2.0, 12.0))
        px = 1024 if self.albedo_px >= 512 else 512
        nrm = self.texture(npath, px) if npath else None
        alb, nmap = water_tile(nrm, col, px)
        alb_tex = self._jpeg(_jpg(Image.fromarray(alb), self.jpeg_q), name)
        nrm_tex = None
        if nmap is not None and self.normals:
            nrm_tex = self.glb.image(_png(Image.fromarray(nmap), optimize=False), name + '_n')
        idx = self.glb.material(name, albedo_tex=alb_tex, normal_tex=nrm_tex,
                                roughness=WATER_ROUGHNESS, metallic=0.0)
        mi = MatInfo(idx, name)
        mi.water = 4 * fine
        rep.update(water={'colour': [round(float(x), 4) for x in col], 'normal': npath,
                          'tile_m': round(mi.water, 2)},
                   alpha='OPAQUE', two_sided=False, roughness=WATER_ROUGHNESS)
        mi.report = rep
        self.report.append(rep)
        return mi

    # ---- decals -----------------------------------------------------------------
    _DEC_COL = re.compile(r'^(decaltexture|texture|albedo|base ?colou?r|colou?r|bc|diffuse|'
                          r'tex|decal)$', re.I)
    _DEC_OPA = re.compile(r'^(opacity|opacity ?mask|mask|alpha ?texture|alpha|puddle map)$', re.I)
    _DEC_TINT = ('tint', 'albedocolor', 'puddlecolor', 'colors', 'color', 'decal color',
                 'color overlay')

    def decal(self, path):
        """a deferred-decal material -> MatInfo with its opacity in the alpha"""
        key = ('decal', path)
        if key in self.cache:
            return self.cache[key]
        ch = self.chain(path)
        name = (path or 'decal').split('.')[-1]
        col_p = next((v for k, v in ch['tex'].items() if self._DEC_COL.match(k.strip())
                      and not v.startswith(_ENGINE_DEFAULTS)), None)
        if col_p is None:
            col_p = self._pick(ch, _ALB_PARAM, _ALB_NAME, _SKIP_TEX)
        opa_p = next((v for k, v in ch['tex'].items() if self._DEC_OPA.match(k.strip())
                      and not v.startswith(_ENGINE_DEFAULTS)), None)
        tint = None
        for k, v in ch['vec'].items():
            if k.strip().lower() in self._DEC_TINT:
                if k.strip().lower() == 'color overlay' and max(abs(x - 0.5) for x in v[:3]) < 0.02:
                    continue                      # Megascans' neutral overlay
                tint = v[:3]
                break
        leaf = lambda p: p.split('.')[-1].split('/')[-1]
        lname = ' '.join(ch['names']).lower()
        wet = bool(re.search(r'(puddle|wet|water)', lname))
        if col_p and opa_p is None and re.search(r'(_msk|mask|_a$|opacity|alpha)', leaf(col_p), re.I):
            col_p, opa_p = None, col_p          # a mask wired in as the colour
        if opa_p is None:
            opa_p = next((r for r in ch['refs'] if r.startswith('/') and not r.startswith(_ENGINE_DEFAULTS)
                          and re.search(r'(_msk$|mask|_a$|opacity|alpha)', leaf(r), re.I)), None)
        if wet:
            # a puddle darkens and wets what it lies on; the game's shader can
            # only lay a colour over it, so: a dark, half-transparent pool
            col_p = None
            if tint is None or max(tint) > 0.2:
                tint = (0.03, 0.035, 0.04)
        col = self.texture(col_p, self.albedo_px) if col_p else None
        opa = self.texture(opa_p, self.albedo_px) if opa_p else None
        if col is not None and col[..., 3].min() < 200:
            alpha = col[..., 3]
        elif opa is not None:
            alpha = opa[..., 0]
        else:
            alpha = None
        if wet and alpha is not None:
            alpha = (alpha.astype(np.float32) * 0.6).astype(np.uint8)
        h, w = (alpha.shape if alpha is not None else
                (col.shape[:2] if col is not None else (8, 8)))
        if col is not None and col.shape[:2] != (h, w):
            col = np.asarray(Image.fromarray(col).resize((w, h), Image.BILINEAR))
        rgba = np.empty((h, w, 4), np.float32)
        if col is not None:
            rgba[..., :3] = col[..., :3]
        else:
            rgba[..., :3] = 255.0
        if tint is not None:
            rgba[..., :3] *= np.asarray(_srgb(tint), np.float32)
        rgba[..., 3] = 255 if alpha is None else alpha
        mi = self.decal_image(np.clip(rgba, 0, 255).astype(np.uint8), name)
        mi.report.update(material=path, albedo=col_p, opacity=opa_p,
                         tint=None if tint is None else [round(float(x), 3) for x in tint])
        self.cache[key] = mi
        return mi

    def decal_image(self, rgba, name):
        a = rgba[..., 3]
        frac = float(((a > 10) & (a < 245)).mean())
        mode = 'BLEND' if frac > 0.12 else 'MASK'
        img = _fit(rgba, self.albedo_px)
        tex = self.glb.image(_png(img, optimize=False), name)
        idx = self.glb.material(name, albedo_tex=tex, roughness=0.9, metallic=0.0,
                                alpha_mode=mode)
        mi = MatInfo(idx, name)
        mi.report = {'material': name, 'decal': True, 'alpha': mode}
        self.report.append(mi.report)
        return mi

    def from_image(self, name, rgba, roughness=0.9):
        img = _fit(rgba, self.albedo_px)
        idx = self.glb.material(name, albedo_tex=self._jpeg(_jpg(img, self.jpeg_q), name),
                                roughness=roughness, metallic=0.0)
        mi = MatInfo(idx, name)
        mi.report = {'material': name, 'generated': True}
        self.report.append(mi.report)
        return mi

    def from_texture(self, name, tex_path, tint=None, normal_path=None, roughness=0.9):
        """a plain material from one texture (and an optional tint)"""
        alb = self.texture(tex_path, self.albedo_px) if tex_path else None
        alb_tex = nrm_tex = None
        base = (1.0, 1.0, 1.0, 1.0)
        if alb is not None:
            rgba = alb.astype(np.float32)
            if tint is not None:
                rgba[..., :3] *= np.asarray(_srgb(tint), np.float32)[None, None, :]
            rgba[..., 3] = 255
            img = _fit(np.clip(rgba, 0, 255).astype(np.uint8), self.albedo_px)
            alb_tex = self._jpeg(_jpg(img, self.jpeg_q), name)
        elif tint is not None:
            alb_tex = self.solid(name, _srgb(tint))      # (see _build: no factors)
        if normal_path and self.normals:
            n = self.texture(normal_path, self.normal_px)
            if n is not None:
                n = n[..., :3].copy(); n[..., 1] = 255 - n[..., 1]
                nrm_tex = self.glb.image(_png(_fit(n, self.normal_px).convert('RGB')), name + '_n')
        idx = self.glb.material(name, albedo_tex=alb_tex, normal_tex=nrm_tex,
                                roughness=roughness, metallic=0.0, base_color=base)
        mi = MatInfo(idx, name)
        mi.report = {'material': name, 'albedo': tex_path, 'tint': tint, 'normal': normal_path}
        self.report.append(mi.report)
        return mi

    def solid(self, name, rgb, alpha=1.0):
        """a 4 x 4 texture of one sRGB colour (and alpha)"""
        a = np.empty((4, 4, 4), np.uint8)
        a[..., :3] = np.clip(np.rint(np.asarray(rgb[:3], np.float64) * 255), 0, 255).astype(np.uint8)
        a[..., 3] = int(round(float(np.clip(alpha, 0, 1)) * 255))
        img = Image.fromarray(a, 'RGBA') if alpha < 1.0 else Image.fromarray(a[..., :3], 'RGB')
        return self.glb.image(_png(img, optimize=False), name + '_c')

    def _jpeg(self, data, name):
        g = self.glb
        key = hash(bytes(data))
        if key in g._img_cache:
            return g._img_cache[key]
        v = g._view(data)
        g.j['images'].append({'bufferView': v, 'mimeType': 'image/jpeg', 'name': name})
        g.j['textures'].append({'sampler': 0, 'source': len(g.j['images']) - 1})
        idx = len(g.j['textures']) - 1
        g._img_cache[key] = idx
        return idx



def _lin(c):
    c = np.asarray(c, np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _nfield(rgb, n, blur=0.0):
    """a DirectX normal map (uint8) at n x n -> unit vectors (n, n, 3)"""
    from PIL import ImageFilter
    im = Image.fromarray(np.ascontiguousarray(rgb[..., :3])).resize((n, n), Image.LANCZOS)
    if blur:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    v = np.asarray(im).astype(np.float32) / 127.5 - 1.0
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-6)


def _octaves(nrm, px, reps=4, coarse=0.8, blur=0.0):
    """the fine map tiled reps x reps, plus itself once at full size,
    transposed (pattern and vectors both, which keeps it a valid normal
    field), blended whiteout-style"""
    f = np.tile(_nfield(nrm, px // reps, blur), (reps, reps, 1))
    c = _nfield(nrm, px, blur * reps).transpose(1, 0, 2)[..., [1, 0, 2]]
    xy = f[..., :2] + coarse * c[..., :2]
    z = np.clip(f[..., 2], 0.2, 1.0) * np.clip(c[..., 2], 0.2, 1.0)
    v = np.dstack([xy, z])
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def water_tile(nrm, colour, px=1024):
    """-> (albedo RGB uint8, OpenGL normal map RGB uint8 or None) for one
    world-aligned water tile; see UMaterialBank._water"""
    c = np.asarray(colour, np.float64)
    lum = float(0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2])
    if lum < 1e-5:
        c, lum = np.array([0.012, 0.02, 0.022]), 0.0184
    c = c * 0.9 + lum * 0.1                       # no channel left at exactly 0
    base = c * (WATER_LUM / lum)
    sky = np.asarray(WATER_SKY, np.float64)
    if nrm is None:
        img = np.empty((64, 64, 3), np.uint8)
        img[:] = np.clip(_srgb(base * 0.94 + sky * 0.06) * 255, 0, 255).astype(np.uint8)
        return img, None
    n = _octaves(nrm, px)
    ns = _octaves(nrm, px, blur=1.5)             # smoothed, for the colour
    tilt = np.hypot(ns[..., 0], ns[..., 1])
    r = np.clip(0.06 + 0.6 * tilt, 0.0, 0.3)[..., None]
    L = np.array([-0.45, 0.35, 0.82]); L /= np.linalg.norm(L)
    shade = 1.0 + 1.8 * ((ns @ L) - L[2])
    col = (base * (1 - r) + sky * r) * shade[..., None]
    alb = np.clip(_srgb(np.clip(col, 0, 1)) * 255, 0, 255).astype(np.uint8)
    nm = np.clip((n * 0.5 + 0.5) * 255, 0, 255).astype(np.uint8)
    nm[..., 1] = 255 - nm[..., 1]                 # DirectX -> OpenGL green
    return alb, nm
