"""Adaptador MCP fino do gateway SPECTRO R0.3 (candidato, NAO instalado).

Anuncia EXATAMENTE as ferramentas do perfil fixo (hoje: `vps_probe`). Nao ha caminho de despacho
fora de Gateway.call; shell_run/shell_start/fastpath_readonly nao existem neste processo.
Cada chamada carrega o grant assinado no argumento `grant` (token emitido pela cerimonia do dono).
Transporte real para a VPS NAO esta resolvido aqui: o default_runner do vps_probe usa `tailscale ssh`
com conta nologin e NAO funciona; injete um runner aprovado (B1).
"""
import json, os, sys, time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
import gateway_core as g

PROFILE_NAMES = ("vps_probe",)


def load_pubkey(path):
    """Arquivo com a chave publica Ed25519 em base64url (43 chars). Sem seguir symlink; so leitura."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        raw = os.read(fd, 256).decode().strip()
    finally:
        os.close(fd)
    key = g.b64d(raw)
    if len(key) != 32:
        raise ValueError("chave publica invalida")
    return Ed25519PublicKey.from_public_bytes(key)


def build_profile(probe_fn):
    def _vps_probe(args):
        if set(args) != {"probe"} or not isinstance(args["probe"], str):
            raise ValueError("args")
        return json.dumps(probe_fn(args["probe"]), sort_keys=True)
    return {"vps_probe": _vps_probe}


def build_gateway(*, pub, aud, state_dir, epoch_fn, probe_fn):
    return g.Gateway(build_profile(probe_fn), pub=pub, aud=aud, state_dir=state_dir, epoch_fn=epoch_fn)


def build_mcp(gw):
    try:                                   # SDK 1.x
        from mcp.server.fastmcp import FastMCP as _Server
    except ImportError:                    # SDK 2.x (FastMCP renomeado)
        from mcp.server.mcpserver import MCPServer as _Server
    mcp = _Server("spectro-gateway")

    @mcp.tool(name="vps_probe", description="Sonda somente leitura da VPS (identity, tunnel_unit, tunnel_key_present, uptime, halt_flags). Exige grant assinado do dono.")
    def vps_probe(probe: str, grant: str) -> str:
        return json.dumps(gw.call("vps_probe", {"probe": probe}, grant), sort_keys=True)

    return mcp


def main(argv):
    """uso: gateway_server.py PUBKEY_FILE AUD STATE_DIR STATUS_JSON  (stdio). Requer SPECTRO_CMD_VPS_PROBE=1."""
    if len(argv) != 5:
        print(main.__doc__, file=sys.stderr)
        return 2
    _, pubf, aud, state, status = argv
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vps-probe-r0"))
    import vps_probe_candidate as vp
    gw = build_gateway(pub=load_pubkey(pubf), aud=aud, state_dir=state,
                       epoch_fn=lambda: g.epoch_from_status(status, time.time()), probe_fn=vp.vps_probe)
    build_mcp(gw).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
