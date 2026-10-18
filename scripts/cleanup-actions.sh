#!/usr/bin/env bash
# ============================================================================
#  cleanup-actions.sh — rapikan jejak Actions:
#    1) hapus run LAMA dari workflow ini (termasuk log-nya) supaya repo rapi
#       dan IP/log sesi lama tidak mengendap. Simpan KEEP_RUNS run terbaru.
#    2) butuh token repo: pakai secret CLEANUP_TOKEN (PAT) bila ada,
#       fallback ke GITHUB_TOKEN.
#
#  Env: CLEANUP_TOKEN, GITHUB_TOKEN, GITHUB_REPOSITORY, GH_WORKFLOW,
#       KEEP_RUNS (default 3).
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:bersih'
. "$(dirname "$0")/lib-common.sh"

repo="${GITHUB_REPOSITORY:-}"
wf="${GH_WORKFLOW:-vps-6h.yml}"
keep="${KEEP_RUNS:-3}"; keep="${keep//[^0-9]/}"; [ "${keep:-0}" -lt 1 ] && keep=3
tok="${CLEANUP_TOKEN:-${GITHUB_TOKEN:-}}"

if [ -z "$repo" ] || [ -z "$tok" ]; then log 'repo/token tidak diketahui — skip'; exit 0; fi

api() { curl -fsS -H "Authorization: Bearer $tok" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: VpsFree' "$@"; }

log "bersih-bersih run lama (simpan $keep terbaru)..."
runs="$(api "https://api.github.com/repos/$repo/actions/workflows/$wf/runs?per_page=100" 2>/dev/null)" || {
  log 'tidak bisa membaca daftar run — skip'; exit 0; }

count="$(printf '%s' "$runs" | jq '.workflow_runs | length' 2>/dev/null)"; count="${count:-0}"
log "  total run terlihat: $count"
if [ "$count" -le "$keep" ]; then log '  tidak ada yang perlu dihapus'; exit 0; fi

n=0
while IFS= read -r row; do
  id="$(printf '%s' "$row" | jq -r '.id')"
  num="$(printf '%s' "$row" | jq -r '.run_number')"
  status="$(printf '%s' "$row" | jq -r '.status')"
  # jangan hapus run yang sedang berjalan (termasuk diri sendiri)
  [ "$status" = 'in_progress' ] && continue
  [ "$status" = 'queued' ] && continue
  if api -X DELETE "https://api.github.com/repos/$repo/actions/runs/$id" >/dev/null 2>&1; then
    n=$((n+1)); log "  run #$num ($id) dihapus"
  else
    log "  hapus run #$num gagal"
  fi
done < <(printf '%s' "$runs" | jq -c ".workflow_runs[$keep:][]")
log "  selesai: $n run lama dihapus"
exit 0
