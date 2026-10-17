"""Sovereign-echo sealed envelope: SM2-ECIES + SM4-GCM + SM2 signature.

Armored text form:

    -----BEGIN SOVEREIGN-ECHO SEALED NOTICE-----
    Format: sovereign-echo/sm-envelope/v1
    Kem: SM2-ECIES(SM3-KDF,SM4-GCM)
    Cipher: SM4-GCM
    Digest: SM3
    Signature: SM2-SM3
    KeyId: <16 lowercase hex chars>
    Created: <UTC ISO8601>
    Request: <64 lowercase hex chars>      # line omitted when unbound

    <base64 of the TLV body, wrapped at 64 columns>

    -----END SOVEREIGN-ECHO SEALED NOTICE-----

Binary body = TLV records `type(1) || length(2, big-endian) || value`:
    0x01 ephemeral point (33B)        0x02 CEK-wrap nonce (12B)
    0x03 wrapped CEK || tag (32B)     0x04 payload nonce (12B)
    0x05 payload ciphertext || tag    0x06 DER signature

Every stored header field is authenticated: the AAD fed to both GCM
operations and the bytes covered by the signature are derived from them, so
tampering with any header breaks both.

The signature covers the TLV records exactly as they arrived on the wire
(`aad || body[:signature_tlv_start]`), never a re-serialization, so a sealed
envelope has one canonical byte string: permuting TLV records breaks it.
"""

import base64
import datetime
import os
import re

try:
    from .sm2 import (PrivateKey, PublicKey, ecies_decrypt, ecies_encrypt,
                      keyid, sign, verify as _sm2_verify)
    from .sm3 import sm3
    from .sm4 import sm4_gcm_decrypt, sm4_gcm_encrypt
except ImportError:
    from sm2 import (PrivateKey, PublicKey, ecies_decrypt, ecies_encrypt,
                     keyid, sign, verify as _sm2_verify)
    from sm3 import sm3
    from sm4 import sm4_gcm_decrypt, sm4_gcm_encrypt

__all__ = [
    "Envelope", "EnvelopeError", "seal", "parse", "verify", "open",
    "BEGIN_MARKER", "END_MARKER",
]

EXIT_USAGE = 2
EXIT_BAD_SIGNATURE = 3
EXIT_DECRYPT_FAILED = 4
EXIT_MALFORMED = 5

BEGIN_MARKER = "-----BEGIN SOVEREIGN-ECHO SEALED NOTICE-----"
END_MARKER = "-----END SOVEREIGN-ECHO SEALED NOTICE-----"

_MAGIC = "SOVEREIGN-ECHO-SM-ENVELOPE-V1\n"

_HEADERS = ("Format", "Kem", "Cipher", "Digest", "Signature", "KeyId", "Created", "Request")
_FIXED_HEADERS = {
    "Format": "sovereign-echo/sm-envelope/v1",
    "Kem": "SM2-ECIES(SM3-KDF,SM4-GCM)",
    "Cipher": "SM4-GCM",
    "Digest": "SM3",
    "Signature": "SM2-SM3",
}

_TLV_EPHEMERAL = 0x01
_TLV_CEK_NONCE = 0x02
_TLV_CEK = 0x03
_TLV_PAYLOAD_NONCE = 0x04
_TLV_PAYLOAD = 0x05
_TLV_SIGNATURE = 0x06

_KEYID_RE = re.compile(r"\A[0-9a-f]{16}\Z")
_REQUEST_RE = re.compile(r"\A[0-9a-f]{64}\Z")
_CREATED_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")
_HEADER_RE = re.compile(r"\A([A-Za-z][A-Za-z-]*): ?(.*)\Z")


class EnvelopeError(Exception):
    """Malformed, unauthentic or undecryptable envelope.

    `code` is the process exit code a CLI should use: EXIT_MALFORMED (5) by
    default, EXIT_BAD_SIGNATURE (3) or EXIT_DECRYPT_FAILED (4) when known.
    Error messages never contain plaintext.
    """

    def __init__(self, message, code=EXIT_MALFORMED):
        super(EnvelopeError, self).__init__(message)
        self.code = code


def _aad(fields):
    """Additional authenticated data binding every header field."""
    return (
        _MAGIC
        + "\n".join("%s:%s" % (k, fields[k]) for k in _HEADERS)
    ).encode("utf-8")


def _tlv(t, value):
    if len(value) > 0xFFFF:
        raise EnvelopeError("envelope field too large")
    return bytes([t]) + len(value).to_bytes(2, "big") + bytes(value)


