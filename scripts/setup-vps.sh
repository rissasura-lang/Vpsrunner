#!/usr/bin/env bash
# ============================================================================
#  setup-vps.sh — MODE DASAR VpsFree (Ubuntu Server).
#   1) set password superuser/root dari secret VPS_PASSWORD
#   2) buat user sudo (default: vps) dengan password yang sama
#   3) aktifkan SSH password + root login (akses tetap lewat Tailscale)
#   4) tulis identitas sesi ke out/vps-status.json (tanpa password)
#
#  Port 22 di VM GitHub-hosted tidak punya inbound publik; hanya ditembus
#  lewat Tailscale. Script dijalankan sebagai user runner, pakai sudo.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:base'
. "$(dirname "$0")/lib-common.sh"

if [ -z "${VPS_PASSWORD:-}" ] || [ "${#VPS_PASSWORD}" -lt 8 ]; then
  log 'ERROR: secret VPS_PASSWORD belum di-set / terlalu pendek (min 8 karakter).'; exit 1
fi
case "$VPS_PASSWORD" in
  *$'\n'*|*$'\r'*) log 'ERROR: VPS_PASSWORD tidak boleh mengandung baris baru.'; exit 1;;
esac

# ---------- durasi (menit) ----------
DUR="${DUR:-360}"; DUR="${DUR//[^0-9]/}"; [ -z "$DUR" ] && DUR=342
[ "$DUR" -lt 10 ] && DUR=342
[ "$DUR" -gt 342 ] && DUR=342   # margin aman di bawah timeout workflow 360

# ---------- user ----------
VPS_USER="${VPS_USER:-vps}"
if ! printf '%s' "$VPS_USER" | grep -Eq '^[a-z_][a-z0-9_-]{1,31}$'; then
  log "ERROR: VPS_USER tidak valid (huruf kecil/angka, _ atau -, 2-32 karakter)."; exit 1
fi
case "$VPS_USER" in
  daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|_apt|nobody|systemd-network|sshd) 
    log "ERROR: VPS_USER '$VPS_USER' adalah nama sistem; pilih nama lain."; exit 1;;
esac

HOST_NAME="$(vps_hostname)"
. /etc/os-release 2>/dev/null || true
OS_NAME="${PRETTY_NAME:-Ubuntu}"
KERNEL="$(uname -r)"
CPU="$(nproc 2>/dev/null || echo 0)"
RAM_GB="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null)"; [ -z "$RAM_GB" ] && RAM_GB=0
DISK_FREE_GB="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"; [ -z "$DISK_FREE_GB" ] && DISK_FREE_GB=0

log "mode dasar | hostname $HOST_NAME | durasi $DUR menit | user $VPS_USER | OS $OS_NAME ($KERNEL)"

# ---------- paket dasar ----------
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq curl
fi
sudo systemctl enable --now ssh >/dev/null 2>&1 || sudo systemctl enable --now sshd >/dev/null 2>&1 || true

# ---------- password superuser / root ----------
printf 'root:%s\n' "$VPS_PASSWORD" | sudo chpasswd
log 'password root diset dari VPS_PASSWORD (tidak ditampilkan).'

# ---------- user sudo ----------
if [ "$VPS_USER" != "root" ]; then
  if ! id -u "$VPS_USER" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "$VPS_USER"
  fi
  printf '%s:%s\n' "$VPS_USER" "$VPS_PASSWORD" | sudo chpasswd
  sudo usermod -aG sudo "$VPS_USER" 2>/dev/null || true
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$VPS_USER" | sudo tee /etc/sudoers.d/90-vpsfree >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-vpsfree
  log "user sudo '$VPS_USER' siap (password sama, NOPASSWD sudo)."
fi

# ---------- sshd: password + root login ----------
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-vpsfree.conf >/dev/null <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

if ! sudo sshd -t 2>/dev/null; then
  log 'ERROR: konfigurasi sshd tidak valid setelah drop-in.'
  sudo rm -f /etc/ssh/sshd_config.d/99-vpsfree.conf
