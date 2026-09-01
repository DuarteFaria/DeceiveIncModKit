"""Minimal UE4 pak v11 reader: AES index decryption, full directory index,
encoded entry decoding, Zlib + Oodle decompression."""
import struct, sys, zlib, ctypes, os, fnmatch
from Crypto.Cipher import AES

OODLE_DLL = r"C:\Program Files (x86)\Steam\steamapps\common\Marathon\bin\x64\oo2core_9_win64.dll"
_ood = None

def oodle_decompress(src, dst_size):
    global _ood
    if _ood is None:
        _ood = ctypes.WinDLL(OODLE_DLL)
        _ood.OodleLZ_Decompress.restype = ctypes.c_int64
        _ood.OodleLZ_Decompress.argtypes = [
            ctypes.c_char_p, ctypes.c_int64, ctypes.c_char_p, ctypes.c_int64,
            ctypes.c_int32, ctypes.c_int32, ctypes.c_int64,
            ctypes.c_void_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_void_p, ctypes.c_int64, ctypes.c_int32]
    out = ctypes.create_string_buffer(dst_size)
    n = _ood.OodleLZ_Decompress(src, len(src), out, dst_size,
                                1, 0, 0, None, 0, None, None, None, 0, 3)
    if n != dst_size:
        raise RuntimeError(f"Oodle returned {n}, expected {dst_size}")
    return out.raw[:dst_size]


class Reader:
    def __init__(self, buf):
        self.b = buf; self.p = 0
    def raw(self, n):
        v = self.b[self.p:self.p + n]; self.p += n; return v
    def i32(self):
        v = struct.unpack_from('<i', self.b, self.p)[0]; self.p += 4; return v
    def u32(self):
        v = struct.unpack_from('<I', self.b, self.p)[0]; self.p += 4; return v
    def i64(self):
        v = struct.unpack_from('<q', self.b, self.p)[0]; self.p += 8; return v
    def u64(self):
        v = struct.unpack_from('<Q', self.b, self.p)[0]; self.p += 8; return v
    def fstring(self):
        n = self.i32()
        if n == 0:
            return ""
        if n > 0:
            s = self.raw(n)
            return s[:-1].decode('utf-8', 'replace')
        s = self.raw(-n * 2)
        return s[:-2].decode('utf-16-le', 'replace')


