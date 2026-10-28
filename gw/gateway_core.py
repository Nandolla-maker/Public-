"""SPECTRO gateway core R0.2 (candidato, NAO instalado; so verifica; depende de `cryptography`).

Objetivo: MCP proprio do SPECTRO com
  * registro EXPLICITO por perfil: o que e anunciado == o que e chamavel (um unico caminho de despacho);
  * grant assinado (escopo, dono, epoca, TTL, revogacao) verificado a CADA chamada;
  * STOP checado antes, depois do START e depois da chamada; qualquer duvida = ativo;
  * auditoria fail-closed (START antes do efeito; falha => REFUSED, zero efeitos).
Assinatura ASSIMETRICA (Ed25519): o gateway so conhece a chave PUBLICA e nao tem codigo para assinar.
A chave privada fica so na cerimonia (ceremony.py), no dispositivo do dono, cifrada por senha que agentes nao tem.
Este modulo NAO cria autoridade: so verifica.
"""
import base64, json, os, stat, time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

VERSION = "gateway-core-R0.3"
MAX_TTL_S = 3600          # grant curto; renovacao exige nova cerimonia
MAX_TOKEN = 4096
MAX_ARGS = 4096
MAX_OUT = 8192


class Refused(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def b64e(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


DOM_GRANT = b"spectro-grant-v1\0"
DOM_REVOKE = b"spectro-revoke-v1\0"


def _verify_sig(pub, domain, token):
    """token = base64url(json).base64url(sig). Retorna o dict do corpo ou levanta ValueError."""
    if not isinstance(token, str) or len(token) > MAX_TOKEN or token.count(".") != 1:
        raise ValueError("malformed")
    body, sig = token.split(".")
    try:
        pub.verify(b64d(sig), domain + body.encode())
    except (InvalidSignature, ValueError):
        raise InvalidSignature()
    p = json.loads(b64d(body))
    if not isinstance(p, dict):
        raise ValueError("malformed")
    return p


def verify_grant(token, pub, *, tool, epoch, now, revoked, aud):
    try:
        p = _verify_sig(pub, DOM_GRANT, token)
    except InvalidSignature:
        raise Refused("GRANT_BAD_SIGNATURE")
    except Exception:
        raise Refused("GRANT_MALFORMED")
    try:
        gid, owner, scope, a = p["grant_id"], p["owner"], p["scope"], p["aud"]
        nb, exp, ep = int(p["not_before"]), int(p["expires"]), int(p["epoch"])
    except Exception:
        raise Refused("GRANT_MALFORMED")
    if not (isinstance(gid, str) and gid and isinstance(owner, str) and owner and isinstance(a, str)
            and isinstance(scope, list) and all(isinstance(s, str) for s in scope)):
        raise Refused("GRANT_MALFORMED")
    if a != aud:
        raise Refused("GRANT_AUDIENCE_MISMATCH")
    if exp - nb > MAX_TTL_S or exp <= nb:
        raise Refused("GRANT_TTL_INVALID")
    if now < nb:
        raise Refused("GRANT_NOT_YET_VALID")
    if now >= exp:
        raise Refused("GRANT_EXPIRED")
    if ep != epoch:
        raise Refused("GRANT_EPOCH_MISMATCH")
    if gid in revoked:
        raise Refused("GRANT_REVOKED")
    if tool not in scope:
        raise Refused("GRANT_SCOPE_DENIED")
    return {"grant_id": gid, "owner": owner}


STATUS_MAX_AGE_S = 10     # supervisor publica a cada ~1 s (observado em #103); HALT dorme 5 s mas ai o estado nao e RUNNING
STATUS_FUTURE_S = 2


def parse_status(d, now=None):
    """Formato CONFIRMADO em #103 (comentarios 6457490998 e 6458658529): {at, scope, state, kernel:{activeLeases, epoch, state}}.
    Fonte root /var/lib/spectro-sovereign-r1/status.json; espelho /srv/paperclip/data/spectro-sovereign-r1/status.json;
    `at` atualiza ~1 s. Exige state==RUNNING e kernel.state==RUNNING, kernel.epoch inteiro >= 0 e, se `now` for dado,
    frescor (at entre -2 s e +10 s de `now`). RUNNING nao atesta grant/CLEAR.
    """
    if not isinstance(d, dict) or not isinstance(d.get("kernel"), dict):
        raise ValueError("status")
    k = d["kernel"]
    if d.get("state") != "RUNNING" or k.get("state") != "RUNNING":
        raise ValueError("status")
    e, at = k.get("epoch"), d.get("at")
    if type(e) is not int or e < 0:
        raise ValueError("status")
    if now is not None:                                  # frescor so quando o relogio e fornecido (gateway sempre fornece)
        if isinstance(at, bool) or not isinstance(at, (int, float)) or not (-STATUS_FUTURE_S <= now - at <= STATUS_MAX_AGE_S):
            raise ValueError("stale")
    return e


def epoch_from_status(path, now=None):
    """Le a epoca do supervisor (somente leitura, sem seguir symlink). Fail-closed: qualquer duvida => excecao."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > 65536:
            raise ValueError("status")
        d = json.loads(os.read(fd, 65536))
    finally:
        os.close(fd)
    return parse_status(d, now)


def _mask(s, n=MAX_OUT):
    s = "".join(c if 32 <= ord(c) < 127 or c in "\n\t" else "?" for c in str(s))
    return s[:n]


class Audit:
    """JSONL append-only, aberto com O_NOFOLLOW, dono=euid, 1 link, write-all + fsync."""

    def __init__(self, path):
        self.path = path
        self.fd = None

    def open(self):
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1:
                os.close(fd)
                raise Refused("AUDIT_UNAVAILABLE")
            os.fchmod(fd, 0o600)
            self.fd = fd
        except OSError:
            raise Refused("AUDIT_UNAVAILABLE")

    def write(self, rec):
        data = (json.dumps(rec, sort_keys=True) + "\n").encode()
        try:
            mv = memoryview(data)
            while mv:
                n = os.write(self.fd, mv)
                if n <= 0:
                    raise OSError("short")
                mv = mv[n:]
            os.fsync(self.fd)
        except OSError:
            raise Refused("AUDIT_UNAVAILABLE")


class Gateway:
    """tools: dict nome -> callable(args:dict)->str. O perfil e FIXO na construcao."""

    def __init__(self, tools, *, pub, aud, state_dir, epoch_fn, clock=time.time):
        self._tools = dict(tools)
        self._pub = pub
        self._aud = aud
        self._dir = state_dir
        self._epoch_fn = epoch_fn
        self._clock = clock

    def list_tools(self):
        return sorted(self._tools)

    def _stop(self):
        try:
            os.lstat(os.path.join(self._dir, "STOP"))
            return True
        except FileNotFoundError:
            return False
        except OSError:
            return True

    def _revoked(self):
        p = os.path.join(self._dir, "revoked.json")
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except FileNotFoundError:
            return set()
        except OSError:
            raise Refused("REVOCATION_UNREADABLE")
        try:
            items = json.loads(os.read(fd, 65536) or b"[]")
            if not isinstance(items, list):
                raise ValueError("rev")
            out = set()
            for tok in items:                     # cada revogacao precisa de assinatura do dono
                out.add(str(_verify_sig(self._pub, DOM_REVOKE, tok)["grant_id"]))
            return out
        except Exception:
            raise Refused("REVOCATION_UNREADABLE")
        finally:
            os.close(fd)

    def call(self, name, args, token):
        try:
            return self._call(name, args, token)
        except Refused as r:
            return {"status": "REFUSED", "code": r.code, "authority": "GRANT_VERIFIED_LOCAL_STOP"}

    def _call(self, name, args, token):
        if name not in self._tools:               # nao anunciado => nao chamavel
            raise Refused("UNKNOWN_TOOL")
        if not isinstance(args, dict) or len(json.dumps(args)) > MAX_ARGS:
            raise Refused("ARGS_INVALID")
        if self._stop():
            raise Refused("STOP_ACTIVE")
        try:
            epoch = int(self._epoch_fn())
        except Exception:
            raise Refused("EPOCH_UNAVAILABLE")
        who = verify_grant(token, self._pub, tool=name, epoch=epoch,
                           now=int(self._clock()), revoked=self._revoked(), aud=self._aud)
        a = Audit(os.path.join(self._dir, "audit.jsonl"))
        a.open()
        try:
            base = {"tool": name, "grant_id": who["grant_id"], "owner": who["owner"], "epoch": epoch,
                    "args": _mask(json.dumps(args, sort_keys=True), 512)}
            a.write(dict(base, phase="START", t=int(self._clock())))
            if self._stop():                       # corrida STOP entre START e efeito
                a.write(dict(base, phase="END", status="REFUSED_STOP"))
                raise Refused("STOP_ACTIVE")
            try:
                out = _mask(self._tools[name](args))
            except Refused as r:
                a.write(dict(base, phase="END", status="REFUSED_TOOL", code=r.code))
                raise
            except Exception as e:
                a.write(dict(base, phase="END", status="ERROR", err=type(e).__name__))
                return {"status": "ERROR", "code": "TOOL_ERROR"}
            if self._stop():                       # STOP durante a execucao: descarta resultado
                a.write(dict(base, phase="END", status="DISCARDED_STOP"))
                raise Refused("STOP_ACTIVE")
            a.write(dict(base, phase="END", status="OK", size=len(out)))
            return {"status": "OK", "output": out, "grant_id": who["grant_id"]}
        finally:
            os.close(a.fd)
