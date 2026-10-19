"""SM2 elliptic-curve cryptography (GM/T 0003), pure Python 3 stdlib.

Provides key handling (SEC1 / X.509 PEM), SM2 digital signatures (with the
GM/T 0003.5 Z-digest) and SM2-ECIES (SM3-KDF + SM4-GCM) key wrapping.

Scalar multiplication uses Jacobian coordinates with a 4-bit window; the
generator's window table is built lazily once at module scope.
"""

import base64
import os
import struct
from collections import namedtuple

try:  # package-relative import when crypto/ is imported as a namespace package
    from .sm3 import sm3
    from .sm4 import sm4_gcm_decrypt, sm4_gcm_encrypt
except ImportError:  # direct import with crypto/ on sys.path
    from sm3 import sm3
    from sm4 import sm4_gcm_decrypt, sm4_gcm_encrypt

__all__ = [
    "CURVE", "PrivateKey", "PublicKey",
    "private_key_to_pem", "public_key_to_pem",
    "load_private_pem", "load_public_pem",
    "sign", "verify",
    "ecies_encrypt", "ecies_decrypt", "keyid",
    "PEMFormatError",
]

CURVE = namedtuple("Curve", "p a b Gx Gy n")(
    p=0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF,
    a=0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFC,
    b=0x28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93,
    Gx=0x32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7,
    Gy=0xBC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0,
    n=0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123,
)

P = CURVE.p
A = CURVE.a
B = CURVE.b
N = CURVE.n
G = (CURVE.Gx, CURVE.Gy)

# GM/T 0003.5 default user identity.
#
# Note on OpenSSL interop: `openssl dgst -sm3 -sign/-verify` (verified against
# OpenSSL 3.6.4) does apply the SM2 Z-digest, but it uses an EMPTY user
# identity (ENTL = 0x0000, ID = b""), not this GM/T default. Pass
# ident=b"" to sign()/verify() for signatures that interoperate with OpenSSL.
DEFAULT_ID = b"1234567812345678"
OPENSSL_ID = b""

_OID_EC_PUBLIC_KEY = bytes.fromhex("2A8648CE3D0201")       # 1.2.840.10045.2.1
_OID_SM2_CURVE = bytes.fromhex("2A811CCF5501822D")         # 1.2.156.10197.1.301

# Named curves we are most likely to be handed by mistake, so a rejection
# can name the curve it refused instead of showing a bare OID.
_OID_NAMED_CURVES = {
    bytes.fromhex("2A8648CE3D030107"): "prime256v1",       # 1.2.840.10045.3.1.7
    bytes.fromhex("2B8104000A"): "secp256k1",              # 1.3.132.0.10
    bytes.fromhex("2B81040022"): "secp384r1",              # 1.3.132.0.34
    bytes.fromhex("2B81040023"): "secp521r1",              # 1.3.132.0.35
}


class PEMFormatError(ValueError):
    """Raised when a PEM/DER structure cannot be parsed."""


def _reject_foreign_curve(oid, where):
    """Fail closed on any named curve that is not SM2.

    A foreign-curve EC key can carry the very same id-ecPublicKey algorithm
    OID as an SM2 key; running SM2 arithmetic on its scalar would silently
    produce wrong-domain points, so reject it at import time.
    """
    if oid == _OID_SM2_CURVE:
        return
    name = _OID_NAMED_CURVES.get(oid)
    label = " (%s)" % name if name else ""
    raise PEMFormatError(
        "%s names curve %s%s — not the SM2 curve (1.2.156.10197.1.301); "
        "refusing to run SM2 arithmetic on a foreign-curve key"
        % (where, oid.hex(), label))


# ---------------------------------------------------------------------------
# Field / curve arithmetic (Jacobian coordinates: x = X/Z^2, y = Y/Z^3)
# ---------------------------------------------------------------------------

def _is_on_curve(pt):
    x, y = pt
    return (y * y - (x * x * x + A * x + B)) % P == 0


