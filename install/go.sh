#!/bin/sh
# Atalho digitavel. Sem chave publica: so recon + (se ainda nao existir) snapshot. Com /root/probe_key.pub: instala
# (conta sem sudo, gate, sshd separado DESLIGADO, relay do status LIGADO). NUNCA inicia o sshd da sonda.
set -e
[ "$(id -u)" = 0 ] || { echo "ENTRE COMO ROOT"; exit 1; }
cd "$(dirname "$0")"
[ "$(git hash-object probe_install.sh)" = 6bd51d40597e0593ff5fdbc850f10571dbe47405 ] || { echo "HASH DIFERENTE (probe_install.sh), ABORTADO"; exit 1; }
[ "$(git hash-object probe_status_relay.py)" = 7d14b7944ad43d78d9faee5a9e68d1b4fb4c5ae6 ] || { echo "HASH DIFERENTE (relay), ABORTADO"; exit 1; }
[ "$(git hash-object ../probe_gate.py)" = 837c8d6a2912c5030fd21f4d8730f47fd8e3c96f ] || { echo "HASH DIFERENTE (gate), ABORTADO"; exit 1; }
echo "== recon =="; hostname; tailscale ip -4; ss -ltn | grep -E ':(22|2222) ' || true
systemctl is-active spectro-sovereign-supervisor-r1.service || true
id spectro-probe 2>&1 || true
chmod +x probe_install.sh
if [ -s /var/backups/spectro-probe-r0/LATEST ]; then
  echo "snapshot ja existe: $(cat /var/backups/spectro-probe-r0/LATEST)"; ./probe_install.sh verify
else
  ./probe_install.sh snapshot
fi
if [ -s /root/probe_key.pub ]; then
  TAILNET_IP=$(tailscale ip -4 | head -1) PUBKEY_FILE=/root/probe_key.pub ./probe_install.sh install
  ./probe_install.sh verify
else
  echo "Falta /root/probe_key.pub (chave publica do Mac). Instalacao NAO feita."
fi
