#!/bin/bash
# SPECTRO probe install R0 (candidato). Subcomandos: snapshot | install | verify | start | rollback
# Precisa de root na VPS. Variaveis: TAILNET_IP (obrigatoria p/ install), PUBKEY_FILE (chave publica da sonda, 1 linha),
# STATUS_PATH (opcional; padrao /run/spectro-probe/status.json, copia minima publicada pelo relay root), BACKUP_DIR.
# DESTROOT/SKIP_SYSTEM=1 so para teste em sandbox. O `install` inicia SOMENTE o relay do status (nunca o sshd).
# NAO toca na porta 22, em ACL, firewall, nem no ssh.service. NAO emite grant. NAO inicia o servico fora de `start`.
set -euo pipefail
umask 077
R="${DESTROOT:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$R/var/backups/spectro-probe-r0}"
UNIT=spectro-probe-sshd.service
RELAY_UNIT=spectro-probe-status-relay.service
SKIP="${SKIP_SYSTEM:-0}"
RELAY_FILES=("$R/usr/local/lib/spectro/probe_status_relay.py" "$R/etc/systemd/system/$RELAY_UNIT")
TARGETS=("$R/usr/local/lib/spectro/probe_gate.py" "$R/etc/spectro/probe_authorized_keys" "$R/etc/spectro/sshd_probe_config"
         "$R/etc/systemd/system/$UNIT" "$R/etc/spectro/probe_ssh_host_ed25519_key" "$R/etc/spectro/probe_ssh_host_ed25519_key.pub"
         "${RELAY_FILES[@]}")
BASE_FILES=("$R/etc/passwd" "$R/etc/group" "$R/etc/shadow" "$R/etc/gshadow" "$R/etc/ssh/sshd_config"
            "$R/lib/systemd/system/ssh.service" "$R/lib/systemd/system/ssh.socket"
            "$R/etc/systemd/system/spectro-sovereign-supervisor-r1.service"
            "$R/opt/spectro/sovereign-r1/sovereign_production.py" "$R/opt/spectro/sovereign-r1/halt_supervisor.py")
die(){ echo "ERRO: $*" >&2; exit 1; }
need_root(){ [ "$SKIP" = 1 ] || [ "$(id -u)" = 0 ] || die "precisa de root"; }
latest(){ ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | tail -1; }

snapshot(){
  need_root
  for t in "${TARGETS[@]}"; do [ ! -e "$t" ] || die "destino ja existe (nao e instalacao limpa): $t"; done
  id spectro-probe >/dev/null 2>&1 && [ "$SKIP" != 1 ] && die "usuario spectro-probe ja existe"
  local d="$BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$d/files"; chmod 700 "$BACKUP_DIR" "$d" "$d/files"
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
  echo "$d" > "$BACKUP_DIR/LATEST"
  echo "SNAPSHOT_OK $d ($(wc -l < "$d/manifest.txt") entradas). Copias contem contas do sistema: NAO publicar."
}

verify(){
  local d; d="$(cat "$BACKUP_DIR/LATEST" 2>/dev/null)" || die "sem snapshot"
  ( cd "$d" && sha256sum -c SHA256SUMS >/dev/null ) || die "snapshot corrompido"
  # o host deve ainda bater com o manifesto (nada mudou desde o snapshot, exceto o que a transacao criou)
  while read -r st h p; do
    [ "$st" = PRESENT ] || continue
    [ "$(sha256sum < "$R$p" | cut -d' ' -f1)" = "$h" ] || echo "AVISO: mudou desde o snapshot: $p"
  done < "$d/manifest.txt"
  echo "VERIFY_OK $d"
}

