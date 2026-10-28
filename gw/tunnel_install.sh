#!/bin/bash
# SPECTRO tunel de saida R0 (candidato). Subcomandos: snapshot | install | setup | verify | start | rollback
# Instala o cliente OFICIAL openai/tunnel-client-runtime v0.0.14 (sha256 fixado) numa conta propria sem privilegio.
# NAO abre porta, NAO toca ssh/ACL/docker/supervisor, NAO emite grant. A chave de execucao e digitada so aqui (setup), nunca em chat.
# install exige /root/aprovo-tunel-instalar; start exige /root/aprovo-tunel-iniciar (so o dono cria).
set -euo pipefail
umask 077
R="${DESTROOT:-}"
SKIP="${SKIP_SYSTEM:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BK="${BACKUP_DIR:-$R/var/backups/spectro-tunnel-r0}"
TD="$R/opt/spectro/tunnel"
UNIT=spectro-tunnel.service
VER=v0.0.14
ZIP="tunnel-client-runtime-$VER-linux-amd64.zip"
URL="https://github.com/openai/tunnel-client/releases/download/$VER/$ZIP"
SHA=29d29cf860ada54e4d3c82c715f4fbfcff2abcdc2584c0fc26431308dfa2505b
TARGETS=("$TD" "$R/etc/spectro/tunnel.env" "$R/etc/systemd/system/$UNIT")
BASE_FILES=("$R/etc/passwd" "$R/etc/group" "$R/etc/shadow" "$R/etc/gshadow")
die(){ echo "ERRO: $*" >&2; exit 1; }
need_root(){ [ "$SKIP" = 1 ] || [ "$(id -u)" = 0 ] || die "precisa de root"; }

snapshot(){
  need_root
  for t in "${TARGETS[@]}"; do [ ! -e "$t" ] || die "destino ja existe: $t"; done
  [ "$SKIP" = 1 ] || ! id spectro-tunnel >/dev/null 2>&1 || die "usuario spectro-tunnel ja existe"
  local d="$BK/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$d/files"; chmod 700 "$BK" "$d" "$d/files"; : > "$d/manifest.txt"
  for f in "${BASE_FILES[@]}"; do
    if [ -e "$f" ]; then cp -p -- "$f" "$d/files/$(echo "${f#$R}" | tr / _)"; echo "PRESENT $(sha256sum < "$f" | cut -d' ' -f1) ${f#$R}" >> "$d/manifest.txt"
    else echo "MISSING - ${f#$R}" >> "$d/manifest.txt"; fi
  done
  for t in "${TARGETS[@]}"; do echo "ABSENT - ${t#$R}" >> "$d/manifest.txt"; done
  echo "ABSENT - user:spectro-tunnel" >> "$d/manifest.txt"
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
  need_root; verify
  [ "$SKIP" = 1 ] || [ -e /root/aprovo-tunel-instalar ] || die "falta /root/aprovo-tunel-instalar (so o dono cria)"
  [ "$SKIP" = 1 ] || systemctl is-active --quiet spectro-gateway-vps.service || die "gateway nao esta ativo (rode: sh gw/go.sh start)"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-/nonexistent-nada}"' EXIT
  if [ "$SKIP" != 1 ]; then
    curl -fsSL --max-time 180 -o "$tmp/$ZIP" "$URL" || die "download falhou"
  else cp "$HERE/$ZIP" "$tmp/$ZIP"; fi
  echo "$SHA  $tmp/$ZIP" | sha256sum -c - >/dev/null || die "SHA256 DIFERENTE do fixado ($SHA). Nada instalado."
  echo "SHA256_OK $ZIP"
  python3 -I - "$tmp/$ZIP" "$tmp" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert "tunnel-client-runtime" in z.namelist()
open(sys.argv[2] + "/tunnel-client-runtime", "wb").write(z.read("tunnel-client-runtime"))
PY
  if [ "$SKIP" != 1 ]; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --comment "SPECTRO tunnel R0" spectro-tunnel
    usermod -p '*' spectro-tunnel
    gpasswd -d spectro-tunnel sudo >/dev/null 2>&1 || true
    ! id -nG spectro-tunnel | grep -qwE 'sudo|wheel|root|adm|docker' || die "spectro-tunnel em grupo privilegiado"
  fi
  install -d -m 0755 -o root -g root "$R/etc/spectro" "$R/opt/spectro" "$TD"
  install -m 0755 -o root -g root "$tmp/tunnel-client-runtime" "$TD/tunnel-client-runtime"
  install -m 0644 -o root -g root "$HERE/$UNIT" "$R/etc/systemd/system/$UNIT"
  [ "$SKIP" = 1 ] || systemctl daemon-reload
  echo "INSTALL_OK (cliente instalado; SEM configuracao e SEM iniciar). Proximo: sh gw/go.sh tsetup"
  sha256sum "$TD/tunnel-client-runtime" "$R/etc/systemd/system/$UNIT"
}