def _jac_double(pt):
    x1, y1, z1 = pt
    if y1 == 0 or z1 == 0:
        return (1, 1, 0)
    yy = (y1 * y1) % P
    s = (4 * x1 * yy) % P
    zz = (z1 * z1) % P
    m = (3 * x1 * x1 + A * zz * zz) % P
    x3 = (m * m - 2 * s) % P
    y3 = (m * (s - x3) - 8 * yy * yy) % P
    z3 = (2 * y1 * z1) % P
    return (x3, y3, z3)


def _jac_add(p1, p2):
    x1, y1, z1 = p1
    x2, y2, z2 = p2
    if z1 == 0:
        return p2
    if z2 == 0:
        return p1
    z1z1 = (z1 * z1) % P
    z2z2 = (z2 * z2) % P
    u1 = (x1 * z2z2) % P
    u2 = (x2 * z1z1) % P
    s1 = (y1 * z2z2 * z2) % P
    s2 = (y2 * z1z1 * z1) % P
    if u1 == u2:
        if s1 != s2:
            return (1, 1, 0)
        return _jac_double(p1)
    h = (u2 - u1) % P
    r = (s2 - s1) % P
    hh = (h * h) % P
    hhh = (hh * h) % P
    u1hh = (u1 * hh) % P
    x3 = (r * r - hhh - 2 * u1hh) % P
    y3 = (r * (u1hh - x3) - s1 * hhh) % P
    z3 = (h * z1 * z2) % P
    return (x3, y3, z3)


def _to_affine(pt):
    x, y, z = pt
    if z == 0:
        return None
    zinv = pow(z, P - 2, P)
    zinv2 = (zinv * zinv) % P
    return ((x * zinv2) % P, (y * zinv2 % P) * zinv % P)


def _jac_table(pt_affine):
    """Window table [1P .. 15P] in Jacobian coordinates."""
    base = (pt_affine[0], pt_affine[1], 1)
    tbl = [None, base]
    for i in range(2, 16):
        tbl.append(_jac_add(tbl[i - 1], base))
    return tbl


def _mul_window(pt_affine, k, table=None):
    """Scalar multiplication k*P using a 4-bit window, Jacobian coordinates."""
    k %= N
    if k == 0:
        return None
    if table is None:
        table = _jac_table(pt_affine)
    acc = None
    for i in range(63, -1, -1):
        nib = (k >> (4 * i)) & 0xF
        if acc is not None:
            acc = _jac_double(acc)
            acc = _jac_double(acc)
            acc = _jac_double(acc)
            acc = _jac_double(acc)
        if nib:
            t = table[nib]
            acc = t if acc is None else _jac_add(acc, t)
    return _to_affine(acc)


_G_TABLE = None


def _g_table():
    global _G_TABLE
    if _G_TABLE is None:
        _G_TABLE = _jac_table(G)
    return _G_TABLE


def _mul_g(k):
    return _mul_window(G, k % N, _g_table())


def _rand_scalar():
    """Uniformly random scalar in [1, n-1] from os.urandom (rejection sampled)."""
    while True:
        c = int.from_bytes(os.urandom(32), "big")
        if 1 <= c < N:
            return c


# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

def _be32(v):
    return v.to_bytes(32, "big")


class PrivateKey(object):
    """An SM2 private key: the scalar `d`."""

    __slots__ = ("d",)

    def __init__(self, d):
        d = int(d)
        if not (1 <= d < N):
            raise ValueError("SM2 private key must be in [1, n-1]")
        self.d = d

    def public_key(self):
        return PublicKey.from_private(self.d)

    def __eq__(self, other):
        return isinstance(other, PrivateKey) and other.d == self.d

    def __hash__(self):
        return hash(("PrivateKey", self.d))

    def __repr__(self):
        return "PrivateKey(keyid=%s)" % keyid(self.public_key())


