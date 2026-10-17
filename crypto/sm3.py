"""SM3 cryptographic hash (GM/T 0004-2012), pure Python 3 stdlib.

Public API:
    sm3(data) -> bytes          # 32-byte digest
    SM3                         # incremental hasher: update/digest/hexdigest/copy

If the platform's hashlib happens to provide 'sm3' (OpenSSL 3.x builds do), it is
used as a fast path -- but only after this module has proven at import time that
it yields byte-identical output to the pure-Python implementation below.
"""

import hashlib
import struct

__all__ = ["sm3", "SM3", "HAS_HASHLIB_SM3", "BLOCK_SIZE", "DIGEST_SIZE"]

BLOCK_SIZE = 64
DIGEST_SIZE = 32

_IV = (
    0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
    0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
)

_T0 = 0x79CC4519  # j in [0, 15]
_T1 = 0x7A879D8A  # j in [16, 63]

# Precomputed T_j <<< j (equivalently T_j <<< (j % 32)) for j in [0, 63].
_ROT_T = tuple(
    (((_T0 if j < 16 else _T1) << (j % 32)) | ((_T0 if j < 16 else _T1) >> (32 - (j % 32)) if (j % 32) else 0))
    & 0xFFFFFFFF
    for j in range(64)
)

_MASK32 = 0xFFFFFFFF


def _rotl(x, n):
    x &= _MASK32
    return ((x << n) | (x >> (32 - n))) & _MASK32


def _p0(x):
    return x ^ _rotl(x, 9) ^ _rotl(x, 17)


def _p1(x):
    return x ^ _rotl(x, 15) ^ _rotl(x, 23)


def _compress(v, block):
    """One SM3 compression function round. `v` is the 8-word state tuple."""
    w = list(struct.unpack(">16I", block))

    for j in range(16, 68):
        t = w[j - 16] ^ w[j - 9] ^ _rotl(w[j - 3], 15)
        w.append(_p1(t) ^ _rotl(w[j - 13], 7) ^ w[j - 6])

    w1 = [w[j] ^ w[j + 4] for j in range(64)]

    a, b, c, d, e, f, g, h = v
    for j in range(64):
        a12 = _rotl(a, 12)
        ss1 = _rotl((a12 + e + _ROT_T[j]) & _MASK32, 7)
        ss2 = ss1 ^ a12

        if j < 16:
            tt1 = (a ^ b ^ c) + d + ss2 + w1[j]
            tt2 = (e ^ f ^ g) + h + ss1 + w[j]
        else:
            tt1 = ((a & b) | (a & c) | (b & c)) + d + ss2 + w1[j]
            tt2 = ((e & f) | ((~e & _MASK32) & g)) + h + ss1 + w[j]

        tt1 &= _MASK32
        d = c
        c = _rotl(b, 9)
        b = a
        a = tt1
        h = g
        g = _rotl(f, 19)
        f = e
        e = _p0(tt2 & _MASK32)

    return (
        a ^ v[0], b ^ v[1], c ^ v[2], d ^ v[3],
        e ^ v[4], f ^ v[5], g ^ v[6], h ^ v[7],
    )


class SM3(object):
    """Incremental SM3 hash object."""

    block_size = BLOCK_SIZE
    digest_size = DIGEST_SIZE
    name = "sm3"

    def __init__(self, data=b""):
        self._state = _IV
        self._buf = b""
        self._length = 0  # message length in bytes
        if data:
            self.update(data)

    def update(self, data):
        if isinstance(data, str):
            raise TypeError("SM3.update() requires bytes, not str")
        data = bytes(data)
        self._length += len(data)
        buf = self._buf + data
        n = len(buf) - (len(buf) % BLOCK_SIZE)
        state = self._state
        for i in range(0, n, BLOCK_SIZE):
            state = _compress(state, buf[i:i + BLOCK_SIZE])
        self._state = state
        self._buf = buf[n:]
        return self

    def _final_state(self):
        # padding: 0x80, zeros to 56 mod 64, then 8-byte big-endian bit count
        bit_len = (self._length * 8) & 0xFFFFFFFFFFFFFFFF
        tail = self._buf + b"\x80"
        pad = (56 - len(tail)) % BLOCK_SIZE
        tail += b"\x00" * pad + struct.pack(">Q", bit_len)
        state = self._state
        for i in range(0, len(tail), BLOCK_SIZE):
            state = _compress(state, tail[i:i + BLOCK_SIZE])
        return state

    def digest(self):
        return struct.pack(">8I", *self._final_state())

    def hexdigest(self):
        return self.digest().hex()

    def copy(self):
        c = SM3()
        c._state = self._state
        c._buf = self._buf
        c._length = self._length
        return c


def sm3(data):
    """Return the 32-byte SM3 digest of `data`."""
    return SM3(data).digest()


# ---------------------------------------------------------------------------
# Fast path: use hashlib's sm3 (OpenSSL) when it provably agrees with the code
# above. Verified against both official test vectors plus a set of lengths that
# exercise padding, multi-block and incremental-update boundaries.
# ---------------------------------------------------------------------------

def _hashlib_agrees():
    try:
        hashlib.new("sm3")
    except Exception:
        return False
    probes = [
        b"", b"a", b"abc", b"\x00" * 55, b"\x00" * 56, b"\x00" * 57,
        b"\x00" * 63, b"\x00" * 64, b"\x00" * 65, b"abcd" * 16,
        b"x" * 1000, bytes(range(256)) * 3,
    ]
    for m in probes:
        if hashlib.new("sm3", m).digest() != sm3(m):
            return False
    # incremental equivalence
    inc = SM3()
    for m in probes:
        inc.update(m)
    hl = hashlib.new("sm3")
    for m in probes:
        hl.update(m)
    return inc.digest() == hl.digest()


HAS_HASHLIB_SM3 = _hashlib_agrees()

if HAS_HASHLIB_SM3:

    def sm3(data):  # noqa: F811 - intentional redefinition for the fast path
        """Return the 32-byte SM3 digest of `data` (hashlib/OpenSSL fast path)."""
        return hashlib.new("sm3", data).digest()

    class SM3(object):  # noqa: F811 - intentional redefinition for the fast path
        """Incremental SM3 hash object (hashlib/OpenSSL fast path)."""

        block_size = BLOCK_SIZE
        digest_size = DIGEST_SIZE
        name = "sm3"

        def __init__(self, data=b""):
            if isinstance(data, str):
                raise TypeError("SM3.update() requires bytes, not str")
            self._h = hashlib.new("sm3", data)

        def update(self, data):
            if isinstance(data, str):
                raise TypeError("SM3.update() requires bytes, not str")
            self._h.update(data)
            return self

        def digest(self):
            return self._h.digest()

        def hexdigest(self):
            return self._h.hexdigest()

        def copy(self):
            c = SM3()
            c._h = self._h.copy()
            return c
