#!/usr/bin/env bash
# ============================================================================
#  publish-status.sh — publikasikan out/vps-status.json ke branch `status`.
#   1) GitHub Contents API (Bearer GITHUB_TOKEN)   <- utama
#   2) fallback: git push + header Authorization    <- terbukti jalan
#  Verifikasi API mencocokkan run_id, run_attempt, active. Gagal = exit 1.
#  File TIDAK berisi password.
#
#  Pemakaian: publish-status.sh [--active true|false]  (default true)
#  Env: GITHUB_TOKEN, GITHUB_REPOSITORY, STATUS_BRANCH (default 'status').
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:status'
. "$(dirname "$0")/lib-common.sh"

ACTIVE_RAW='true'
while [ $# -gt 0 ]; do
  case "$1" in
    --active) ACTIVE_RAW="${2:-true}"; shift 2;;
    *) shift;;
  esac
done
case "$(printf '%s' "$ACTIVE_RAW" | tr 'A-Z' 'a-z')" in
  false|0|no|tidak|off|'') IS_ACTIVE=0;;
  *) IS_ACTIVE=1;;
esac

repo="${GITHUB_REPOSITORY:-}"
branch="${STATUS_BRANCH:-status}"
src="$(status_path)"
[ -f "$src" ] || { log "tidak ada $src — skip"; exit 0; }

# ---------- tulis ulang file lokal (aman untuk sesi mati) ----------
tmp="$(mktemp)"
if [ "$IS_ACTIVE" -eq 0 ]; then
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .active=false | .stopped_at=$t
    | .public_ip="" | .tailscale_ip="" | .tailscale_dns=""
    | (if .akses and .akses.tailscale then
         .akses.tailscale.status="offline"
         | .akses.tailscale.ip="" | .akses.tailscale.magicdns="" | .akses.tailscale.hostname=""
       else . end)
  ' "$src" > "$tmp" 2>/dev/null && mv "$tmp" "$src" || rm -f "$tmp"
  log 'status inactive: alamat SSH + Tailscale dibersihkan dari file publik'
fi

if [ -z "$repo" ] || [ -z "${GITHUB_TOKEN:-}" ]; then
  log 'GITHUB_TOKEN/repo tidak tersedia — hanya file lokal diperbarui.'; exit 0
fi

gh() { # gh METHOD PATH [BODY]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -fsS -X "$m" -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: VpsFree' -H 'Content-Type: application/json' \
      -d "$b" "https://api.github.com$p"
  else
    curl -fsS -X "$m" -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: VpsFree' "https://api.github.com$p"
  fi
}

verify_api() {
  local c t
  c="$(gh GET "/repos/$repo/contents/vps-status.json?ref=$branch" 2>/dev/null)" || return 1
  t="$(printf '%s' "$c" | jq -r '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null)" || return 1
  printf '%s' "$t" | jq -e --arg rid "${GITHUB_RUN_ID:-}" --arg att "$(jq -r '.run_attempt // empty' "$src")" \
    --argjson act "$([ "$IS_ACTIVE" -eq 1 ] && echo true || echo false)" \
    '(.run_id|tostring)==$rid and ((.run_attempt//"")|tostring)==$att and .active==$act' >/dev/null 2>&1
}

# ---------- cara 1: Contents API ----------
if ! gh GET "/repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  db="$(gh GET "/repos/$repo" | jq -r '.default_branch')"
  sha0="$(gh GET "/repos/$repo/git/ref/heads/$db" | jq -r '.object.sha')"
  gh POST "/repos/$repo/git/refs" "$(jq -n --arg b "$branch" --arg s "$sha0" '{ref:("refs/heads/"+$b),sha:$s}')" \
    >/dev/null 2>&1 && log "branch '$branch' dibuat (via API)"
fi

b64="$(base64 -w0 "$src" 2>/dev/null || base64 "$src" | tr -d '\n')"
for remote in vps-status.json out/vps-status.json; do
  sha="$(gh GET "/repos/$repo/contents/$remote?ref=$branch" 2>/dev/null | jq -r '.sha // empty')"
  body="$(jq -n --arg m "VpsFree status update (run ${GITHUB_RUN_NUMBER:-})" \
    --arg c "$b64" --arg b "$branch" --arg s "$sha" \
    '{message:$m,content:$c,branch:$b} + (if $s=="" then {} else {sha:$s} end)')"
  if gh PUT "/repos/$repo/contents/$remote" "$body" | jq -e '.content' >/dev/null 2>&1; then
    log "Contents API OK ($remote)"
  elif [ "$remote" = 'vps-status.json' ]; then
    log 'PUT contents gagal — lanjut fallback git'
  fi
done

# ---------- verifikasi / fallback ----------
if verify_api; then
  log 'OK — status run/attempt/active terverifikasi via API.'; exit 0
fi

log 'verifikasi belum lolos — coba fallback git push...'
tdir="$(mktemp -d)"
(
  cd "$tdir" && git init -q -b "$branch" && \
  cp "$src" vps-status.json && mkdir -p out && cp "$src" out/vps-status.json && \
  git config user.name 'github-actions[bot]' && \
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com' && \
  git add vps-status.json out/vps-status.json && \
  git -c commit.gpgsign=false commit -q -m 'VpsFree status update' && \
  git -c "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN" push --force \
      "https://github.com/$repo.git" "HEAD:refs/heads/$branch"
) 2>&1 | while IFS= read -r l; do log "git: $l"; done
rm -rf "$tdir"

if verify_api; then
  log 'OK — status terverifikasi setelah git push.'; exit 0
fi
log 'Gagal mempublikasikan status. Periksa izin Contents write workflow.'; exit 1
