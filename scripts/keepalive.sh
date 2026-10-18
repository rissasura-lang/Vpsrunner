#!/usr/bin/env bash
# ============================================================================
#  keepalive.sh — jaga VPS tetap hidup sampai batas waktu, lalu:
#   * health-check sshd + tailscaled setiap menit
#   * heartbeat tiap 5 menit (sisa waktu, IP tailscale, listener 22)
#   * auto-checkpoint state tiap 15 menit
#   * HANDOVER / RENEWAL: sebelum waktu habis (default 20 menit), simpan state
#     lalu dispatch sesi berikutnya (vps-6h.yml) agar sesi baru sudah pulih
#     sebelum sesi ini berakhir — data & identitas Tailscale ikut dipindahkan.
#   * AUTO-STOP: berhenti sendiri 3 menit sebelum expires_at.
#
#  Env: GITHUB_TOKEN, GITHUB_REPOSITORY, DUR, VPS_HOST, VPS_USER,
#       RUNNER_IMAGE, PERPANJANG_OTOMATIS, HANDOVER_LEAD_MIN.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:keepalive'
. "$(dirname "$0")/lib-common.sh"

exp="$(json_get '.expires_at')"
if [ -z "$exp" ] || [ "$exp" = "null" ]; then
  exp="$(date -u -d '+335 minutes' +%Y-%m-%dT%H:%M:%SZ)"
fi
exp_epoch="$(date -u -d "$exp" +%s 2>/dev/null || echo 0)"
if [ "$exp_epoch" -le 0 ]; then exp_epoch=$(( $(date -u +%s) + 335*60 )); fi
lead="${HANDOVER_LEAD_MIN:-20}"

log "sesi aktif sampai $exp UTC (auto-checkpoint 15m, handover ${lead}m sebelum habis)"

dispatch_next() {
  [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  local body
  body="$(jq -n \
    --arg dur "${DUR:-360}" --arg host "${VPS_HOST:-vpsfree}" \
    --arg user "${VPS_USER:-vps}" --arg runner "${RUNNER_IMAGE:-ubuntu-24.04}" \
    --arg renew "${PERPANJANG_OTOMATIS:-ya}" \
    '{ref:"main",inputs:{durasi_menit:$dur,hostname:$host,vps_user:$user,
      runner:$runner,perpanjang_otomatis:$renew,renewal:"ya"}}')"
  curl -fsS -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: VpsFree' \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/vps-6h.yml/dispatches" \
    -d "$body" >/dev/null 2>&1
}

hdir="$(dirname "$0")"
stop_epoch=$(( exp_epoch - 180 ))   # auto-stop 3 menit sebelum expires_at
handed=0
i=0
while :; do
  now="$(date -u +%s)"
  [ "$now" -ge "$stop_epoch" ] && break
  sleep 60
  i=$((i+1))
  now="$(date -u +%s)"
  rem=$(( (exp_epoch - now) / 60 )); [ "$rem" -lt 0 ] && rem=0

  systemctl is-active --quiet ssh 2>/dev/null || sudo systemctl start ssh 2>/dev/null || true
  systemctl is-active --quiet tailscaled 2>/dev/null || sudo systemctl start tailscaled 2>/dev/null || true

  if [ $((i % 5)) -eq 0 ]; then
    tsip="$(sudo tailscale ip -4 2>/dev/null | head -1 || true)"
    ssh_ok="$(ss -ltn 2>/dev/null | grep -c ':22 ' || true)"
    log "detak #$i | sisa ${rem} menit | ssh=$ssh_ok | tailscale=$tsip"
    if [ -z "$tsip" ] && [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
      log 'Tailscale terputus — mencoba menyambung ulang...'
      sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" \
        --accept-dns=false --timeout=60s >/dev/null 2>&1 || true
    fi
  fi

  if [ $((i % 15)) -eq 0 ]; then
    log 'auto-checkpoint 15 menit...'
    "$hdir/persist-state.sh" --checkpoint || log 'checkpoint warning'
  fi

  if [ "$handed" -eq 0 ] && [ "${PERPANJANG_OTOMATIS:-ya}" != 'tidak' ] && [ "$rem" -le "$lead" ]; then
    handed=1
    log "handover: menyimpan state lalu menjadwalkan sesi berikutnya (sisa ${rem} menit)..."
    "$hdir/persist-state.sh" --checkpoint || true
    if dispatch_next; then
      update_status "$(jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{handover:{status:"dispatched",at:$t}}')" || true
      "$hdir/publish-status.sh" --active true >/dev/null 2>&1 || true
      touch /tmp/vps-handover-done 2>/dev/null || true
      log 'sesi berikutnya dijadwalkan (VPS lama tetap berjalan sampai batas waktu).'
    else
      update_status "$(jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{handover:{status:"failed",at:$t}}')" || true
      log 'handover gagal dijadwalkan (akan dicoba lagi oleh step estafet).'
      handed=0
    fi
  fi
done

log 'batas waktu tercapai — berhenti dengan aman, lanjut persist final + finalize.'
[ -f /tmp/vps-handover-done ] && exit 0
[ "${PERPANJANG_OTOMATIS:-ya}" = 'tidak' ] && exit 0
exit 0
