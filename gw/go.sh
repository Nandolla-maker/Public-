#!/bin/sh
# Atalho digitavel do gateway (perfil LEITURA). Uso: sh gw/go.sh [install|start|rollback|gupdate|tsnap|tinstall|tsetup|tstart|trollback]  (sem argumento: recon + snapshot/verify)
# Confere hashes de TODOS os arquivos, monta /root/gwbuild e chama gateway_install.sh. Nunca emite grant, nunca toca ssh/ACL/docker.
set -e
[ "$(id -u)" = 0 ] || { echo "ENTRE COMO ROOT"; exit 1; }
cd "$(dirname "$0")"
chk(){ [ "$(git hash-object "$1")" = "$2" ] || { echo "HASH DIFERENTE ($1), ABORTADO"; exit 1; }; }
chk gateway_core.py 8d7cf0ae442cd9f950fcc243283a827b6f98fbd9
chk gateway_server.py dacfff37d9483927ee100d54a0ae9cb672f12f06
chk local_runner.py 6b0db1c931564b33570e4259f93a3fe50d39af10
chk gateway_vps.py 05680ec0da033ef94cca14e4b4478aae149e1595
chk spectro-gateway-vps.service e31c284ec77ee2b83b26da912a91d11993752f98
chk gateway_install.sh 5d03d58ec8dcc731a377d14016f6ecb43afdc30a
chk tunnel_install.sh f5c73494000b4ecd0a4dd9f156b2a580c539db0f
chk spectro-tunnel.service 8735028d89b71211bd66a1a161451c471a264ca2
chk ../probe_gate.py 837c8d6a2912c5030fd21f4d8730f47fd8e3c96f
chk ../install/probe_status_relay.py 7d14b7944ad43d78d9faee5a9e68d1b4fb4c5ae6
chk ../install/spectro-probe-status-relay.service e15ec25bef305fa7dd948dfa2c889e0a3acb386c
B=/root/gwbuild
rm -rf "$B"; mkdir -p "$B"
cp gateway_core.py gateway_server.py local_runner.py gateway_vps.py spectro-gateway-vps.service gateway_install.sh tunnel_install.sh spectro-tunnel.service "$B"/
cp ../probe_gate.py ../install/probe_status_relay.py ../install/spectro-probe-status-relay.service "$B"/
chmod +x "$B/gateway_install.sh" "$B/tunnel_install.sh"
export OWNER_PUBKEY=esxP_KPMYLb7QP4kChZrecTKv_wIigCRXVt53VAPlgM
case "${1:-}" in
  install)  "$B/gateway_install.sh" verify && "$B/gateway_install.sh" install;;
  start)    "$B/gateway_install.sh" start;;
  rollback) "$B/gateway_install.sh" rollback;;
  gupdate)
    # troca SO gateway_vps.py (404 em JSON p/ descoberta OAuth do tunel). Exige /root/aprovo-gateway-atualizar. Guarda o antigo.
    [ -e /root/aprovo-gateway-atualizar ] || { echo "falta /root/aprovo-gateway-atualizar (so voce cria)"; exit 1; }
    D=/opt/spectro/gateway/gateway_vps.py; K=/var/backups/spectro-gateway-r0/gateway_vps.py.antes-$(date -u +%Y%m%dT%H%M%SZ)
    [ -f "$D" ] || { echo "gateway nao instalado"; exit 1; }
    cp -p "$D" "$K"; echo "BACKUP_OK $K"
    install -m 0644 -o root -g root gateway_vps.py "$D"
    systemctl restart spectro-gateway-vps.service; sleep 4
    systemctl is-active --quiet spectro-gateway-vps.service || { echo "GATEWAY NAO SUBIU. Voltando o antigo."; cp -p "$K" "$D"; systemctl restart spectro-gateway-vps.service; exit 1; }
    echo "GATEWAY_ATUALIZADO. Teste do 404 (esperado: 404 e JSON detail):"
    curl -s -o /dev/stdout -w ' HTTP=%{http_code}\n' http://127.0.0.1:18791/.well-known/oauth-protected-resource;;
  tsnap)    "$B/tunnel_install.sh" snapshot;;
  tinstall) "$B/tunnel_install.sh" verify && "$B/tunnel_install.sh" install;;
  tsetup)   "$B/tunnel_install.sh" setup;;
  tstart)   "$B/tunnel_install.sh" start;;
  trollback) "$B/tunnel_install.sh" rollback;;
  "")
    echo "== recon =="; hostname; ss -ltn | grep -E ':(22|18791) ' || true
    systemctl is-active spectro-sovereign-supervisor-r1.service || true
    id spectro-probe 2>&1 || true
    if [ -s /var/backups/spectro-gateway-r0/LATEST ]; then "$B/gateway_install.sh" verify; else "$B/gateway_install.sh" snapshot; fi
    echo "Proximo: crie /root/aprovo-gateway-instalar (so voce) e rode: sh gw/go.sh install";;
  *) echo "uso: sh gw/go.sh [install|start|rollback|gupdate|tsnap|tinstall|tsetup|tstart|trollback]"; exit 2;;
esac