install_(){
  need_root
  verify
  : "${TAILNET_IP:?TAILNET_IP obrigatorio}" "${PUBKEY_FILE:?PUBKEY_FILE obrigatorio}"
  # O gate le a copia minima publicada pelo relay (root), nunca o status.json original nem o espelho do Paperclip.
  STATUS_PATH="${STATUS_PATH:-/run/spectro-probe/status.json}"
  [[ "$TAILNET_IP" =~ ^100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || die "TAILNET_IP nao parece IP tailnet 100.x"
  [ "$(wc -l < "$PUBKEY_FILE")" -le 1 ] && grep -qE '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' "$PUBKEY_FILE" || die "PUBKEY_FILE deve ter UMA chave ssh-ed25519"
  [[ "$STATUS_PATH" = /* ]] || die "STATUS_PATH deve ser absoluto"
  local ETC="$R/etc" LIB="$R/usr/local/lib"
  if [ "$SKIP" != 1 ]; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /bin/sh --comment "SPECTRO probe R0" spectro-probe
    usermod -p '*' spectro-probe                     # sem senha, mas NAO bloqueada (sshd recusa contas com "!")
    gpasswd -d spectro-probe sudo >/dev/null 2>&1 || true
    ! id -nG spectro-probe | grep -qwE 'sudo|wheel|root|adm|docker' || die "spectro-probe em grupo privilegiado"
  fi
  install -d -m 0755 -o root -g root "$LIB/spectro" "$ETC/spectro"
  sed "s|^STATUS_PATH = None\$|STATUS_PATH = \"$STATUS_PATH\"|" "$HERE/../probe_gate.py" > "$LIB/spectro/probe_gate.py"
  grep -q "^STATUS_PATH = \"$STATUS_PATH\"\$" "$LIB/spectro/probe_gate.py" || die "falha ao fixar STATUS_PATH no gate"
  chown root:root "$LIB/spectro/probe_gate.py"; chmod 0644 "$LIB/spectro/probe_gate.py"
  { printf 'restrict,command="/usr/bin/python3 -I /usr/local/lib/spectro/probe_gate.py" '; cat "$PUBKEY_FILE"; } > "$ETC/spectro/probe_authorized_keys"
  chown root:root "$ETC/spectro/probe_authorized_keys"; chmod 0644 "$ETC/spectro/probe_authorized_keys"
  sed -e "s|@TAILNET_IP@|$TAILNET_IP|" "$HERE/sshd_probe_config" > "$ETC/spectro/sshd_probe_config"
  ! grep -q '@' "$ETC/spectro/sshd_probe_config" || die "placeholder sem substituir no sshd_probe_config"
  chown root:root "$ETC/spectro/sshd_probe_config"; chmod 0644 "$ETC/spectro/sshd_probe_config"
  if [ "$SKIP" != 1 ]; then
    ssh-keygen -q -t ed25519 -N '' -C spectro-probe-host -f "$ETC/spectro/probe_ssh_host_ed25519_key"
    chown root:root "$ETC/spectro/probe_ssh_host_ed25519_key"*; chmod 0600 "$ETC/spectro/probe_ssh_host_ed25519_key"
    /usr/sbin/sshd -t -f "$ETC/spectro/sshd_probe_config" || die "sshd -t falhou (nada iniciado)"
  fi
  install -m 0644 -o root -g root "$HERE/$UNIT" "$R/etc/systemd/system/$UNIT"
  install -m 0644 -o root -g root "$HERE/probe_status_relay.py" "$LIB/spectro/probe_status_relay.py"
  install -m 0644 -o root -g root "$HERE/$RELAY_UNIT" "$R/etc/systemd/system/$RELAY_UNIT"
  if [ "$SKIP" != 1 ]; then
    systemctl daemon-reload
    systemctl start "$RELAY_UNIT"          # SOMENTE o relay (le o status do supervisor e publica copia minima); o sshd NAO inicia
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$STATUS_PATH" ] && break; sleep 1; done
    runuser -u spectro-probe -- test -r "$STATUS_PATH" || die "spectro-probe nao le $STATUS_PATH (relay nao publicou; veja: journalctl -u $RELAY_UNIT). Rollback disponivel."
    runuser -u spectro-probe -- python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));print('STATUS_RELAY_OK',d['state'],d['kernel']['state'],'epoca',d['kernel']['epoch'])" "$STATUS_PATH" \
      || die "copia do status ilegivel pela sonda"
  fi
  echo "INSTALL_OK (relay do status ATIVO; sshd da sonda NAO habilitado e NAO iniciado; relay nao habilitado no boot)."
  [ "$SKIP" = 1 ] || { echo "Impressao digital da host key (pinar no known_hosts do Mac, por canal confiavel):"; ssh-keygen -lf "$ETC/spectro/probe_ssh_host_ed25519_key.pub"; }
  sha256sum "$LIB/spectro/probe_gate.py" "$ETC/spectro/sshd_probe_config" "$ETC/spectro/probe_authorized_keys" "$R/etc/systemd/system/$UNIT"
}

start_(){
  need_root
  [ "${I_CONFIRM_GATES_1_2_4:-}" = yes ] || die "defina I_CONFIRM_GATES_1_2_4=yes SO depois de: registro de grant (G1), HALT cancelando o cgroup (G2) e ACL Mac->VPS:2222 (G4)"
  grep -q 'spectro-probe-sshd' "$R/opt/spectro/sovereign-r1/sovereign_production.py" || die "supervisor nao conhece spectro-probe-sshd (HALT nao o pararia)"
  systemctl cat "$UNIT" >/dev/null
  systemctl start "$UNIT"; sleep 1
  systemctl is-active --quiet "$UNIT" || die "unidade nao ficou ativa"
  ss -ltn | grep -q ":2222 " && echo "START_OK :2222 escutando; porta 22 intacta"
}

rollback(){
  need_root
  local d; d="$(cat "$BACKUP_DIR/LATEST")"
  if [ "$SKIP" != 1 ]; then
    systemctl stop "$UNIT" 2>/dev/null || true
    systemctl disable "$UNIT" 2>/dev/null || true
    systemctl kill --kill-who=all --signal=SIGKILL "$UNIT" 2>/dev/null || true
    systemctl stop "$RELAY_UNIT" 2>/dev/null || true
    systemctl kill --kill-who=all --signal=SIGKILL "$RELAY_UNIT" 2>/dev/null || true
  fi
  rm -f -- "${RELAY_FILES[@]}"            # cobre snapshots tirados antes do relay existir
  # remove SOMENTE o que a transacao criou (todos constam como ABSENT no manifesto); nunca restaura bases de conta as cegas
  while read -r st h p; do
    [ "$st" = ABSENT ] || continue
    case "$p" in user:*) continue;; esac
    rm -f -- "$R$p"
  done < "$d/manifest.txt"
  rmdir "$R/usr/local/lib/spectro" 2>/dev/null || true
  [ "$SKIP" = 1 ] || { systemctl daemon-reload; id spectro-probe >/dev/null 2>&1 && userdel spectro-probe; true; }
  echo "ROLLBACK_OK (porta 22/ssh.service/tailscaled nao foram tocados). Conferir: $0 verify"
}

case "${1:-}" in
  snapshot) snapshot;; install) install_;; verify) verify;; start) start_;; rollback) rollback;;
  *) echo "uso: $0 snapshot|install|verify|start|rollback" >&2; exit 2;;
esac