class PublicKey(object):
    """An SM2 public key: the affine point (x, y)."""

    __slots__ = ("x", "y")

    def __init__(self, x, y):
        x, y = int(x), int(y)
        if not (0 <= x < P and 0 <= y < P) or not _is_on_curve((x, y)):
            raise ValueError("point is not on the SM2 curve")
        self.x = x
        self.y = y

    @classmethod
    def from_private(cls, d):
        d = d.d if isinstance(d, PrivateKey) else int(d)
        if not (1 <= d < N):
            raise ValueError("SM2 private key must be in [1, n-1]")
        pt = _mul_g(d)
        if pt is None:
            raise ValueError("degenerate private key")
        return cls(pt[0], pt[1])

    def to_bytes(self):
        """Uncompressed SEC1 point encoding: 0x04 || X || Y (65 bytes)."""
        return b"\x04" + _be32(self.x) + _be32(self.y)

    @classmethod
    def from_bytes(cls, data):
        data = bytes(data)
        if len(data) == 65 and data[0] == 0x04:
            return cls(int.from_bytes(data[1:33], "big"),
                       int.from_bytes(data[33:65], "big"))
        if len(data) == 33 and data[0] in (0x02, 0x03):
            return cls(*_decompress(data))
        raise ValueError("unsupported point encoding")

    def __eq__(self, other):
        return (isinstance(other, PublicKey)
                and other.x == self.x and other.y == self.y)

    def __hash__(self):
        return hash(("PublicKey", self.x, self.y))

    def __repr__(self):
        return "PublicKey(keyid=%s)" % keyid(self)


def _decompress(data):
    """Compressed point (33 bytes) -> affine (x, y). p = 3 (mod 4)."""
    if len(data) != 33 or data[0] not in (0x02, 0x03):
        raise ValueError("not a compressed SM2 point")
    x = int.from_bytes(data[1:33], "big")
    if x >= P:
        raise ValueError("x coordinate out of range")
    alpha = (x * x * x + A * x + B) % P
    y = pow(alpha, (P + 1) // 4, P)
    if (y * y - alpha) % P != 0:
        raise ValueError("point is not on the curve")
    if (y & 1) != (data[0] & 1):
        y = (P - y) % P
    return x, y


def _compress(pt):
    return bytes([0x02 | (pt[1] & 1)]) + _be32(pt[0])


def keyid(pub):
    """16 lowercase hex chars: first 8 bytes of sm3(uncompressed point)."""
    return sm3(pub.to_bytes())[:8].hex()


# ---------------------------------------------------------------------------
# Minimal DER encoding / decoding
# ---------------------------------------------------------------------------

def _der_len(n):
    if n < 0x80:
        return bytes([n])
    body = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(body)]) + body


def _der(tag, content):
    return bytes([tag]) + _der_len(len(content)) + content


