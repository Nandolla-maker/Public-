#!/bin/bash
# SPECTRO gateway VPS install R0.3 (candidato). Subcomandos: snapshot | install | verify | start | rollback
# Perfil LEITURA apenas (so vps_probe). NAO toca na porta 22, ACL, firewall, ssh, docker, supervisor. NAO emite grant.
# install exige /root/aprovo-gateway-instalar; start exige /root/aprovo-gateway-iniciar (arquivos que SO o dono cria).
# DESTROOT/SKIP_SYSTEM=1 so para teste em sandbox.
set -euo pipefail
umask 077
R="${DESTROOT:-}"
SKIP="${SKIP_SYSTEM:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BK="${BACKUP_DIR:-$R/var/backups/spectro-gateway-r0}"
GW="$R/opt/spectro/gateway"
UNIT=spectro-gateway-vps.service
RELAY_UNIT=spectro-probe-status-relay.service
PORT="${GATEWAY_PORT:-18791}"
APP_FILES=(gateway_core.py gateway_server.py local_runner.py gateway_vps.py probe_gate.py)
TARGETS=("$GW" "$R/etc/spectro/owner_public.key" "$R/etc/spectro/gateway.env" "$R/etc/systemd/system/$UNIT"
         "$R/etc/systemd/system/$RELAY_UNIT" "$R/usr/local/lib/spectro/probe_status_relay.py")
BASE_FILES=("$R/etc/passwd" "$R/etc/group" "$R/etc/shadow" "$R/etc/gshadow"
            "$R/etc/systemd/system/spectro-sovereign-supervisor-r1.service"
            "$R/opt/spectro/sovereign-r1/sovereign_production.py")
die(){ echo "ERRO: $*" >&2; exit 1; }
need_root(){ [ "$SKIP" = 1 ] || [ "$(id -u)" = 0 ] || die "precisa de root"; }