fi
sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true

# Verifikasi nilai EFEKTIF (main sshd_config bisa menimpa Include).
EFF_ROOT="$(sudo sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')"
EFF_PW="$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
if [ "$EFF_ROOT" != 'yes' ] || [ "$EFF_PW" != 'yes' ]; then
  log "menimpa langsung di sshd_config (root='$EFF_ROOT', password='$EFF_PW')..."
  printf '\nPermitRootLogin yes\nPasswordAuthentication yes\n' | sudo tee -a /etc/ssh/sshd_config >/dev/null
  if sudo sshd -t 2>/dev/null; then
    sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true
  else
    log 'ERROR: sshd_config tetap tidak valid — periksa manual.'
  fi
  EFF_ROOT="$(sudo sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')"
  EFF_PW="$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
fi

if ss -ltn 2>/dev/null | grep -q ':22 '; then
  SSH_LISTEN='ok'
else
  SSH_LISTEN='belum terdeteksi'
fi
log "sshd port 22: $SSH_LISTEN | PermitRootLogin=$EFF_ROOT PasswordAuthentication=$EFF_PW"
if [ "$EFF_ROOT" != 'yes' ] || [ "$EFF_PW" != 'yes' ]; then
  log 'PERINGATAN: login root/password belum aktif sesuai konfigurasi efektif.'
fi

# ---------- firewall: hanya tailnet boleh SSH (best-effort) ----------
if ! command -v ufw >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || true
fi
if command -v ufw >/dev/null 2>&1; then
  sudo ufw --force reset >/dev/null 2>&1 || true
  sudo ufw default deny incoming >/dev/null 2>&1 || true
  sudo ufw default allow outgoing >/dev/null 2>&1 || true
  sudo ufw allow in on tailscale0 >/dev/null 2>&1 || true
  sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp >/dev/null 2>&1 || true
  sudo ufw --force enable >/dev/null 2>&1 || true
  log 'ufw aktif: inbound ditolak kecuali via tailscale0 / 100.64.0.0/10 ke port 22.'
fi

# ---------- status awal (tanpa password) ----------
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES="$(date -u -d "+${DUR} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"${DUR}"M +%Y-%m-%dT%H:%M:%SZ)"
update_status "$(jq -n \
  --arg host "$HOST_NAME" --arg os "$OS_NAME" --arg kernel "$KERNEL" \
  --argjson cpu "$CPU" --argjson ram "$RAM_GB" --argjson disk "$DISK_FREE_GB" \
  --arg user "$VPS_USER" --arg listen "$SSH_LISTEN" \
  --arg started "$NOW" --arg expires "$EXPIRES" --argjson dur "$DUR" \
  --arg runid "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg number "${GITHUB_RUN_NUMBER:-}" \
  --arg url "https://github.com/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  --arg renewal "${RENEWAL:-tidak}" \
  '{active:true, hostname:$host, os:$os, kernel:$kernel,
    cpu_threads:$cpu, ram_gb:$ram, disk_free_gb:$disk,
    ssh_port:22, ssh_user:$user, ssh_listen:$listen,
    public_ip:"", tailscale_ip:"", tailscale_dns:"",
    started_at:$started, expires_at:$expires, duration_menit:$dur,
    run_id:$runid, run_attempt:$attempt, run_number:$number, run_url:$url,
    mode:"vpsfree", renewal:$renewal,
    akses:{mode:"tailscale", tailscale:{status:"pending"}}}')"

{
  printf '### VpsFree\n\n'
  printf '| field | nilai |\n|---|---|\n'
  printf '| hostname | %s |\n| OS | %s |\n| kernel | %s |\n| user | %s |\n| SSH | %s:22 |\n| mulai | %s |\n| berakhir | %s |\n' \
    "$HOST_NAME" "$OS_NAME" "$KERNEL" "$VPS_USER" "$HOST_NAME" "$NOW" "$EXPIRES"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true

log "SESI DASAR SIAP — user $VPS_USER, SSH port 22. Lanjut: setup Tailscale."
exit 0