def _der_int(i):
    if i == 0:
        body = b"\x00"
    else:
        body = i.to_bytes((i.bit_length() + 7) // 8, "big")
        if body[0] & 0x80:
            body = b"\x00" + body
    return _der(0x02, body)


def _der_oid(content):
    return _der(0x06, content)


def _read_tlv(buf, i):
    if i + 2 > len(buf):
        raise PEMFormatError("truncated DER element")
    tag = buf[i]
    length = buf[i + 1]
    i += 2
    if length & 0x80:
        nb = length & 0x7F
        if nb == 0 or i + nb > len(buf):
            raise PEMFormatError("unsupported DER length")
        length = int.from_bytes(buf[i:i + nb], "big")
        i += nb
    if i + length > len(buf):
        raise PEMFormatError("truncated DER element")
    return tag, buf[i:i + length], i + length


def _der_items(content):
    """Split a DER SEQUENCE body into (tag, value) pairs."""
    out = []
    i = 0
    while i < len(content):
        tag, value, i = _read_tlv(content, i)
        out.append((tag, value))
    return out


def _pem(label, der):
    b64 = base64.b64encode(der).decode("ascii")
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (
        label, "\n".join(lines), label)


def _pem_blocks(text):
    """Yield (label, der) for each PEM block in `text`, in order.

    A file may carry more than one block: OpenSSL writes the curve parameters
    ahead of the key (e.g. `openssl ecparam -name SM2 -genkey`).
    """
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    pos = 0
    while True:
        start = text.find("-----BEGIN ", pos)
        if start < 0:
            return
        end = text.find("-----END ", start)
        if end < 0:
            raise PEMFormatError("no PEM footer found")
        nl = text.find("\n", start)
        if nl < 0 or nl > end:
            raise PEMFormatError("malformed PEM header")
        marker = text[start:nl].strip()
        if not marker.endswith("-----"):
            raise PEMFormatError("malformed PEM header")
        label = marker[len("-----BEGIN "):-len("-----")].strip()
        end_nl = text.find("\n", end)
        stop = end_nl if end_nl >= 0 else len(text)
        b64 = "".join(text[nl + 1:end].split())
        try:
            der = base64.b64decode(b64, validate=True)
        except Exception:
            raise PEMFormatError("invalid base64 in PEM body")
        yield label, der
        pos = stop


def _unpem(text, label):
    for header, der in _pem_blocks(text):
        if label is not None and header != label:
            raise PEMFormatError("expected %r PEM, got %r" % (label, header))
        return der
    raise PEMFormatError("no PEM header found")


# ---------------------------------------------------------------------------
# PEM import / export
# ---------------------------------------------------------------------------

def private_key_to_pem(d):
    """SEC1 ECPrivateKey (RFC 5915) with the SM2 named-curve OID."""
    priv = d.d if isinstance(d, PrivateKey) else int(d)
    if not (1 <= priv < N):
        raise ValueError("SM2 private key must be in [1, n-1]")
    pub = PublicKey.from_private(priv)
    body = (
        _der_int(1)
        + _der(0x04, priv.to_bytes(32, "big"))
        + _der(0xA0, _der_oid(_OID_SM2_CURVE))
        + _der(0xA1, _der(0x03, b"\x00" + pub.to_bytes()))
    )
    return _pem("EC PRIVATE KEY", _der(0x30, body))


def public_key_to_pem(pub):
    """X.509 SubjectPublicKeyInfo for an SM2 public key."""
    alg = _der(0x30, _der_oid(_OID_EC_PUBLIC_KEY) + _der_oid(_OID_SM2_CURVE))
    spki = _der(0x30, alg + _der(0x03, b"\x00" + pub.to_bytes()))
    return _pem("PUBLIC KEY", spki)


def _ec_private_from_der(content):
    items = _der_items(content)
    if len(items) < 2 or items[0][0] != 0x02 or items[1][0] != 0x04:
        raise PEMFormatError("malformed ECPrivateKey")
    if int.from_bytes(items[0][1], "big") != 1:
        raise PEMFormatError("unsupported ECPrivateKey version")
    # ECPrivateKey ::= SEQUENCE { version, privateKey,
    #                              parameters [0] ECParameters OPTIONAL, ... }
    if len(items) >= 3 and items[2][0] == 0xA0:
        tag, oid, _ = _read_tlv(items[2][1], 0)
        if tag != 0x06:
            raise PEMFormatError(
                "SEC1 EC parameters are explicit, not a named curve — only "
                "the SM2 curve (1.2.156.10197.1.301) is supported")
        _reject_foreign_curve(oid, "SEC1 key")
    return int.from_bytes(items[1][1], "big")


# SEC1 (RFC 5915) private key blocks: OpenSSL 3 names the SM2 variant
# "SM2 PRIVATE KEY", older releases and everything else use "EC PRIVATE KEY".
_PRIVATE_PEM_LABELS = ("EC PRIVATE KEY", "SM2 PRIVATE KEY", "PRIVATE KEY")


def _private_key_from_pkcs8(content):
    """PKCS#8 PrivateKeyInfo: SEQUENCE { version, algid, OCTET STRING key }."""
    items = _der_items(content)
    if len(items) < 3 or items[0][0] != 0x02 or items[1][0] != 0x30 \
            or items[2][0] != 0x04:
        raise PEMFormatError("malformed PKCS#8 PrivateKeyInfo")
    if int.from_bytes(items[0][1], "big") != 0:
        raise PEMFormatError("unsupported PKCS#8 version")
    alg = _der_items(items[1][1])
    if not alg or alg[0][0] != 0x06:
        raise PEMFormatError("PKCS#8 PrivateKeyInfo has no algorithm OID")
    if alg[0][1] not in (_OID_EC_PUBLIC_KEY, _OID_SM2_CURVE):
        raise PEMFormatError(
            "PKCS#8 key algorithm is not EC/SM2 (expected id-ecPublicKey "
            "1.2.840.10045.2.1 or SM2 1.2.156.10197.1.301)")
    # AlgorithmIdentifier parameters, when present, name the curve: anything
    # but SM2 there means the key is not an SM2 key.
    if len(alg) >= 2:
        if alg[1][0] != 0x06:
            raise PEMFormatError(
                "PKCS#8 EC parameters are explicit, not a named curve — only "
                "the SM2 curve (1.2.156.10197.1.301) is supported")
        _reject_foreign_curve(alg[1][1], "PKCS#8 key")
    tag, inner, _ = _read_tlv(items[2][1], 0)
    if tag != 0x30:
        raise PEMFormatError("malformed inner ECPrivateKey")
    return PrivateKey(_ec_private_from_der(inner))


def _assert_on_sm2_curve(priv):
    """Fail closed unless the key really belongs to the SM2 curve.

    Derives the public point and lets PublicKey validate it: a key whose
    scalar survives the [1, n-1] check but is not an SM2 scalar must not
    pass import silently.
    """
    try:
        priv.public_key()
    except ValueError as exc:
        raise PEMFormatError(
            "private key does not belong to the SM2 curve: %s" % exc)
    return priv


def load_private_pem(text):
    """Load a SEC1 'EC PRIVATE KEY' or an unencrypted PKCS#8 'PRIVATE KEY'.

    Both are what OpenSSL emits: `ecparam -name SM2 -genkey` writes PKCS#8
    (preceded by a parameters block, which is skipped here), `ec` writes SEC1.

    Fails closed on anything that is not an SM2 key: a non-EC/SM2 algorithm
    OID, a named curve other than SM2, a scalar outside [1, n-1], or a
    derived point that is not on the SM2 curve.
    """
    for label, der in _pem_blocks(text):
        if label == "ENCRYPTED PRIVATE KEY":
            raise PEMFormatError("encrypted private keys are not supported")
        if label not in _PRIVATE_PEM_LABELS:
            continue
        tag, content, _ = _read_tlv(der, 0)
        if tag != 0x30:
            raise PEMFormatError("expected a DER SEQUENCE")
        items = _der_items(content)
        if len(items) >= 2 and items[0][0] == 0x02 and items[1][0] == 0x30:
            return _assert_on_sm2_curve(_private_key_from_pkcs8(content))
        return _assert_on_sm2_curve(PrivateKey(_ec_private_from_der(content)))
    raise PEMFormatError(
        "no private key found: expected an 'EC PRIVATE KEY' or "
        "'PRIVATE KEY' PEM block")


def load_public_pem(text):
    """Load an X.509 SubjectPublicKeyInfo 'PUBLIC KEY'."""
    der = _unpem(text, None)
    tag, content, _ = _read_tlv(der, 0)
    if tag != 0x30:
        raise PEMFormatError("expected a DER SEQUENCE")
    items = _der_items(content)
    if len(items) < 2 or items[0][0] != 0x30 or items[1][0] != 0x03:
        raise PEMFormatError("malformed SubjectPublicKeyInfo")
    bits = items[1][1]
    if not bits or bits[0] != 0x00:
        raise PEMFormatError("unsupported BIT STRING padding")
    return PublicKey.from_bytes(bits[1:])


# ---------------------------------------------------------------------------
# Signatures (GM/T 0003.5)
# ---------------------------------------------------------------------------

def _z_digest(pub, ident=DEFAULT_ID):
    """Z = sm3(ENTL || ID || a || b || Gx || Gy || Px || Py)."""
    if len(ident) >= 0x2000:
        raise ValueError("user identity too long")
    return sm3(
        struct.pack(">H", len(ident) * 8)
        + ident
        + _be32(A) + _be32(B)
        + _be32(CURVE.Gx) + _be32(CURVE.Gy)
        + _be32(pub.x) + _be32(pub.y)
    )


def _digest_e(pub, msg, ident=DEFAULT_ID):
    return int.from_bytes(sm3(_z_digest(pub, ident) + bytes(msg)), "big")


def _encode_sig(r, s):
    return _der(0x30, _der_int(r) + _der_int(s))


def _decode_sig(sig_der):
    """Return (r, s) or None if the DER is malformed."""
    try:
        sig_der = bytes(sig_der)
        tag, content, end = _read_tlv(sig_der, 0)
        if tag != 0x30 or end != len(sig_der):
            return None
        items = _der_items(content)
        if len(items) != 2 or items[0][0] != 0x02 or items[1][0] != 0x02:
            return None
        vals = []
        for _, body in items:
            if not body:
                return None
            if body[0] & 0x80:
                return None  # negative
            if len(body) > 1 and body[0] == 0x00 and not (body[1] & 0x80):
                return None  # non-minimal
            vals.append(int.from_bytes(body, "big"))
        return vals[0], vals[1]
    except Exception:
        return None


def sign(priv, msg, ident=DEFAULT_ID, k=None):
    """SM2 signature over `msg` (Z-digest form). Returns DER `SEQUENCE{r,s}`."""
    d = priv.d if isinstance(priv, PrivateKey) else int(priv)
    pub = PublicKey.from_private(d)
    e = _digest_e(pub, msg, ident)
    msg = bytes(msg)
    while True:
        kk = _rand_scalar() if k is None else int(k)
        if k is not None and not (1 <= kk < N):
            raise ValueError("k must be in [1, n-1]")
        pt = _mul_g(kk)
        if pt is None:
            continue
        r = (e + pt[0]) % N
        if r == 0 or r + kk == N:
            if k is not None:
                raise ValueError("unsuitable k")
            continue
        s = (pow(1 + d, -1, N) * (kk - r * d)) % N
        if s == 0:
            if k is not None:
                raise ValueError("unsuitable k")
            continue
        return _encode_sig(r, s)


def verify(pub, msg, sig_der, ident=DEFAULT_ID):
    """Verify an SM2 signature (Z-digest form). Never raises; returns bool."""
    parsed = _decode_sig(sig_der)
    if parsed is None:
        return False
    r, s = parsed
    if not (1 <= r < N and 1 <= s < N):
        return False
    msg = bytes(msg)
    e = _digest_e(pub, msg, ident)
    t = (r + s) % N
    if t == 0:
        return False
    sg = _mul_g(s)
    tp = _mul_window((pub.x, pub.y), t)
    if sg is None or tp is None:
        return False
    pt = _jac_add((sg[0], sg[1], 1), (tp[0], tp[1], 1))
    aff = _to_affine(pt)
    if aff is None:
        return False
    return (e + aff[0]) % N == r


# ---------------------------------------------------------------------------
# ECIES: SM3-KDF key wrap + SM4-GCM
# ---------------------------------------------------------------------------

def _kdf(shared_x, counter=1):
    return sm3(_be32(shared_x) + counter.to_bytes(4, "big"))[:16]


def ecies_encrypt(pub, cek16, k=None):
    """Wrap a 16-byte CEK to `pub`.

    Returns (eph_compressed, nonce12, ciphertext, tag16).
    """
    cek16 = bytes(cek16)
    if len(cek16) != 16:
        raise ValueError("CEK must be exactly 16 bytes")
    kk = _rand_scalar() if k is None else int(k)
    c1 = _mul_g(kk)
    if c1 is None:
        raise ValueError("degenerate ephemeral key")
    shared = _mul_window((pub.x, pub.y), kk)
    if shared is None:
        raise ValueError("degenerate shared secret")
    kek = _kdf(shared[0])
    eph = _compress(c1)
    nonce = os.urandom(12)
    ct, tag = sm4_gcm_encrypt(kek, nonce, cek16, aad=eph)
    return eph, nonce, ct, tag


def ecies_decrypt(priv, eph_compressed, nonce12, ct, tag16):
    """Unwrap a CEK. Raises ValueError if authentication fails."""
    d = priv.d if isinstance(priv, PrivateKey) else int(priv)
    c1 = _decompress(bytes(eph_compressed))
    shared = _mul_window(c1, d)
    if shared is None:
        raise ValueError("degenerate shared secret")
    kek = _kdf(shared[0])
    return sm4_gcm_decrypt(kek, bytes(nonce12), bytes(ct), bytes(tag16),
                           aad=bytes(eph_compressed))
