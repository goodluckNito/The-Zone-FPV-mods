"""Minimal, dependency-free glTF 2.0 / GLB writer tuned for The Zone FPV."""
import json, struct, io, numpy as np

F32, U32, U16 = 5126, 5125, 5123


class Glb:
    def __init__(self, generator='zone-map-forge'):
        self.j = {
            'asset': {'version': '2.0', 'generator': generator},
            'scenes': [{'nodes': []}], 'scene': 0,
            'nodes': [], 'meshes': [], 'materials': [],
            'textures': [], 'images': [], 'samplers': [
                {'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497}],
            'accessors': [], 'bufferViews': [], 'buffers': [],
        }
        self.blob = bytearray()
        self._img_cache = {}

    # ---- buffer plumbing -------------------------------------------------
    def _view(self, data, target=None):
        while len(self.blob) % 4:
            self.blob.append(0)
        off = len(self.blob)
        self.blob += data
        v = {'buffer': 0, 'byteOffset': off, 'byteLength': len(data)}
        if target:
            v['target'] = target
        self.j['bufferViews'].append(v)
        return len(self.j['bufferViews']) - 1

    def _acc(self, arr, ctype, atype, target=None, minmax=False):
        arr = np.ascontiguousarray(arr)
        v = self._view(arr.tobytes(), target)
        a = {'bufferView': v, 'componentType': ctype, 'count': int(arr.shape[0]),
             'type': atype}
        if minmax:
            flat = arr.reshape(arr.shape[0], -1)
            a['min'] = [float(x) for x in flat.min(axis=0)]
            a['max'] = [float(x) for x in flat.max(axis=0)]
        self.j['accessors'].append(a)
        return len(self.j['accessors']) - 1

    # ---- textures --------------------------------------------------------
    def image(self, png_bytes, name=None):
        key = hash(bytes(png_bytes))
        if key in self._img_cache:
            return self._img_cache[key]
        v = self._view(png_bytes)
        self.j['images'].append({'bufferView': v, 'mimeType': 'image/png',
                                 **({'name': name} if name else {})})
        self.j['textures'].append({'sampler': 0, 'source': len(self.j['images']) - 1})
        idx = len(self.j['textures']) - 1
        self._img_cache[key] = idx
        return idx

    def material(self, name, albedo_tex=None, normal_tex=None,
                 roughness=0.85, metallic=0.0, base_color=(1, 1, 1, 1),
                 alpha_mode='OPAQUE', double_sided=False, normal_scale=1.0,
                 emissive=None):
        pbr = {'metallicFactor': float(metallic), 'roughnessFactor': float(roughness),
               'baseColorFactor': [float(x) for x in base_color]}
        if albedo_tex is not None:
            pbr['baseColorTexture'] = {'index': albedo_tex}
        m = {'name': name, 'pbrMetallicRoughness': pbr, 'alphaMode': alpha_mode,
             'doubleSided': bool(double_sided)}
        if alpha_mode == 'MASK':
            m['alphaCutoff'] = 0.5
        if normal_tex is not None:
            m['normalTexture'] = {'index': normal_tex, 'scale': float(normal_scale)}
        if emissive:
            m['emissiveFactor'] = [float(x) for x in emissive]
        self.j['materials'].append(m)
        return len(self.j['materials']) - 1

    # ---- geometry --------------------------------------------------------
    def mesh(self, name, prims):
        """prims: (pos, nrm|None, uv|None, idx, material_index[, uv2|None])"""
        out = []
        for prim in prims:
            pos, nrm, uv, idx, mat = prim[:5]
            uv2 = prim[5] if len(prim) > 5 else None
            attrs = {'POSITION': self._acc(np.asarray(pos, '<f4'), F32, 'VEC3',
                                           34962, minmax=True)}
            if nrm is not None:
                attrs['NORMAL'] = self._acc(np.asarray(nrm, '<f4'), F32, 'VEC3', 34962)
            if uv is not None:
                attrs['TEXCOORD_0'] = self._acc(np.asarray(uv, '<f4'), F32, 'VEC2', 34962)
            if uv2 is not None:
                attrs['TEXCOORD_1'] = self._acc(np.asarray(uv2, '<f4'), F32, 'VEC2', 34962)
            idx = np.asarray(idx, '<u4').reshape(-1)
            p = {'attributes': attrs,
                 'indices': self._acc(idx, U32, 'SCALAR', 34963), 'mode': 4}
            if mat is not None:
                p['material'] = int(mat)
            out.append(p)
        self.j['meshes'].append({'name': name, 'primitives': out})
        return len(self.j['meshes']) - 1

    def node(self, name, mesh=None, children=None, translation=None,
             rotation=None, scale=None):
        n = {'name': name}
        if mesh is not None:
            n['mesh'] = int(mesh)
        if children:
            n['children'] = [int(c) for c in children]
        if translation is not None:
            n['translation'] = [float(x) for x in translation]
        if rotation is not None:
            n['rotation'] = [float(x) for x in rotation]
        if scale is not None:
            n['scale'] = [float(x) for x in scale]
        self.j['nodes'].append(n)
        return len(self.j['nodes']) - 1

    def root(self, node_idx):
        self.j['scenes'][0]['nodes'].append(int(node_idx))

    # ---- output ----------------------------------------------------------
    def save(self, path):
        self.j['buffers'] = [{'byteLength': len(self.blob)}]
        js = json.dumps(self.j, separators=(',', ':')).encode('utf-8')
        js += b' ' * ((4 - len(js) % 4) % 4)
        bin_ = bytes(self.blob) + b'\0' * ((4 - len(self.blob) % 4) % 4)
        total = 12 + 8 + len(js) + 8 + len(bin_)
        with open(path, 'wb') as f:
            f.write(struct.pack('<III', 0x46546C67, 2, total))
            f.write(struct.pack('<II', len(js), 0x4E4F534A)); f.write(js)
            f.write(struct.pack('<II', len(bin_), 0x004E4942)); f.write(bin_)
        return total
