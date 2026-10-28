"""Executor local guardado (R0.3, candidato, NAO instalado). Roda um comando em grupo de processos proprio,
sonda `stop_fn` a cada POLL_S e, em parada, mata o grupo (SIGKILL) e DESCARTA toda a saida.
Em producao o servico roda em unidade systemd com KillMode=control-group: o supervisor parando a unidade mata tambem
quem escapou do grupo (setsid/fork). Aqui, so o grupo e provado (o sandbox nao tem cgroup)."""
import os, signal, subprocess, time

POLL_S = 0.05
RC_STOP, RC_TIMEOUT, RC_OUTPUT = 3, 124, 125


def run_guarded(argv, *, env, cwd, timeout_s, stop_fn, max_out=32768, poll_s=POLL_S):
    """Retorna (rc, bytes). rc==RC_STOP => saida vazia garantida. stop_fn() True/excecao => parada (fail-closed)."""
    def stopped():
        try:
            return bool(stop_fn())
        except Exception:
            return True
    if stopped():
        return RC_STOP, b""
    p = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, start_new_session=True, close_fds=True)
    os.set_blocking(p.stdout.fileno(), False)
    buf, t0, over = bytearray(), time.monotonic(), False
    def kill():
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
    try:
        while True:
            try:
                chunk = os.read(p.stdout.fileno(), 65536)
            except BlockingIOError:
                chunk = None
            if chunk:
                if len(buf) + len(chunk) > max_out:
                    over = True
                else:
                    buf += chunk
            if stopped():
                kill()
                return RC_STOP, b""
            if over:
                kill()
                return RC_OUTPUT, b""
            if time.monotonic() - t0 > timeout_s:
                kill()
                return RC_TIMEOUT, b""
            if chunk == b"" or (chunk is None and p.poll() is not None):
                if p.poll() is None:
                    p.wait()
                break
            if chunk is None:
                time.sleep(poll_s)
        try:                                    # resto do pipe depois do exit
            while True:
                rest = os.read(p.stdout.fileno(), 65536)
                if not rest:
                    break
                if len(buf) + len(rest) > max_out:
                    return RC_OUTPUT, b""
                buf += rest
        except BlockingIOError:
            pass
    finally:
        if p.poll() is None:
            kill()
        p.stdout.close()
        try:                                    # nada fica vivo no grupo apos o fim
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    if stopped():
        return RC_STOP, b""
    return p.returncode, bytes(buf)
