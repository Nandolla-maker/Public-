"""probe_gate R0.1 (candidato, NAO instalado) - roda NA VPS como comando forcado de UMA chave dedicada.

authorized_keys (uma linha, na conta dedicada; ver TRANSPORT.md):
  restrict,command="/usr/bin/python3 -I /usr/local/lib/spectro/probe_gate.py" ssh-ed25519 AAAA... spectro-probe-r0
`restrict` desliga pty, forwarding, agente, X11 e ~/.ssh/rc. O cliente envia SO o nome da sonda; o gate
mapeia para um comando constante. Qualquer outra coisa => recusa, sem executar nada. Sem argumentos, sem env do cliente.
A tabela abaixo DEVE ser igual a PROBES de vps_probe_candidate (teste confere).
"""
import json, os, signal, stat, subprocess, sys, time

_HDR = "printf 'ID %s %s\\n' \"$(hostname)\" \"$(id -un)\"; "


def _exists_probe(path):
    return ('p="%s"; d="$(dirname "$p")"; '
            'if [ -d "$d" ] && [ -x "$d" ]; then if [ -e "$p" ]; then echo present; else echo absent; fi; '
            'else echo unknown; fi' % path)


def _multi_exists(paths):
    return " ; ".join('printf "%s " "' + p + '"; ' + _exists_probe(p) for p in paths)


TABLE = {
    "identity": _HDR + "date -u +%Y-%m-%dT%H:%M:%SZ",
    "tunnel_unit": _HDR + "systemctl show spectro-mcp-tunnel.service "
                          "-p ActiveState -p SubState -p UnitFileState -p Result -p ExecMainStatus",
    "tunnel_key_present": _HDR + _exists_probe("/srv/spectro-tunnel/openai-runtime.key"),
    "uptime": _HDR + "cat /proc/uptime",
    "halt_flags": _HDR + _multi_exists(["/etc/spectro/SOVEREIGN_HALT", "/srv/spectro/SOVEREIGN_HALT"]),
}
SAFE_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"}
# Lista que o supervisor realmente observa (#103, comentario 6457490998) + o caminho extra que a sonda halt_flags ja olha.
HALT_PATHS = ("/etc/spectro/SOVEREIGN_HALT", "/etc/spectro/cognitive-r1/SOVEREIGN_HALT",
              "/srv/spectro/two-domain-r0/SOVEREIGN_HALT", "/srv/spectro/SOVEREIGN_HALT")
# Caminho do status.json do supervisor: NAO confirmado. None => gate RECUSA (fail-closed) ate o instalador fixar o caminho.
STATUS_PATH = None
STATUS_MAX_AGE_S = 30
TIMEOUT_S = 10
POLL_S = 0.05
RC_HALT = 3


def halted(paths=None):
    """Qualquer entrada (inclusive symlink quebrado) ou erro != ENOENT = HALT ativo (fail-closed)."""
    for p in (HALT_PATHS if paths is None else paths):
        try:
            os.lstat(p)
            return True
        except FileNotFoundError:
            continue
        except OSError:
            return True
    return False


def read_status(path, now=None):
    """Retorna (epoch) se status.json esta fresco e RUNNING/RUNNING; senao levanta ValueError/OSError (=> HALT)."""
    if not isinstance(path, str):
        raise ValueError("status_path")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > 65536:
            raise ValueError("status")
        d = json.loads(os.read(fd, 65536))
    finally:
        os.close(fd)
    k = d.get("kernel") if isinstance(d, dict) else None
    if not isinstance(k, dict) or d.get("state") != "RUNNING" or k.get("state") != "RUNNING":
        raise ValueError("status")
    e, at = k.get("epoch"), d.get("at")
    if type(e) is not int or e < 0 or not isinstance(at, (int, float)) or isinstance(at, bool):
        raise ValueError("status")
    if abs((time.time() if now is None else now) - at) > STATUS_MAX_AGE_S:
        raise ValueError("stale")
    return e


def _stopped(paths, status_path, epoch0):
    """True se flag de HALT, ou (com status_path) estado/frescor/epoca mudaram. status_path=False desliga (so testes)."""
    if halted(paths):
        return True
    if status_path is False:
        return False
    try:
        return read_status(status_path) != epoch0
    except Exception:
        return True


def _run_guarded(cmd, paths=None, status_path=None):
    """Roda o comando constante capturando a saida; sonda HALT/epoca a cada POLL_S; em parada mata o grupo e DESCARTA tudo."""
    epoch0 = None
    if status_path is not False:
        try:
            epoch0 = read_status(status_path)
        except Exception:
            return RC_HALT, b""
    if _stopped(paths, status_path, epoch0):
        return RC_HALT, b""
    p = subprocess.Popen(["/bin/sh", "-c", cmd], env=SAFE_ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    t0 = time.monotonic()
    try:
        while p.poll() is None:
            if _stopped(paths, status_path, epoch0) or time.monotonic() - t0 > TIMEOUT_S:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
                return (RC_HALT if _stopped(paths, status_path, epoch0) else 124), b""
            time.sleep(POLL_S)
        out = p.stdout.read(65536)
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        p.stdout.close()
    if _stopped(paths, status_path, epoch0):   # parada ao final: nada sai
        return RC_HALT, b""
    return p.returncode, out


def run(original, executor=None, halt_paths=None, out=None, status_path=None):
    """Retorna codigo de saida. `original` = SSH_ORIGINAL_COMMAND (string ou None)."""
    if not isinstance(original, str) or original not in TABLE:   # igualdade exata, sem strip/split
        sys.stderr.write("probe_gate: recusado\n")
        return 2
    try:
        if executor is not None:
            return executor(TABLE[original])
        rc, data = _run_guarded(TABLE[original], halt_paths, STATUS_PATH if status_path is None else status_path)
        if rc == RC_HALT:
            sys.stderr.write("probe_gate: HALT\n")
            return rc
        (out or sys.stdout.buffer).write(data)
        (out or sys.stdout.buffer).flush()
        return rc
    except Exception:
        sys.stderr.write("probe_gate: erro\n")
        return 1


if __name__ == "__main__":
    sys.exit(run(os.environ.get("SSH_ORIGINAL_COMMAND")))
