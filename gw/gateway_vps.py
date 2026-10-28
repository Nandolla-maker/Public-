"""Gateway SPECTRO que roda NA VPS (R0.3, candidato, NAO instalado). Substitui a rota Mac/SSH/:2222.

Perfis FIXOS na construcao (nao ha como mudar em runtime):
  read : {vps_probe}
  work : {vps_probe, vps_work_run}
Toda chamada exige grant Ed25519 assinado pelo dono (escopo por ferramenta, epoca, TTL<=1h, revogacao), STOP checado antes,
depois do START e depois da execucao, e agora TAMBEM durante ela (local_runner mata o grupo e descarta a saida).
Escuta so em 127.0.0.1; a unica ponte para fora e o cliente de tunel de SAIDA (decisao do dono: opcao 1).
Shells do Mac (shell_run/shell_start/fastpath_readonly) nao existem aqui. vps_work_run roda como o usuario do servico
(nao-root por padrao); root so por decisao separada do dono.
"""
import json, os, sys, threading, time
from collections import deque
import gateway_core as g
import local_runner as lr
import probe_gate as pg
from gateway_server import load_pubkey

PROFILES = {"read": ("vps_probe",), "work": ("vps_probe", "vps_work_run")}
MAX_CMD = 2000
MAX_TIMEOUT = 120
RATE_N, RATE_WINDOW_S = 30, 10


def make_stop_fn(state_dir, epoch_fn, halt_paths=pg.HALT_PATHS):
    """Retorna stop() para UMA execucao: True se STOP, flag de HALT, ou epoca mudou/ilegivel/velha (fail-closed)."""
    try:
        e0 = int(epoch_fn())
    except Exception:
        return lambda: True
    stop_path = os.path.join(state_dir, "STOP")

    def stop():
        try:
            os.lstat(stop_path)
            return True
        except FileNotFoundError:
            pass
        except OSError:
            return True
        if pg.halted(halt_paths):
            return True
        try:
            return int(epoch_fn()) != e0
        except Exception:
            return True
    return stop


def _pack(rc, data):
    return json.dumps({"rc": rc, "out": data.decode("utf-8", "replace")}, sort_keys=True)


def build_tools(profile, *, state_dir, epoch_fn, work_home, halt_paths=pg.HALT_PATHS, probe_poll=lr.POLL_S):
    if profile not in PROFILES:
        raise ValueError("perfil")
    work_lock = threading.Lock()

    def _vps_probe(args):
        if set(args) != {"probe"} or not isinstance(args["probe"], str) or args["probe"] not in pg.TABLE:
            raise ValueError("args")
        stop = make_stop_fn(state_dir, epoch_fn, halt_paths)
        rc, out = lr.run_guarded(["/bin/sh", "-c", pg.TABLE[args["probe"]]], env=dict(pg.SAFE_ENV), cwd="/",
                                 timeout_s=pg.TIMEOUT_S, stop_fn=stop, max_out=65536, poll_s=probe_poll)
        if rc == lr.RC_STOP:
            raise g.Refused("STOP_ACTIVE")
        return _pack(rc, out)

    def _vps_work_run(args):
        if not set(args) <= {"command", "timeout_s"} or "command" not in args:
            raise ValueError("args")
        cmd, t = args["command"], args.get("timeout_s", 30)
        if not isinstance(cmd, str) or not cmd.strip() or len(cmd) > MAX_CMD or "\0" in cmd:
            raise ValueError("command")
        if type(t) is not int or not (1 <= t <= MAX_TIMEOUT):
            raise ValueError("timeout_s")
        if not work_lock.acquire(blocking=False):
            raise g.Refused("BUSY")
        try:
            stop = make_stop_fn(state_dir, epoch_fn, halt_paths)
            env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C", "HOME": work_home}
            rc, out = lr.run_guarded(["/bin/bash", "--noprofile", "--norc", "-c", cmd], env=env, cwd=work_home,
                                     timeout_s=t, stop_fn=stop, max_out=32768, poll_s=probe_poll)
        finally:
            work_lock.release()
        if rc == lr.RC_STOP:
            raise g.Refused("STOP_ACTIVE")
        return _pack(rc, out)

    tools = {"vps_probe": _vps_probe}
    if profile == "work":
        tools["vps_work_run"] = _vps_work_run
    return tools


def build_gateway(*, profile, pub, aud, state_dir, epoch_fn, work_home="/var/lib/spectro-gateway/work", **kw):
    return g.Gateway(build_tools(profile, state_dir=state_dir, epoch_fn=epoch_fn, work_home=work_home, **kw),
                     pub=pub, aud=aud, state_dir=state_dir, epoch_fn=epoch_fn)


class RateLimiter:
    def __init__(self, n=RATE_N, window=RATE_WINDOW_S, clock=time.monotonic):
        self.n, self.w, self.clock, self.q, self.lock = n, window, clock, deque(), threading.Lock()

    def allow(self):
        with self.lock:
            now = self.clock()
            while self.q and now - self.q[0] > self.w:
                self.q.popleft()
            if len(self.q) >= self.n:
                return False
            self.q.append(now)
            return True


def build_mcp(gw, profile, limiter=None):
    from mcp.server.mcpserver import MCPServer
    mcp = MCPServer("spectro-gateway-vps")
    lim = limiter or RateLimiter()

    def guarded(name, args, grant):
        if not lim.allow():
            return {"status": "REFUSED", "code": "RATE_LIMIT"}
        return gw.call(name, args, grant)

    @mcp.tool(name="vps_probe", description="Sonda somente leitura da VPS (identity, tunnel_unit, tunnel_key_present, uptime, halt_flags). Exige grant assinado do dono com escopo vps_probe.")
    def vps_probe(probe: str, grant: str) -> str:
        return json.dumps(guarded("vps_probe", {"probe": probe}, grant), sort_keys=True)

    if profile == "work":
        @mcp.tool(name="vps_work_run", description="Executa um comando na VPS como o usuario do servico. Exige grant assinado do dono com escopo vps_work_run (validade maxima 1 h). STOP/HALT interrompe no meio e descarta a saida.")
        def vps_work_run(command: str, grant: str, timeout_s: int = 30) -> str:
            return json.dumps(guarded("vps_work_run", {"command": command, "timeout_s": timeout_s}, grant), sort_keys=True)
    return mcp


def main(argv):
    """uso: gateway_vps.py read|work PUBKEY_FILE AUD STATE_DIR STATUS_JSON PORT PUBLIC_HOST
    Escuta SO em 127.0.0.1:PORT; PUBLIC_HOST e o Host do tunel (protecao contra DNS rebinding)."""
    if len(argv) != 8 or argv[1] not in PROFILES:
        print(main.__doc__, file=sys.stderr)
        return 2
    _, profile, pubf, aud, state, status, port, public_host = argv
    from mcp.server.transport_security import TransportSecuritySettings
    epoch_fn = lambda: g.epoch_from_status(status, time.time())
    gw = build_gateway(profile=profile, pub=load_pubkey(pubf), aud=aud, state_dir=state, epoch_fn=epoch_fn)
    ts = TransportSecuritySettings(enable_dns_rebinding_protection=True,
                                   allowed_hosts=["127.0.0.1:%s" % port, "localhost:%s" % port, public_host],
                                   allowed_origins=["https://%s" % public_host])
    build_mcp(gw, profile).run("streamable-http", host="127.0.0.1", port=int(port), transport_security=ts,
                               stateless_http=True, json_response=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
