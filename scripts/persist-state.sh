#!/usr/bin/env bash
# ============================================================================
#  persist-state.sh — simpan state VPS lintas sesi (anti-reset).
#  Disimpan: home user (Desktop/Documents/Downloads/.ssh/.config/projects),
#            /etc/ssh/sshd_config.d, /var/lib/tailscale (IP 100.x tetap),
#            /opt/vpsfree bila ada.
#  Tujuan: GitHub Release tag 'vpsfree-state-latest' (asset vps-state.tar.gz)
#          agar tahan terhadap cleanup-actions.sh.
#
#  Pemakaian: persist-state.sh [--checkpoint]
#  Env: GITHUB_TOKEN, GITHUB_REPOSITORY, VPS_USER.
# ============================================================================
set -uo pipefail
XY_TAG='VpsFree:persist'
. "$(dirname "$0")/lib-common.sh"

CHECKPOINT=0; [ "${1:-}" = "--checkpoint" ] && CHECKPOINT=1
[ "$CHECKPOINT" -eq 1 ] && export XY_TAG='VpsFree:checkpoint'

u="${VPS_USER:-vps}"
home="/home/$u"; [ "$u" = "root" ] && home="/root"
out="$(workspace)/out"; mkdir -p "$out"
arc="$out/vps-state.tar.gz"; tmp="$arc.tmp"

paths=()
[ -d "$home" ] && paths+=("$home")
[ -d /etc/ssh/sshd_config.d ] && paths+=("/etc/ssh/sshd_config.d")
[ -d /var/lib/tailscale ] && paths+=("/var/lib/tailscale")
[ -d /opt/vpsfree ] && paths+=("/opt/vpsfree")

if [ "${#paths[@]}" -eq 0 ]; then log 'tidak ada path untuk disimpan.'; exit 0; fi

excludes=(
  --exclude='*/cache/*' --exclude='*/.cache/*' --exclude='*/node_modules/*'
  --exclude='*/.npm/_cacache/*' --exclude='*/.local/share/Trash/*'
  --exclude='*.iso' --exclude='*.img' --exclude='*.vmdk' --exclude='*.tmp'
  --exclude='*/snap/*' --exclude='*/go/pkg/mod/*' --exclude='*/.cargo/registry/*'
  --exclude='*/vps-state.tar.gz*'
)
# Jangan pernah mengemas workspace runner / arsip state itu sendiri (rekursi).
if [ -n "${GITHUB_WORKSPACE:-}" ]; then excludes+=(--exclude="$GITHUB_WORKSPACE"); fi

log "mengemas state (${paths[*]})..."
sudo tar "${excludes[@]}" -cf - "${paths[@]}" 2>/dev/null | gzip -1 > "$tmp"
tar_rc=("${PIPESTATUS[@]}")
if [ "${tar_rc[0]}" -le 1 ] && [ "${tar_rc[1]}" -eq 0 ]; then
  mv "$tmp" "$arc"
else
  rm -f "$tmp"; log 'gagal mengemas state.'; exit 0
fi
[ -f "$arc" ] || { log 'arsip tidak terbentuk.'; exit 0; }

bytes="$(stat -c%s "$arc" 2>/dev/null || echo 0)"
if [ "$bytes" -gt 1900000000 ]; then
  log "arsip terlalu besar ($((bytes/1024/1024)) MB) — dilewati."; exit 0
fi
log "state dikemas: $((bytes/1024/1024)) MB -> vps-state.tar.gz"

if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  log 'token/repo tidak tersedia — arsip lokal saja (akan di-upload sebagai artifact).'; exit 0
fi

api="https://api.github.com/repos/$GITHUB_REPOSITORY"
tag='vpsfree-state-latest'
auth=(-H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json'
      -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: VpsFree')

rel="$(curl -fsS "${auth[@]}" "$api/releases/tags/$tag" 2>/dev/null || true)"
rel_id="$(printf '%s' "$rel" | jq -r '.id // empty' 2>/dev/null)"
if [ -z "$rel_id" ]; then
  rel="$(curl -fsS -X POST "${auth[@]}" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$tag" '{tag_name:$t,name:"VpsFree Persistent State (Auto-Save)",draft:false,prerelease:true,body:"Arsip otomatis data sesi VpsFree lintas sesi. Jangan dihapus bila ingin data tetap tersimpan."}')" \
    "$api/releases" 2>/dev/null || true)"
  rel_id="$(printf '%s' "$rel" | jq -r '.id // empty' 2>/dev/null)"
fi
if [ -z "$rel_id" ]; then log 'gagal membuat/menemukan Release — dilewati.'; exit 0; fi

# hapus SEMUA asset lama dengan nama sama (hindari duplikat dari upload yang gagal)
old_ids="$(printf '%s' "$rel" | jq -r '.assets[]? | select(.name=="vps-state.tar.gz") | .id' 2>/dev/null)"
for aid in $old_ids; do
  [ -n "$aid" ] && curl -fsS -X DELETE "${auth[@]}" "$api/releases/assets/$aid" >/dev/null 2>&1 || true
done

upload="$(printf '%s' "$rel" | jq -r '.upload_url // empty' | sed 's/{?name,label}//')"
if [ -z "$upload" ]; then log 'upload_url tidak tersedia — dilewati.'; exit 0; fi

if curl -fsS -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Content-Type: application/gzip' \
  -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: VpsFree' \
  --data-binary @"$arc" "${upload}?name=vps-state.tar.gz" >/dev/null 2>&1; then
  log "state tersimpan ke Release '$tag'."
else
  log "upload ke Release '$tag' gagal — artifact tetap disediakan."
fi
exit 0
