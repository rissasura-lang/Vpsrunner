#!/usr/bin/env bash
# ============================================================================
#  setup-akses.sh — akses privat via Tailscale (satu-satunya jalur).
#   1) pasang tailscale resmi (install.sh) bila belum ada
#   2) tailscale up dengan auth key + hostname tetap
#   3) tunggu IP 100.x, batasi SSH hanya dari tailnet
#   4) catat IP/DNS Tailscale ke out/vps-status.json
#
#  Env: TAILSCALE_AUTH_KEY (wajib), VPS_HOST, GITHUB_RUN_NUMBER.
#  Opsional: TAILSCALE_INSTALL_ONLY=1 untuk validasi tanpa auth key.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:akses'
. "$(dirname "$0")/lib-common.sh"

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then return 0; fi
  log 'memasang Tailscale (paket resmi)...'
  if ! curl -fsSL --connect-timeout 15 --max-time 120 https://tailscale.com/install.sh | sudo sh; then
    log 'ERROR: unduhan/instalasi Tailscale gagal.'; return 1
  fi
  command -v tailscale >/dev/null 2>&1
}

if ! install_tailscale; then
  update_status "$(jq -n '{akses:{mode:"tailscale",tailscale:{status:"failed",note:"install gagal"}}}')" || true
  exit 1
fi
sudo systemctl enable --now tailscaled >/dev/null 2>&1 || true

if [ "${TAILSCALE_INSTALL_ONLY:-0}" = "1" ]; then
  sudo tailscale version && log 'validasi install-only OK.'; exit 0
fi

if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  log 'ERROR: secret TAILSCALE_AUTH_KEY belum di-set.'
  update_status "$(jq -n '{akses:{mode:"tailscale",tailscale:{status:"failed",note:"auth key kosong"}}}')" || true
  exit 1
fi

HOST_NAME="$(json_get '.hostname')"; [ "$HOST_NAME" = "null" ] || [ -z "$HOST_NAME" ] && HOST_NAME="$(vps_hostname)"

up_args=(--authkey="$TAILSCALE_AUTH_KEY" --accept-dns=false --timeout=90s)
if sudo tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null 2>&1; then
  log 'state Tailscale dipulihkan — nama node & IP dipertahankan.'
else
  up_args+=(--hostname="$HOST_NAME")
  log "menghubungkan ke tailnet sebagai '$HOST_NAME'..."
fi

if ! sudo tailscale up "${up_args[@]}"; then
  log 'ERROR: Tailscale menolak koneksi. Periksa masa berlaku auth key & persetujuan perangkat.'
  update_status "$(jq -n '{akses:{mode:"tailscale",tailscale:{status:"failed",note:"up ditolak"}}}')" || true
  exit 1
fi

TS_IP=''
for _ in $(seq 1 30); do
  TS_IP="$(sudo tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$TS_IP" ] && break
  sleep 3
done
BACKEND="$(sudo tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')"
TS_DNS="$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"

if [ "$BACKEND" != 'Running' ] || [ -z "$TS_IP" ]; then
  log 'ERROR: Tailscale belum siap atau belum disetujui pemilik tailnet.'
  update_status "$(jq -n --arg b "$BACKEND" '{akses:{mode:"tailscale",tailscale:{status:"failed",note:("backend="+$b)}}}')" || true
  exit 1
fi

# SSH hanya dari ruang alamat tailnet.
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow in on tailscale0 >/dev/null 2>&1 || true
  sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp >/dev/null 2>&1 || true
fi

PUBLIC_IP="$(curl -fsS --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null || echo '')"

update_status "$(jq -n \
  --arg ip "$TS_IP" --arg dns "$TS_DNS" --arg host "$HOST_NAME" --arg pub "$PUBLIC_IP" \
  '{tailscale_ip:$ip, tailscale_dns:$dns, public_ip:$pub,
    akses:{mode:"tailscale", tailscale:{status:"ok", ip:$ip, magicdns:$dns, hostname:$host,
      note:"HP/PC harus login Tailscale pada tailnet yang sama lalu SSH ke user@ip -p 22."}}}')"

log "Tailscale siap: ssh ${VPS_USER:-vps}@$TS_IP -p 22 (tanpa akses publik)."
exit 0
