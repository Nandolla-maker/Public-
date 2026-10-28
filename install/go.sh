#!/bin/sh
# Atalho digitavel: recon (leitura) + snapshot. Instala so se /root/probe_key.pub existir. NUNCA inicia o servico.
set -e
[ "$(id -u)" = 0 ] || { echo "ENTRE COMO ROOT"; exit 1; }
cd "$(dirname "$0")"
[ "$(git hash-object probe_install.sh)" = 02eb4136825cbee00fa9b3ee89808f8e037f4d09 ] || { echo "HASH DIFERENTE, ABORTADO"; exit 1; }
SP=/srv/paperclip/data/spectro-sovereign-r1/status.json
echo "== recon =="; hostname; tailscale ip -4; ls -l $SP; ss -ltn | grep -E ':(22|2222) ' || true
systemctl is-active spectro-sovereign-supervisor-r1.service || true
id spectro-probe 2>&1 || true
chmod +x probe_install.sh
./probe_install.sh snapshot
if [ -s /root/probe_key.pub ]; then
  TAILNET_IP=$(tailscale ip -4 | head -1) PUBKEY_FILE=/root/probe_key.pub STATUS_PATH=$SP ./probe_install.sh install
  ./probe_install.sh verify
else
  echo "SNAPSHOT OK. Falta /root/probe_key.pub (chave publica do Mac). Instalacao NAO feita."
fi
