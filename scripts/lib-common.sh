#!/usr/bin/env bash
# ============================================================================
#  lib-common.sh — helper bersama VpsFree (Ubuntu Server + Tailscale SSH).
#  Pakai dengan dot-source:
#
#      XY_TAG='VpsFree:akses'
#      . "$(dirname "$0")/lib-common.sh"
#
#  Menyediakan: logger, lokasi workspace, baca/tulis out/vps-status.json.
#  Tidak pernah menulis password ke status.
# ============================================================================

XY_TAG="${XY_TAG:-VpsFree}"

log()  { printf '[%s UTC][%s] %s\n' "$(date -u +%H:%M:%S)" "$XY_TAG" "$*"; }
redact() { printf '%s' "$1" | sed -E 's/(tskey-[A-Za-z0-9]+|ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)/[redacted]/g'; }

workspace() {
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then printf '%s' "$GITHUB_WORKSPACE"
  else ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd ); fi
}

status_path() { printf '%s/out/vps-status.json' "$(workspace)"; }

ensure_workspace_dirs() { mkdir -p "$(workspace)/out"; }

# Bangun/normalisasi hostname Tailscale dari input + nomor run.
vps_hostname() {
  local base
  base="$(printf '%s' "${VPS_HOST:-vpsfree}" | tr -cd 'a-zA-Z0-9-' | tr 'A-Z' 'a-z')"
  while [ "${base%-}" != "$base" ]; do base="${base%-}"; done
  [ -z "$base" ] && base="vpsfree"
  [ "${#base}" -gt 30 ] && base="${base:0:30}"
  printf '%s-%s' "$base" "${GITHUB_RUN_NUMBER:-local}"
}

read_status() {
  local p; p="$(status_path)"
  if [ -f "$p" ] && jq -e . "$p" >/dev/null 2>&1; then cat "$p"; else printf '{}'; fi
}

# update_status '<json-object>' — merge top-level (dan objek nested yang dikirim utuh).
update_status() {
  local patch="$1" p tmp
  p="$(status_path)"; ensure_workspace_dirs
  [ -f "$p" ] || printf '{}' > "$p"
  tmp="$(mktemp)"
  if printf '%s' "$patch" | jq -e . >/dev/null 2>&1 \
     && jq -s '.[0] * .[1]' "$p" <(printf '%s' "$patch") > "$tmp" 2>/dev/null; then
    mv "$tmp" "$p"
  else
    rm -f "$tmp"; log "update_status: patch JSON tidak valid — dilewati"; return 1
  fi
}

json_get() { read_status | jq -r "$1" 2>/dev/null; }