def aes_dec(key, data):
    n = (len(data) // 16) * 16
    return AES.new(key, AES.MODE_ECB).decrypt(data[:n])


class Pak:
    def __init__(self, path, key):
        self.path = path
        self.key = key
        self.f = open(path, 'rb')
        self.f.seek(0, 2); self.size = self.f.tell()
        self.f.seek(self.size - 221)
        d = self.f.read(221)
        assert struct.unpack('<I', d[17:21])[0] == 0x5A6F12E1, "bad pak magic"
        self.encrypted = d[16] == 1
        self.version = struct.unpack('<I', d[21:25])[0]
        self.index_off, self.index_size = struct.unpack('<qq', d[25:41])
        cm = d[61:61 + 160]
        self.methods = [None]
        for i in range(5):
            name = cm[i * 32:(i + 1) * 32].rstrip(b'\0').decode('ascii', 'replace')
            if name:
                self.methods.append(name)
        self.files = {}
        self._load_index()

    def _read_at(self, off, size, decrypt):
        self.f.seek(off)
        raw = self.f.read(size if not decrypt else ((size + 15) // 16) * 16)
        if decrypt:
            raw = aes_dec(self.key, raw)[:size]
        return raw

    def _load_index(self):
        idx = self._read_at(self.index_off, self.index_size, self.encrypted)
        r = Reader(idx)
        self.mount = r.fstring()
        self.num_entries = r.i32()
        self.path_hash_seed = r.u64()
        if r.i32():                        # bReaderHasPathHashIndex
            r.i64(); r.i64(); r.raw(20)
        has_fdi = r.i32()
        if not has_fdi:
            raise RuntimeError("pak has no full directory index")
        fdi_off = r.i64(); fdi_size = r.i64(); r.raw(20)
        enc_len = r.i32()
        self.encoded = r.raw(enc_len)

        fdi = self._read_at(fdi_off, fdi_size, self.encrypted)
        fr = Reader(fdi)
        ndirs = fr.i32()
        for _ in range(ndirs):
            d = fr.fstring()
            nf = fr.i32()
            for _ in range(nf):
                fn = fr.fstring()
                eoff = fr.i32()
                self.files[(d + fn).replace('\\', '/')] = eoff

    def _entry_header_size(self, method_idx, nblocks):
        n = 8 + 8 + 8 + 20 + 4 + 1 + 4
        if method_idx != 0:
            n += 4 + 16 * nblocks
        return n

    def decode(self, eoff):
        r = Reader(self.encoded); r.p = eoff
        v = r.u32()
        blk_size = (v & 0x3f) << 11
        nblocks = (v >> 6) & 0xffff
        enc = (v >> 22) & 1
        method = (v >> 23) & 0x3f
        size32 = (v >> 29) & 1
        usize32 = (v >> 30) & 1
        off32 = (v >> 31) & 1
        offset = r.u32() if off32 else r.u64()
        usize = r.u32() if usize32 else r.u64()
        size = (r.u32() if size32 else r.u64()) if method != 0 else usize
        blocks = []
        if nblocks > 0:
            hdr = self._entry_header_size(method, nblocks)
            if nblocks == 1:
                start = offset + hdr
                blocks = [(start, start + size)]
            else:
                cur = offset + hdr
                for _ in range(nblocks):
                    bs = r.u32()
                    blocks.append((cur, cur + bs))
                    cur = cur + bs
                    if enc:
                        cur = (cur + 15) & ~15
        return dict(offset=offset, size=size, usize=usize, method=method,
                    enc=enc, blk_size=blk_size, blocks=blocks, nblocks=nblocks)

    def read_file(self, path):
        eoff = self.files[path]
        if eoff < 0:
            raise RuntimeError("entry stored in Files array; unsupported")
        e = self.decode(eoff)
        if e['method'] == 0:
            hdr = self._entry_header_size(0, 0)
            raw = self._read_at(e['offset'] + hdr, e['size'], e['enc'])
            return raw[:e['usize']]
        name = self.methods[e['method']] if e['method'] < len(self.methods) else '?'
        out = b''
        remaining = e['usize']
        for (s, en) in e['blocks']:
            csz = en - s
            raw = self._read_at(s, csz, e['enc'])
            want = min(e['blk_size'], remaining) if e['nblocks'] > 1 else remaining
            if name.lower() == 'zlib':
                dec = zlib.decompress(raw)
            elif name.lower() == 'oodle':
                dec = oodle_decompress(raw, want)
            else:
                raise RuntimeError("unknown method " + name)
            out += dec
            remaining -= len(dec)
        return out[:e['usize']]


if __name__ == '__main__':
    pak = sys.argv[1]
    key = bytes.fromhex(sys.argv[2].removeprefix('0x'))
    cmd = sys.argv[3] if len(sys.argv) > 3 else 'list'
    p = Pak(pak, key)
    print(f"mount={p.mount!r} entries={p.num_entries} methods={p.methods[1:]} files={len(p.files)}")
    if cmd == 'list':
        pat = sys.argv[4] if len(sys.argv) > 4 else '*'
        hits = [f for f in sorted(p.files) if fnmatch.fnmatch(f.lower(), pat.lower())]
        for f in hits[:400]:
            print(" ", f)
        print(f"({len(hits)} match)")
    elif cmd == 'extract':
        src, dst = sys.argv[4], sys.argv[5]
        data = p.read_file(src)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'wb').write(data)
        print(f"wrote {len(data)} bytes -> {dst}  magic={data[:4].hex()}")