def _parse_tlvs(body):
    """Split `body` into TLV records. Returns (fields, signature_tlv_start)."""
    fields = {}
    sig_start = None
    i = 0
    while i < len(body):
        if i + 3 > len(body):
            raise EnvelopeError("truncated TLV record")
        t = body[i]
        start = i
        length = int.from_bytes(body[i + 1:i + 3], "big")
        i += 3
        if i + length > len(body):
            raise EnvelopeError("truncated TLV value")
        if t in fields or t not in (1, 2, 3, 4, 5, 6):
            raise EnvelopeError("unexpected TLV record 0x%02x" % t)
        if t == _TLV_SIGNATURE:
            sig_start = start
        fields[t] = body[i:i + length]
        i += length
    for t in (_TLV_EPHEMERAL, _TLV_CEK_NONCE, _TLV_CEK,
              _TLV_PAYLOAD_NONCE, _TLV_PAYLOAD, _TLV_SIGNATURE):
        if t not in fields:
            raise EnvelopeError("missing TLV record 0x%02x" % t)
    return fields, sig_start


class Envelope(object):
    """A parsed sealed envelope."""

    __slots__ = ("headers", "keyid", "created", "request",
                 "ephemeral", "cek_nonce", "wrapped_cek",
                 "payload_nonce", "payload", "signature", "signed_prefix")

    def __init__(self, headers, tlvs, signed_prefix=b""):
        self.headers = headers
        self.keyid = headers["KeyId"]
        self.created = headers["Created"]
        req = headers.get("Request")
        self.request = req if req != "-" else None
        self.ephemeral = tlvs[_TLV_EPHEMERAL]
        self.cek_nonce = tlvs[_TLV_CEK_NONCE]
        self.wrapped_cek = tlvs[_TLV_CEK]
        self.payload_nonce = tlvs[_TLV_PAYLOAD_NONCE]
        self.payload = tlvs[_TLV_PAYLOAD]
        self.signature = tlvs[_TLV_SIGNATURE]
        self.signed_prefix = signed_prefix

    def aad(self):
        fields = dict(self.headers)
        fields["Request"] = self.request if self.request else "-"
        return _aad(fields)

    def signed_bytes(self):
        """The bytes covered by the signature: AAD plus the received TLVs 1..5.

        `signed_prefix` is the decoded body up to (not including) the signature
        TLV, i.e. the records as they arrived on the wire rather than a
        canonical re-serialization, so TLV order is authenticated too.
        """
        return self.aad() + self.signed_prefix

    def __repr__(self):
        return "<Envelope keyid=%s created=%s request=%s>" % (
            self.keyid, self.created, self.request or "-")


def _as_request(request):
    if request is None:
        return None
    return request.encode("utf-8") if isinstance(request, str) else bytes(request)


def _format_created(now):
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")


def seal(plaintext, priv, request=None, now=None):
    """Seal `plaintext` to the holder of `priv`. Returns the armored envelope."""
    if not isinstance(priv, PrivateKey):
        raise TypeError("priv must be an sm2.PrivateKey")
    plaintext = bytes(plaintext)
    request = _as_request(request)
    pub = priv.public_key()

    fields = dict(_FIXED_HEADERS)
    fields["KeyId"] = keyid(pub)
    fields["Created"] = _format_created(now)
    fields["Request"] = sm3(request).hex() if request is not None else "-"
    aad = _aad(fields)

    cek = os.urandom(16)
    eph, cek_nonce, wrapped_cek, cek_tag = ecies_encrypt(pub, cek)
    payload_nonce = os.urandom(12)
    payload, payload_tag = sm4_gcm_encrypt(cek, payload_nonce, plaintext, aad=aad)

    body = b"".join((
        _tlv(_TLV_EPHEMERAL, eph),
        _tlv(_TLV_CEK_NONCE, cek_nonce),
        _tlv(_TLV_CEK, wrapped_cek + cek_tag),
        _tlv(_TLV_PAYLOAD_NONCE, payload_nonce),
        _tlv(_TLV_PAYLOAD, payload + payload_tag),
    ))
    signature = sign(priv, aad + body)
    body += _tlv(_TLV_SIGNATURE, signature)

    b64 = base64.b64encode(body).decode("ascii")
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    header_lines = ["%s: %s" % (k, fields[k]) for k in _HEADERS if k != "Request"]
    if request is not None:
        header_lines.append("Request: %s" % fields["Request"])
    return (
        BEGIN_MARKER + "\n"
        + "\n".join(header_lines) + "\n"
        + "\n"
        + "\n".join(lines) + "\n"
        + "\n"
        + END_MARKER + "\n"
    )


