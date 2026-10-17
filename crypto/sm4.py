"""SM4 block cipher (GM/T 0002-2012) plus SM4-GCM, pure Python 3 stdlib.

Public API:
    SM4(key)                        # 16-byte key; .encrypt_block/.decrypt_block
    sm4_gcm_encrypt(key, nonce12, plaintext, aad=b'') -> (ciphertext, tag16)
    sm4_gcm_decrypt(key, nonce12, ciphertext, tag16, aad=b'') -> plaintext

GCM is the standard NIST SP 800-38D construction with SM4 substituted for AES:
128-bit tag, GHASH over GF(2^128), 96-bit nonce with a 32-bit counter.
"""

import struct

__all__ = ["SM4", "sm4_gcm_encrypt", "sm4_gcm_decrypt", "BLOCK_SIZE", "KEY_SIZE"]

BLOCK_SIZE = 16
KEY_SIZE = 16
_TAG_LEN = 16

# GM/T 0002-2012 S-box, 16 bytes per line.
_SBOX = bytes.fromhex(
    "d690e9fecce13db716b614c228fb2c05"
    "2b679a762abe04c3aa44132649860699"
    "9c4250f491ef987a33540b43edcfac62"
    "e4b31ca9c908e89580df94fa758f3fa6"
    "4707a7fcf37317ba83593c19e6854fa8"
    "686b81b27164da8bf8eb0f4b70569d35"
    "1e240e5e6358d1a225227c3b01217887"
    "d40046579fd327524c3602e7a0c4c89e"
    "eabf8ad240c738b5a3f7f2cef96115a1"
    "e0ae5da49b341a55ad933230f58cb1e3"
    "1df6e22e8266ca60c02923ab0d534e6f"
    "d5db3745defd8e2f03ff6a726d6c5b51"
    "8d1baf92bbddbc7f11d95c411f105ad8"
    "0ac13188a5cd7bbd2d74d012b8e5b4b0"
    "8969974a0c96777e65b9f109c56ec684"
    "18f07dec3adc4d2079ee5f3ed7cb3948"
)
assert len(_SBOX) == 256

_FK = (0xA3B1BAC6, 0x56AA3350, 0x677D9197, 0xB27022DC)

# CK[i] = bytes ((4i + j) * 7 mod 256) for j = 0..3, big-endian word
_CK = tuple(
    int.from_bytes(bytes(((4 * i + j) * 7) & 0xFF for j in range(4)), "big")
    for i in range(32)
)

_MASK32 = 0xFFFFFFFF


def _rotl(x, n):
    return ((x << n) | (x >> (32 - n))) & _MASK32


def _tau(word):
    return int.from_bytes(
        bytes((
            _SBOX[(word >> 24) & 0xFF],
            _SBOX[(word >> 16) & 0xFF],
            _SBOX[(word >> 8) & 0xFF],
            _SBOX[word & 0xFF],
        )),
        "big",
    )


class SM4(object):
    """SM4 block cipher with a 16-byte key."""

    block_size = BLOCK_SIZE
    key_size = KEY_SIZE

    def __init__(self, key):
        key = bytes(key)
        if len(key) != KEY_SIZE:
            raise ValueError("SM4 key must be exactly 16 bytes")
        self._rk = self._expand(key)

    @staticmethod
    def _expand(key):
        mk = struct.unpack(">4I", key)
        k = [mk[i] ^ _FK[i] for i in range(4)]
        rk = []
        for i in range(32):
            t = k[i + 1] ^ k[i + 2] ^ k[i + 3] ^ _CK[i]
            b = _tau(t)
            b ^= _rotl(b, 13) ^ _rotl(b, 23)
            k.append((k[i] ^ b) & _MASK32)
            rk.append(k[i + 4])
        return rk

    def encrypt_block(self, block):
        block = bytes(block)
        if len(block) != BLOCK_SIZE:
            raise ValueError("SM4 block must be exactly 16 bytes")
        rk = self._rk
        x = list(struct.unpack(">4I", block))
        for i in range(32):
            t = x[i + 1] ^ x[i + 2] ^ x[i + 3] ^ rk[i]
            b = _tau(t)
            x.append(
                x[i]
                ^ b
                ^ _rotl(b, 2)
                ^ _rotl(b, 10)
                ^ _rotl(b, 18)
                ^ _rotl(b, 24)
            )
        return struct.pack(">4I", x[35], x[34], x[33], x[32])

    def decrypt_block(self, block):
        # Decryption is encryption with the round keys reversed.
        block = bytes(block)
        if len(block) != BLOCK_SIZE:
            raise ValueError("SM4 block must be exactly 16 bytes")
        rk = self._rk[::-1]
        x = list(struct.unpack(">4I", block))
        for i in range(32):
            t = x[i + 1] ^ x[i + 2] ^ x[i + 3] ^ rk[i]
            b = _tau(t)
            x.append(
                x[i]
                ^ b
                ^ _rotl(b, 2)
                ^ _rotl(b, 10)
                ^ _rotl(b, 18)
                ^ _rotl(b, 24)
            )
        return struct.pack(">4I", x[35], x[34], x[33], x[32])


