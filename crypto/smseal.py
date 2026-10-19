#!/usr/bin/env python3
"""smseal -- seal and open sovereign-echo notices with 国密 (SM2/SM3/SM4).

    python3 crypto/smseal.py keygen   [--home DIR] [--force]
    python3 crypto/smseal.py seal     [--notice PATH] [--home DIR] [--hook] [--request TEXT]
    python3 crypto/smseal.py open     [--home DIR] [--in FILE] [--pubkey FILE] [--request TEXT]
    python3 crypto/smseal.py verify   [--home DIR] [--in FILE] [--pubkey FILE] [--request TEXT]
    python3 crypto/smseal.py pubkey   [--home DIR]

Exit codes: 0 ok · 2 usage · 3 signature failed · 4 decryption failed ·
5 envelope malformed.
"""

import argparse
import json
import os
import sys

try:
    from . import envelope as _envelope
    from . import sm2 as _sm2
    from . import sm3 as _sm3
except ImportError:
    _HERE = os.path.dirname(os.path.abspath(__file__))
    if _HERE not in sys.path:
        sys.path.insert(0, _HERE)
    import envelope as _envelope
    import sm2 as _sm2
    import sm3 as _sm3

EnvelopeError = _envelope.EnvelopeError
seal = _envelope.seal
parse = _envelope.parse
verify_envelope = _envelope.verify
open_envelope = _envelope.open
keyid = _sm2.keyid
PublicKey = _sm2.PublicKey
load_private_pem = _sm2.load_private_pem
load_public_pem = _sm2.load_public_pem
private_key_to_pem = _sm2.private_key_to_pem
public_key_to_pem = _sm2.public_key_to_pem

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_BAD_SIGNATURE = 3
EXIT_DECRYPT_FAILED = 4
EXIT_MALFORMED = 5

PROG = "smseal"


def _default_home():
    return os.environ.get("SOVEREIGN_ECHO_HOME") or os.path.join(
        os.path.expanduser("~"), ".sovereign-echo")


def _paths(home):
    keys = os.path.join(home, "keys")
    return {
        "home": home,
        "keys": keys,
        "priv": os.path.join(keys, "sm2-private.pem"),
        "pub": os.path.join(keys, "sm2-public.pem"),
    }