def _extract_armored(text):
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    start = text.find(BEGIN_MARKER)
    if start < 0:
        raise EnvelopeError("no sealed-notice envelope found in input")
    end = text.find(END_MARKER, start)
    if end < 0:
        raise EnvelopeError("unterminated sealed notice")
    return text[start:end + len(END_MARKER)]


def parse(text):
    """Extract and parse an armored envelope. Raises EnvelopeError if malformed."""
    block = _extract_armored(text)
    lines = [line.rstrip("\r") for line in block.split("\n")]
    while lines and lines[-1].strip() == "":
        lines.pop()
    if len(lines) < 3 or lines[0].strip() != BEGIN_MARKER:
        raise EnvelopeError("malformed envelope header")
    if lines[-1].strip() != END_MARKER:
        raise EnvelopeError("malformed envelope footer")

    headers = {}
    for i in range(1, len(lines) - 1):
        line = lines[i]
        if line.strip() == "":
            break
        m = _HEADER_RE.match(line)
        if not m:
            raise EnvelopeError("malformed header line")
        name, value = m.group(1), m.group(2)
        if name in headers or name not in _HEADERS:
            raise EnvelopeError("unexpected header %r" % name)
        headers[name] = value
    else:
        raise EnvelopeError("envelope body missing")

    # Header values are authenticated by the signature (they are part of the
    # AAD), so only their presence and shape are checked here: a tampered
    # value surfaces as a signature failure rather than a parse failure.
    for name in _FIXED_HEADERS:
        if name not in headers:
            raise EnvelopeError("missing header %r" % name)
    if "KeyId" not in headers or not _KEYID_RE.match(headers["KeyId"]):
        raise EnvelopeError("malformed KeyId")
    if "Created" not in headers or not _CREATED_RE.match(headers["Created"]):
        raise EnvelopeError("malformed Created")
    request = headers.get("Request")
    if request is not None and not _REQUEST_RE.match(request):
        raise EnvelopeError("malformed Request")

    try:
        body = base64.b64decode("".join(lines[i + 1:-1]), validate=True)
    except Exception:
        raise EnvelopeError("envelope body is not valid base64")

    tlvs, sig_start = _parse_tlvs(body)
    if len(tlvs[_TLV_EPHEMERAL]) != 33:
        raise EnvelopeError("malformed ephemeral point")
    if len(tlvs[_TLV_CEK_NONCE]) != 12 or len(tlvs[_TLV_PAYLOAD_NONCE]) != 12:
        raise EnvelopeError("malformed nonce")
    if len(tlvs[_TLV_CEK]) != 32:
        raise EnvelopeError("malformed wrapped key")
    if len(tlvs[_TLV_PAYLOAD]) < 16:
        raise EnvelopeError("malformed payload")
    return Envelope(headers, tlvs, body[:sig_start])


def verify(env, pub):
    """Verify the envelope's SM2 signature against `pub`."""
    if not isinstance(env, Envelope):
        raise TypeError("env must be an Envelope")
    if not isinstance(pub, PublicKey):
        raise TypeError("pub must be an sm2.PublicKey")
    try:
        return _sm2_verify(pub, env.signed_bytes(), env.signature)
    except Exception:
        return False


def open(env, priv, request=None):
    """Verify then decrypt. Raises EnvelopeError on any failure.

    If `request` is given, the envelope's stored Request field must match
    sm3(request). The signature is always checked before any decryption.
    """
    if not isinstance(env, Envelope):
        raise TypeError("env must be an Envelope")
    if not isinstance(priv, PrivateKey):
        raise TypeError("priv must be an sm2.PrivateKey")
    request = _as_request(request)

    if not verify(env, priv.public_key()):
        raise EnvelopeError("signature verification failed", EXIT_BAD_SIGNATURE)

    if request is not None and env.request != sm3(request).hex():
        raise EnvelopeError("request binding mismatch", EXIT_BAD_SIGNATURE)

    aad = env.aad()
    try:
        cek = ecies_decrypt(
            priv, env.ephemeral, env.cek_nonce,
            env.wrapped_cek[:16], env.wrapped_cek[16:32],
        )
    except Exception:
        raise EnvelopeError("could not unwrap the content key", EXIT_DECRYPT_FAILED)
    try:
        return sm4_gcm_decrypt(
            cek, env.payload_nonce,
            env.payload[:-16], env.payload[-16:], aad=aad,
        )
    except Exception:
        raise EnvelopeError("decryption failed", EXIT_DECRYPT_FAILED)