# ---------------------------------------------------------------------------
# GCM (SP 800-38D) over SM4
# ---------------------------------------------------------------------------

_R = 0xE1000000000000000000000000000000  # reduction polynomial reflected


def _bswap_words(b):
    return struct.unpack(">4I", b)


def _xor_bytes(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


class _GHash(object):
    """GHASH over GF(2^128) with the GCM bit-reflected convention."""

    __slots__ = ("h0", "h1")

    def __init__(self, h_bytes):
        h = int.from_bytes(h_bytes, "big")
        self.h0 = h >> 64
        self.h1 = h & 0xFFFFFFFFFFFFFFFF

    def _mul(self, y0, y1):
        """Multiply accumulator (y0,y1) by H in GF(2^128)."""
        x0, x1 = self.h0, self.h1
        z0 = z1 = 0
        # 128 iterations, bit by bit (bits of Y from MSB of y0 down to LSB of y1)
        for i in range(64):
            if (y0 >> (63 - i)) & 1:
                z0 ^= x0
                z1 ^= x1
            lsb = x1 & 1
            x1 = (x1 >> 1) | (x0 << 63)
            x0 = x0 >> 1
            if lsb:
                x0 ^= _R
            x0 &= 0xFFFFFFFFFFFFFFFF
            x1 &= 0xFFFFFFFFFFFFFFFF
        for i in range(64):
            if (y1 >> (63 - i)) & 1:
                z0 ^= x0
                z1 ^= x1
            lsb = x1 & 1
            x1 = (x1 >> 1) | (x0 << 63)
            x0 = x0 >> 1
            if lsb:
                x0 ^= _R
            x0 &= 0xFFFFFFFFFFFFFFFF
            x1 &= 0xFFFFFFFFFFFFFFFF
        return z0, z1

    def update(self, acc, block):
        b0 = int.from_bytes(block[:8], "big")
        b1 = int.from_bytes(block[8:], "big")
        y0 = acc[0] ^ b0
        y1 = acc[1] ^ b1
        return self._mul(y0, y1)

    def finish(self, acc, aad_len, ct_len):
        last = struct.pack(">QQ", aad_len * 8, ct_len * 8)
        b0 = int.from_bytes(last[:8], "big")
        b1 = int.from_bytes(last[8:], "big")
        acc = self._mul(acc[0] ^ b0, acc[1] ^ b1)
        return acc[0].to_bytes(8, "big") + acc[1].to_bytes(8, "big")


def _pad16(b):
    r = len(b) % 16
    return b + b"\x00" * (16 - r) if r else b


def _ghash_all(h, aad, ct):
    acc = (0, 0)
    data = _pad16(aad) + _pad16(ct)
    for i in range(0, len(data), 16):
        acc = h.update(acc, data[i:i + 16])
    return h.finish(acc, len(aad), len(ct))


def _ctr(cipher, nonce12, data, start_counter=2):
    """GCTR over `data`; keystream blocks are E(nonce || counter)."""
    if not data:
        return b""
    out = bytearray()
    counter = start_counter
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        ks = cipher.encrypt_block(nonce12 + struct.pack(">I", counter))
        out += _xor_bytes(chunk, ks[:len(chunk)])
        counter = (counter + 1) & 0xFFFFFFFF
    return bytes(out)


def sm4_gcm_encrypt(key, nonce12, plaintext, aad=b""):
    """Encrypt with SM4-GCM. Returns (ciphertext, tag) with a 16-byte tag."""
    nonce12 = bytes(nonce12)
    if len(nonce12) != 12:
        raise ValueError("SM4-GCM nonce must be exactly 12 bytes")
    plaintext = bytes(plaintext)
    aad = bytes(aad)
    cipher = SM4(key)
    h = _GHash(cipher.encrypt_block(b"\x00" * 16))
    ct = _ctr(cipher, nonce12, plaintext)
    s = _ghash_all(h, aad, ct)
    j0 = cipher.encrypt_block(nonce12 + b"\x00\x00\x00\x01")
    return ct, _xor_bytes(s, j0)


def sm4_gcm_decrypt(key, nonce12, ciphertext, tag16, aad=b""):
    """Decrypt with SM4-GCM. Raises ValueError if authentication fails."""
    nonce12 = bytes(nonce12)
    if len(nonce12) != 12:
        raise ValueError("SM4-GCM nonce must be exactly 12 bytes")
    tag16 = bytes(tag16)
    if len(tag16) != _TAG_LEN:
        raise ValueError("SM4-GCM tag must be exactly 16 bytes")
    ciphertext = bytes(ciphertext)
    aad = bytes(aad)
    cipher = SM4(key)
    h = _GHash(cipher.encrypt_block(b"\x00" * 16))
    expected = _ghash_all(h, aad, ciphertext)
    j0 = cipher.encrypt_block(nonce12 + b"\x00\x00\x00\x01")
    if not _const_eq(_xor_bytes(expected, j0), tag16):
        raise ValueError("SM4-GCM authentication failed")
    return _ctr(cipher, nonce12, ciphertext)


def _const_eq(a, b):
    if len(a) != len(b):
        return False
    diff = 0
    for x, y in zip(a, b):
        diff |= x ^ y
    return diff == 0
