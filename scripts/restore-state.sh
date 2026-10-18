#!/usr/bin/env bash
# ============================================================================
#  restore-state.sh — pulihkan state sesi sebelumnya (anti-reset).
#  Sumber (pilih terbaru):
#    1) Release tag 'vpsfree-state-latest' (asset vps-state.tar.gz)
#    2) Actions Artifact 'vpsfree-state' (fallback)
#  Memulihkan: home user, /etc/ssh/sshd_config.d, /var/lib/tailscale (IP 100.x).
#
#  Env: GITHUB_TOKEN, GITHUB_REPOSITORY, VPS_USER.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:restore'
. "$(dirname "$0")/lib-common.sh"

u="${VPS_USER:-vps}"
home="/home/$u"; [ "$u" = "root" ] && home="/root"
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  log 'GITHUB_TOKEN/repo tidak tersedia — lewati restore.'; exit 0
fi

api="https://api.github.com/repos/$GITHUB_REPOSITORY"
auth=(-H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json'
      -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: VpsFree')

work="$(mktemp -d)"; arc="$work/state.bin"; ext="$work/ext"; mkdir -p "$ext"

# ---------- kandidat Release ----------
rel_url=''; rel_ts=0; rel_mb=0
rel="$(curl -fsS "${auth[@]}" "$api/releases/tags/vpsfree-state-latest" 2>/dev/null || true)"
if [ -n "$rel" ]; then
  rel_url="$(printf '%s' "$rel" | jq -r '.assets[]? | select(.name=="vps-state.tar.gz") | .url' | head -1)"
  rel_ts="$(printf '%s' "$rel" | jq -r '.assets[]? | select(.name=="vps-state.tar.gz") | .updated_at' | head -1)"
  rel_ts="$(date -u -d "$rel_ts" +%s 2>/dev/null || echo 0)"
  rel_mb="$(printf '%s' "$rel" | jq -r '.assets[]? | select(.name=="vps-state.tar.gz") | .size' | head -1)"
fi

# ---------- kandidat Artifact ----------
art_url=''; art_ts=0; art_mb=0
arts="$(curl -fsS "${auth[@]}" "$api/actions/artifacts?name=vpsfree-state&per_page=5" 2>/dev/null || true)"
if [ -n "$arts" ]; then
  art_url="$(printf '%s' "$arts" | jq -r '[.artifacts[]? | select(.expired|not)] | sort_by(.created_at) | reverse | .[0].archive_download_url // empty')"
  a_created="$(printf '%s' "$arts" | jq -r '[.artifacts[]? | select(.expired|not)] | sort_by(.created_at) | reverse | .[0].created_at // empty')"
  [ -n "$a_created" ] && art_ts="$(date -u -d "$a_created" +%s 2>/dev/null || echo 0)"
  art_mb="$(printf '%s' "$arts" | jq -r '[.artifacts[]? | select(.expired|not)] | sort_by(.created_at) | reverse | .[0].size_in_bytes // 0')"
fi

got=0
case "$rel_mb" in ''|*[!0-9]*) rel_mb=0;; esac
case "$art_mb" in ''|*[!0-9]*) art_mb=0;; esac
if [ -n "$rel_url" ] && [ "$rel_ts" -ge "$art_ts" ]; then
  log "mengunduh state dari Release ($((rel_mb/1024/1024)) MB)..."
  if curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/octet-stream' \
      -H 'User-Agent: VpsFree' -o "$arc" "$rel_url" 2>/dev/null && [ -s "$arc" ]; then got=1; fi
fi
if [ "$got" -eq 0 ] && [ -n "$art_url" ]; then
  log "mengunduh state dari Artifact ($((art_mb/1024/1024)) MB)..."
  if curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H 'User-Agent: VpsFree' \
      -o "$arc" "$art_url" 2>/dev/null && [ -s "$arc" ]; then got=1; fi
fi
if [ "$got" -eq 0 ] && [ -n "$rel_url" ]; then
  curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/octet-stream' \
    -H 'User-Agent: VpsFree' -o "$arc" "$rel_url" 2>/dev/null && [ -s "$arc" ] && got=1
fi

if [ "$got" -eq 0 ]; then
  log 'belum ada simpanan sesi sebelumnya — sesi pertama.'; rm -rf "$work"; exit 0
fi

# Artifact = zip berisi vps-state.tar.gz; Release = tar.gz langsung.
if tar -tzf "$arc" >/dev/null 2>&1; then
  sudo tar -xzf "$arc" -C / --no-same-owner 2>/dev/null || true
else
  if command -v unzip >/dev/null 2>&1 && unzip -q -o "$arc" -d "$ext" 2>/dev/null; then
    inner="$ext/vps-state.tar.gz"
    [ -f "$inner" ] && sudo tar -xzf "$inner" -C / --no-same-owner 2>/dev/null || true
  fi
fi

if id -u "$u" >/dev/null 2>&1 && [ -d "$home" ]; then sudo chown -R "$u:$u" "$home" 2>/dev/null || true; fi
sudo chown -R root:root /var/lib/tailscale 2>/dev/null || true
sudo chmod 700 /var/lib/tailscale 2>/dev/null || true
sudo chmod 755 /etc/ssh/sshd_config.d 2>/dev/null || true

# Drop-in sshd dari arsip bisa berbeda dari yang divalidasi setup-vps: validasi ulang.
conf=/etc/ssh/sshd_config.d/99-vpsfree.conf
if [ -f "$conf" ]; then
  if ! sudo sshd -t 2>/dev/null; then
    log 'konfigurasi sshd hasil restore tidak valid — memakai konfigurasi aman bawaan.'
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPubkeyAuthentication yes\nUsePAM yes\n' | sudo tee "$conf" >/dev/null
  fi
  sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true
fi
rm -rf "$work"
log "restore selesai ke $home & /var/lib/tailscale."
exit 0
