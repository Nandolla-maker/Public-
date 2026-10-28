"""probe_status_relay R0 (candidato). Roda como root, so le o status.json do supervisor e publica UMA copia minima
em /run/spectro-probe/status.json (root:spectro-probe 0640) para a conta da sonda ler sem abrir /var/lib nem /srv/paperclip.
Copia so: at, state, kernel.state, kernel.epoch. O campo `at` e copiado SEM mudar: se o relay ou o supervisor parar, o arquivo
envelhece e o gate recusa (fail-closed). Nunca escreve em /var/lib. Nao executa nada, nao abre rede."""
import grp, json, os, stat, sys, time

SRC = "/var/lib/spectro-sovereign-r1/status.json"
DST_DIR = "/run/spectro-probe"
DST_NAME = "status.json"
GROUP = "spectro-probe"
PERIOD_S = 1.0
MAX_SRC = 65536


def minimal(d):
    """Extrai so os campos necessarios; None se a forma for invalida (nada e publicado => arquivo envelhece)."""
    if not isinstance(d, dict) or not isinstance(d.get("kernel"), dict):
        return None
    k = d["kernel"]
    at, st, ks, ep = d.get("at"), d.get("state"), k.get("state"), k.get("epoch")
    if isinstance(at, bool) or not isinstance(at, (int, float)):
        return None
    if not isinstance(st, str) or not isinstance(ks, str) or len(st) > 32 or len(ks) > 32:
        return None
    if type(ep) is not int or ep < 0:
        return None
    return {"at": at, "state": st, "kernel": {"state": ks, "epoch": ep}}


def read_src(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_size > MAX_SRC:
            raise ValueError("src")
        return json.loads(os.read(fd, MAX_SRC))
    finally:
        os.close(fd)


def publish(doc, dst_dir, gid):
    tmp = os.path.join(dst_dir, ".status.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o640)
    try:
        os.write(fd, json.dumps(doc, sort_keys=True).encode())
        if gid is not None:
            os.fchown(fd, 0, gid)
        os.fchmod(fd, 0o640)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, os.path.join(dst_dir, DST_NAME))


def once(src, dst_dir, gid):
    """Uma iteracao. Retorna True se publicou."""
    try:
        doc = minimal(read_src(src))
    except Exception:
        return False
    if doc is None:
        return False
    publish(doc, dst_dir, gid)
    return True


def main():
    gid = grp.getgrnam(GROUP).gr_gid
    os.makedirs(DST_DIR, mode=0o750, exist_ok=True)
    os.chown(DST_DIR, 0, gid)
    os.chmod(DST_DIR, 0o750)
    while True:
        t0 = time.monotonic()
        try:
            once(SRC, DST_DIR, gid)
        except Exception as e:
            sys.stderr.write("relay: %s\n" % type(e).__name__)
        time.sleep(max(0.05, PERIOD_S - (time.monotonic() - t0)))


if __name__ == "__main__":
    main()