def _read_text(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def _write_public(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)


def _fail(message, code):
    sys.stderr.write("%s: %s\n" % (PROG, message))
    return code


class _CliError(Exception):
    """A usage/environment problem, not an envelope problem."""

    def __init__(self, message, code=EXIT_USAGE):
        super(_CliError, self).__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_keygen(args):
    p = _paths(args.home)
    if not args.force and os.path.exists(p["priv"]) and os.path.exists(p["pub"]):
        try:
            priv = load_private_pem(_read_text(p["priv"]))
        except Exception as exc:
            return _fail("existing private key is unreadable: %s" % exc, EXIT_USAGE)
        sys.stdout.write("%s\n" % keyid(priv.public_key()))
        return EXIT_OK

    try:
        os.makedirs(p["keys"], mode=0o700, exist_ok=True)
        os.chmod(p["keys"], 0o700)
    except OSError as exc:
        return _fail("cannot create %s: %s" % (p["keys"], exc), EXIT_USAGE)
    if not args.force and (os.path.exists(p["priv"]) or os.path.exists(p["pub"])):
        sys.stderr.write("%s: regenerating incomplete key pair in %s\n"
                         % (PROG, p["keys"]))

    d = _sm2._rand_scalar()
    pub = PublicKey.from_private(d)
    _write_private(p["priv"], private_key_to_pem(d))
    _write_public(p["pub"], public_key_to_pem(pub))
    sys.stdout.write("%s\n" % keyid(pub))
    return EXIT_OK


def cmd_pubkey(args):
    p = _paths(args.home)
    if not os.path.exists(p["pub"]):
        return _fail("no public key at %s (run: smseal.py keygen)" % p["pub"],
                     EXIT_USAGE)
    sys.stdout.write(_read_text(p["pub"]))
    return EXIT_OK


def _notice_text(args):
    if args.notice:
        if not os.path.exists(args.notice):
            raise _CliError("notice file not found: %s" % args.notice)
        return _read_text(args.notice).encode("utf-8")
    fallback = os.path.join(args.home, "declarations", "notice.compact.txt")
    if not os.path.exists(fallback):
        raise _CliError("no --notice given and %s does not exist" % fallback)
    return _read_text(fallback).encode("utf-8")


def _hook_request(args):
    """Determine the request-binding input for `--hook`."""
    if args.request is not None:
        return args.request.encode("utf-8")
    if not args.hook:
        return None
    try:
        raw = sys.stdin.read()
    except Exception:
        return None
    if not raw.strip():
        return None
    try:
        obj = json.loads(raw)
    except Exception:
        return None
    if isinstance(obj, dict):
        prompt = obj.get("prompt")
        if isinstance(prompt, str) and prompt != "":
            return prompt.encode("utf-8")
    return None


def cmd_seal(args):
    p = _paths(args.home)
    if not os.path.exists(p["priv"]):
        return _fail("no private key at %s (run: smseal.py keygen)" % p["priv"],
                     EXIT_USAGE)
    try:
        priv = load_private_pem(_read_text(p["priv"]))
    except Exception as exc:
        return _fail("cannot load private key %s: %s" % (p["priv"], exc),
                     EXIT_USAGE)
    try:
        plaintext = _notice_text(args)
    except _CliError as exc:
        return _fail(str(exc), EXIT_USAGE)
    request = _hook_request(args)
    sys.stdout.write(seal(plaintext, priv, request))
    return EXIT_OK


def _read_envelope(args):
    if args.infile:
        if not os.path.exists(args.infile):
            raise _CliError("input file not found: %s" % args.infile)
        return _read_text(args.infile)
    return sys.stdin.read()


def _load_pub(args):
    if args.pubkey:
        if not os.path.exists(args.pubkey):
            raise _CliError("public key file not found: %s" % args.pubkey)
        return load_public_pem(_read_text(args.pubkey))
    p = _paths(args.home)
    if not os.path.exists(p["pub"]):
        raise _CliError("no public key at %s (run: smseal.py keygen)" % p["pub"])
    return load_public_pem(_read_text(p["pub"]))


def _request_arg(args):
    return args.request.encode("utf-8") if args.request is not None else None


def _describe(env):
    return "key=%s created=%s request=%s" % (
        env.keyid, env.created, env.request or "-")


def cmd_verify(args):
    try:
        env = parse(_read_envelope(args))
        pub = _load_pub(args)
    except (EnvelopeError, _CliError) as exc:
        return _fail(str(exc), getattr(exc, "code", EXIT_MALFORMED))
    except Exception as exc:
        return _fail("malformed envelope: %s" % exc, EXIT_MALFORMED)
    if not verify_envelope(env, pub):
        return _fail("signature verification failed", EXIT_BAD_SIGNATURE)
    request = _request_arg(args)
    if request is not None and env.request != _sm3.sm3(request).hex():
        return _fail("request binding mismatch", EXIT_BAD_SIGNATURE)
    sys.stdout.write("OK %s\n" % _describe(env))
    return EXIT_OK


def cmd_open(args):
    p = _paths(args.home)
    if not os.path.exists(p["priv"]):
        return _fail("no private key at %s (run: smseal.py keygen)" % p["priv"],
                     EXIT_USAGE)
    try:
        priv = load_private_pem(_read_text(p["priv"]))
    except Exception as exc:
        return _fail("cannot load private key %s: %s" % (p["priv"], exc),
                     EXIT_USAGE)
    try:
        env = parse(_read_envelope(args))
    except (EnvelopeError, _CliError) as exc:
        return _fail(str(exc), getattr(exc, "code", EXIT_MALFORMED))
    except Exception as exc:
        return _fail("malformed envelope: %s" % exc, EXIT_MALFORMED)

    local_id = keyid(priv.public_key())
    if env.keyid != local_id:
        return _fail(
            "envelope was sealed to key id %s, but the local key is %s "
            "(missing private key for %s)" % (env.keyid, local_id, env.keyid),
            EXIT_DECRYPT_FAILED)

    try:
        plaintext = open_envelope(env, priv, _request_arg(args))
    except EnvelopeError as exc:
        return _fail(str(exc), getattr(exc, "code", EXIT_DECRYPT_FAILED))
    except Exception as exc:
        return _fail("could not open envelope: %s" % exc, EXIT_DECRYPT_FAILED)

    sys.stdout.write("OK %s\n" % _describe(env))
    sys.stdout.write(plaintext.decode("utf-8", "replace"))
    if not plaintext.endswith(b"\n"):
        sys.stdout.write("\n")
    return EXIT_OK


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command")

    def home_opt(sp):
        sp.add_argument("--home", default=_default_home(),
                        help="sovereign-echo home directory")

    sp = sub.add_parser("keygen", help="generate an SM2 key pair")
    home_opt(sp)
    sp.add_argument("--force", action="store_true", help="overwrite existing keys")

    sp = sub.add_parser("seal", help="seal a notice into an envelope")
    home_opt(sp)
    sp.add_argument("--notice", help="notice file (default: <home>/declarations/notice.compact.txt)")
    sp.add_argument("--hook", action="store_true",
                    help="read a hook JSON payload from stdin for request binding")
    sp.add_argument("--request", help="explicit request text to bind")

    sp = sub.add_parser("open", help="verify and decrypt an envelope")
    home_opt(sp)
    sp.add_argument("--in", dest="infile", help="envelope file (default: stdin)")
    sp.add_argument("--pubkey", help="public key file (verify only)")
    sp.add_argument("--request", help="request text the envelope must be bound to")

    sp = sub.add_parser("verify", help="verify an envelope's signature")
    home_opt(sp)
    sp.add_argument("--in", dest="infile", help="envelope file (default: stdin)")
    sp.add_argument("--pubkey", help="public key file (default: the local one)")
    sp.add_argument("--request", help="request text the envelope must be bound to")

    sp = sub.add_parser("pubkey", help="print the local public key PEM")
    home_opt(sp)

    return parser


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_usage(sys.stderr)
        return EXIT_USAGE
    handlers = {
        "keygen": cmd_keygen,
        "seal": cmd_seal,
        "open": cmd_open,
        "verify": cmd_verify,
        "pubkey": cmd_pubkey,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
