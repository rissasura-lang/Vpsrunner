#!/usr/bin/env bash
# ============================================================================
#  finalize-vps.sh — tutup akses sesi ini tanpa menyentuh state tersimpan.
#   * putuskan Tailscale (sesi ini) — tidak menghapus node di tailnet.
#   * TIDAK menghapus data /home atau Release state.
#  Status 'inactive' ditulis oleh step publish-status --active false.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:finalize'
. "$(dirname "$0")/lib-common.sh"

if command -v tailscale >/dev/null 2>&1; then
  sudo tailscale down >/dev/null 2>&1 || true
fi
log 'Sesi VPS dihentikan. State tersimpan tetap ada dan akan dipulihkan pada sesi berikutnya.'
exit 0