snapshot(){
  need_root
  for t in "${TARGETS[@]}"; do [ ! -e "$t" ] || die "destino ja existe (nao e instalacao limpa): $t"; done
  [ "$SKIP" = 1 ] || ! id spectro-probe >/dev/null 2>&1 || die "usuario spectro-probe ja existe"
  local d="$BK/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$d/files"; chmod 700 "$BK" "$d" "$d/files"
  : > "$d/manifest.txt"
  for f in "${BASE_FILES[@]}"; do
    if [ -e "$f" ]; then
      cp -p -- "$f" "$d/files/$(echo "${f#$R}" | tr / _)"
      echo "PRESENT $(sha256sum < "$f" | cut -d' ' -f1) ${f#$R}" >> "$d/manifest.txt"
    else echo "MISSING - ${f#$R}" >> "$d/manifest.txt"; fi
  done
  for t in "${TARGETS[@]}"; do echo "ABSENT - ${t#$R}" >> "$d/manifest.txt"; done
  echo "ABSENT - user:spectro-probe" >> "$d/manifest.txt"
  ( cd "$d" && sha256sum manifest.txt files/* > SHA256SUMS )
  echo "$d" > "$BK/LATEST"
  echo "SNAPSHOT_OK $d. Copias contem contas do sistema: NAO publicar."
}

verify(){
  local d; d="$(cat "$BK/LATEST" 2>/dev/null)" || die "sem snapshot"
  ( cd "$d" && sha256sum -c SHA256SUMS >/dev/null ) || die "snapshot corrompido"
  while read -r st h p; do
    [ "$st" = PRESENT ] || continue
    [ "$(sha256sum < "$R$p" | cut -d' ' -f1)" = "$h" ] || echo "AVISO: mudou desde o snapshot: $p"
  done < "$d/manifest.txt"
  echo "VERIFY_OK $d"
}

install_(){
  need_root
  verify
  [ "$SKIP" = 1 ] || [ -e /root/aprovo-gateway-instalar ] || die "falta /root/aprovo-gateway-instalar (so o dono cria)"
  : "${OWNER_PUBKEY:?OWNER_PUBKEY obrigatorio (chave publica do dono, base64url 43 chars)}"
  [[ "$OWNER_PUBKEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "OWNER_PUBKEY invalida"
  [[ "$PORT" =~ ^[0-9]{4,5}$ ]] || die "porta invalida"
  if [ "$SKIP" != 1 ]; then
    ! ss -ltn | grep -q ":$PORT " || die "porta $PORT ja em uso"
    for f in "${APP_FILES[@]}" probe_status_relay.py "$UNIT" "$RELAY_UNIT"; do [ -f "$HERE/$f" ] || die "falta $f ao lado do instalador"; done
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --comment "SPECTRO gateway R0" spectro-probe
    usermod -p '*' spectro-probe
    gpasswd -d spectro-probe sudo >/dev/null 2>&1 || true
    ! id -nG spectro-probe | grep -qwE 'sudo|wheel|root|adm|docker' || die "spectro-probe em grupo privilegiado"
  fi
  install -d -m 0755 -o root -g root "$R/etc/spectro" "$R/usr/local/lib/spectro" "$R/opt/spectro" "$GW"
  for f in "${APP_FILES[@]}"; do install -m 0644 -o root -g root "$HERE/$f" "$GW/$f"; done
  printf '%s\n' "$OWNER_PUBKEY" > "$R/etc/spectro/owner_public.key"; chmod 0644 "$R/etc/spectro/owner_public.key"
  printf 'GATEWAY_PROFILE=read\nGATEWAY_PORT=%s\nPUBLIC_HOST=localhost\n' "$PORT" > "$R/etc/spectro/gateway.env"; chmod 0644 "$R/etc/spectro/gateway.env"
  install -m 0644 -o root -g root "$HERE/probe_status_relay.py" "$R/usr/local/lib/spectro/probe_status_relay.py"
  install -m 0644 -o root -g root "$HERE/$RELAY_UNIT" "$R/etc/systemd/system/$RELAY_UNIT"
  install -m 0644 -o root -g root "$HERE/$UNIT" "$R/etc/systemd/system/$UNIT"
  if [ "$SKIP" != 1 ]; then
    python3 -m venv "$GW/venv"
    "$GW/venv/bin/pip" install -q --disable-pip-version-check "mcp==2.3.0" "cryptography==50.0.1"
    runuser -u spectro-probe -- "$GW/venv/bin/python" -I -c "import mcp, cryptography, uvicorn; print('DEPS_OK', mcp.__name__)" || die "dependencias nao importam"
    systemctl daemon-reload
    systemctl start "$RELAY_UNIT"
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s /run/spectro-probe/status.json ] && break; sleep 1; done
    runuser -u spectro-probe -- python3 -I -c "import json;d=json.load(open('/run/spectro-probe/status.json'));print('STATUS_RELAY_OK',d['state'],d['kernel']['state'],'epoca',d['kernel']['epoch'])" \
      || die "sonda nao le a copia do status (veja: journalctl -u $RELAY_UNIT)"
  fi
  echo "INSTALL_OK (perfil LEITURA; relay ATIVO; gateway NAO iniciado e NAO habilitado no boot)."
  sha256sum "$GW"/*.py "$R/etc/systemd/system/$UNIT"
}

start_(){
  need_root
  [ -e /root/aprovo-gateway-iniciar ] || die "falta /root/aprovo-gateway-iniciar (so o dono cria)"
  systemctl start "$UNIT"; sleep 2
  systemctl is-active --quiet "$UNIT" || die "unidade nao ficou ativa (veja: journalctl -u $UNIT -n 20 --no-pager)"
  ss -ltn | grep ":$PORT " | grep -q "127.0.0.1" || die "gateway nao escuta em 127.0.0.1:$PORT"
  ! ss -ltn | grep ":$PORT " | grep -vq "127.0.0.1" || die "gateway escuta fora do loopback"
  python3 -I - "$PORT" <<'PY'
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=10)
h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
c.request("POST", "/mcp", json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}), h)
d = json.loads(c.getresponse().read())
print("TOOLS", sorted(t["name"] for t in d["result"]["tools"]))
PY
  echo "START_OK (somente loopback; sem tunel; sem grant emitido)."
}

rollback(){
  need_root
  local d; d="$(cat "$BK/LATEST")"
  if [ "$SKIP" != 1 ]; then
    for u in "$UNIT" "$RELAY_UNIT"; do
      systemctl stop "$u" 2>/dev/null || true
      systemctl disable "$u" 2>/dev/null || true
      systemctl kill --kill-who=all --signal=SIGKILL "$u" 2>/dev/null || true
    done
  fi
  while read -r st h p; do
    [ "$st" = ABSENT ] || continue
    case "$p" in user:*) continue;; esac
    rm -rf -- "$R$p"
  done < "$d/manifest.txt"
  rmdir "$R/usr/local/lib/spectro" "$R/opt/spectro" 2>/dev/null || true
  [ "$SKIP" = 1 ] || { systemctl daemon-reload; rm -rf /var/lib/spectro-gateway; id spectro-probe >/dev/null 2>&1 && userdel spectro-probe; true; }
  echo "ROLLBACK_OK (porta 22/ssh/tailscaled/docker/supervisor nao foram tocados). Conferir: $0 verify"
}

case "${1:-}" in
  snapshot) snapshot;; install) install_;; verify) verify;; start) start_;; rollback) rollback;;
  *) echo "uso: $0 snapshot|install|verify|start|rollback" >&2; exit 2;;
esac