setup_(){
  need_root
  [ -x "$TD/tunnel-client-runtime" ] || die "rode install antes"
  [ ! -e "$R/etc/spectro/tunnel.env" ] || die "tunnel.env ja existe (rollback para refazer)"
  local id key
  read -r -p "ID do tunel (tunnel_...): " id
  [[ "$id" =~ ^tunnel_[0-9a-f]{32}$ ]] || die "ID invalido (esperado tunnel_ + 32 hex)"
  read -r -s -p "Chave de execucao (nao aparece na tela): " key; echo
  [ "${#key}" -ge 20 ] && [[ "$key" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "chave com formato estranho (nada gravado)"
  ( umask 077
    { printf 'CONTROL_PLANE_TUNNEL_ID=%s\n' "$id"
      printf 'CONTROL_PLANE_API_KEY=%s\n' "$key"
      printf 'MCP_SERVER_URL=http://127.0.0.1:%s/mcp\n' "${GATEWAY_PORT:-18791}"
      printf 'HEALTH_LISTEN_ADDR=127.0.0.1:18792\n'
      printf 'MCP_STARTUP_WAIT_TIMEOUT=30s\n'; } > "$R/etc/spectro/tunnel.env" )
  unset key
  chown root:spectro-tunnel "$R/etc/spectro/tunnel.env" 2>/dev/null || true
  chmod 0640 "$R/etc/spectro/tunnel.env"
  echo "SETUP_OK (gravado 0640 root:spectro-tunnel; chave nao exibida). Proximo: crie /root/aprovo-tunel-iniciar e rode: sh gw/go.sh tstart"
}

start_(){
  need_root
  [ -e /root/aprovo-tunel-iniciar ] || die "falta /root/aprovo-tunel-iniciar (so o dono cria)"
  [ -s /etc/spectro/tunnel.env ] || die "rode setup antes"
  systemctl start "$UNIT"; sleep 5
  systemctl is-active --quiet "$UNIT" || die "tunel nao ficou ativo (veja: journalctl -u $UNIT -n 25 --no-pager)"
  echo "TUNEL_ATIVO. Ultimas linhas do log (sem segredos):"
  journalctl -u "$UNIT" -n 12 --no-pager -o cat | cut -c1-160 | sed -E 's/(tunnel_[0-9a-f]{6})[0-9a-f]+/\1.../g'
}

rollback(){
  need_root
  local d; d="$(cat "$BK/LATEST")"
  [ "$SKIP" = 1 ] || { systemctl stop "$UNIT" 2>/dev/null || true; systemctl disable "$UNIT" 2>/dev/null || true
                       systemctl kill --kill-who=all --signal=SIGKILL "$UNIT" 2>/dev/null || true; }
  while read -r st h p; do
    [ "$st" = ABSENT ] || continue
    case "$p" in user:*) continue;; esac
    rm -rf -- "$R$p"
  done < "$d/manifest.txt"
  rmdir "$R/opt/spectro" 2>/dev/null || true
  [ "$SKIP" = 1 ] || { systemctl daemon-reload; id spectro-tunnel >/dev/null 2>&1 && userdel spectro-tunnel; true; }
  echo "ROLLBACK_OK (gateway, ssh, ACL, docker, supervisor nao foram tocados)."
}

case "${1:-}" in
  snapshot) snapshot;; install) install_;; setup) setup_;; verify) verify;; start) start_;; rollback) rollback;;
  *) echo "uso: $0 snapshot|install|setup|verify|start|rollback" >&2; exit 2;;
esac
