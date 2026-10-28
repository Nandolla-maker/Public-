#!/bin/sh
# Atalho digitavel do gateway (perfil LEITURA). Uso: sh gw/go.sh [install|start|rollback]  (sem argumento: recon + snapshot/verify)
# Confere hashes de TODOS os arquivos, monta /root/gwbuild e chama gateway_install.sh. Nunca emite grant, nunca toca ssh/ACL/docker.
set -e
[ "$(id -u)" = 0 ] || { echo "ENTRE COMO ROOT"; exit 1; }
cd "$(dirname "$0")"
chk(){ [ "$(git hash-object "$1")" = "$2" ] || { echo "HASH DIFERENTE ($1), ABORTADO"; exit 1; }; }
chk gateway_core.py 8d7cf0ae442cd9f950fcc243283a827b6f98fbd9
chk gateway_server.py dacfff37d9483927ee100d54a0ae9cb672f12f06
chk local_runner.py 6b0db1c931564b33570e4259f93a3fe50d39af10
chk gateway_vps.py e7138464943d59af5587ae00c4859ae95c02a7e0
chk spectro-gateway-vps.service e31c284ec77ee2b83b26da912a91d11993752f98
chk gateway_install.sh 0c8516310fc4dbb43189ed9374475f4a002c21e1
chk ../probe_gate.py 837c8d6a2912c5030fd21f4d8730f47fd8e3c96f
chk ../install/probe_status_relay.py 7d14b7944ad43d78d9faee5a9e68d1b4fb4c5ae6
chk ../install/spectro-probe-status-relay.service e15ec25bef305fa7dd948dfa2c889e0a3acb386c
B=/root/gwbuild
rm -rf "$B"; mkdir -p "$B"
cp gateway_core.py gateway_server.py local_runner.py gateway_vps.py spectro-gateway-vps.service gateway_install.sh "$B"/
cp ../probe_gate.py ../install/probe_status_relay.py ../install/spectro-probe-status-relay.service "$B"/
chmod +x "$B/gateway_install.sh"
export OWNER_PUBKEY=esxP_KPMYLb7QP4kChZrecTKv_wIigCRXVt53VAPlgM
case "${1:-}" in
  install)  "$B/gateway_install.sh" verify && "$B/gateway_install.sh" install;;
  start)    "$B/gateway_install.sh" start;;
  rollback) "$B/gateway_install.sh" rollback;;
  "")
    echo "== recon =="; hostname; ss -ltn | grep -E ':(22|18791) ' || true
    systemctl is-active spectro-sovereign-supervisor-r1.service || true
    id spectro-probe 2>&1 || true
    if [ -s /var/backups/spectro-gateway-r0/LATEST ]; then "$B/gateway_install.sh" verify; else "$B/gateway_install.sh" snapshot; fi
    echo "Proximo: crie /root/aprovo-gateway-instalar (so voce) e rode: sh gw/go.sh install";;
  *) echo "uso: sh gw/go.sh [install|start|rollback]"; exit 2;;
esac
