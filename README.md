# VpsFree

VPS **Ubuntu Server** yang dijalankan oleh **GitHub Actions** dan diakses lewat **SSH melalui Tailscale privat**. Tidak ada RDP, tidak ada tunnel publik (Pinggy/bore/ngrok/Serveo/localhost.run/Funnel), tidak ada relay publik.

Kredit asli: **KallAncrit**. Template: `xykal/XyRDP`.

---

## 1. Cara kerja singkat

Setiap kali workflow dijalankan, GitHub menyiapkan satu mesin Ubuntu Server sementara (ephemeral):

1. `setup-vps.sh` menyetel password **root** dan user sudo dari secret `VPS_PASSWORD`, serta mengaktifkan SSH (password + root login).
2. `restore-state.sh` memulihkan data sesi sebelumnya (home, konfigurasi SSH, identitas Tailscale).
3. `setup-akses.sh` memasang Tailscale dan menyambung ke tailnet-mu. Hanya alamat tailnet `100.64.0.0/10` yang boleh masuk SSH port 22.
4. `publish-status.sh` menulis status sesi ke branch `status` (`vps-status.json`).
5. `keepalive.sh` menjaga mesin tetap hidup, menyimpan state tiap 15 menit, menjadwalkan sesi berikutnya sebelum waktu habis, lalu menghentikan diri sendiri 3 menit sebelum batas waktu.

Karena runner GitHub ephemeral, **data tidak hidup di mesin** — data dipindahkan antar sesi lewat state yang disimpan dan dipulihkan.

---

## 2. Prasyarat

- Repository dibuat dari template (`Use this template` di GitHub).
- Tailnet Tailscale dan sebuah **auth key** (`tskey-auth-...`).
- Klien Tailscale di perangkat yang dipakai (HP/PC), login ke tailnet yang sama.
- Actions diizinkan pada repository (repo pribadi biasanya sudah aktif; organisasi mungkin perlu mengaktifkan).

---

## 3. Secrets (wajib)

Buka **Settings → Secrets and variables → Actions → New repository secret**, isi:

| Secret | Isi |
|---|---|
| `VPS_PASSWORD` | Password untuk **root** sekaligus user sudo. Minimal 8 karakter, buat yang kuat dan unik. |
| `TAILSCALE_AUTH_KEY` | Auth key Tailscale (`tskey-auth-...`). Jangan dibagikan. |

Opsional:
- `CLEANUP_TOKEN` — PAT dengan scope `repo` bila ingin `cleanup-actions.sh` menghapus run lama (fallback `GITHUB_TOKEN`).

> Password tidak pernah dicetak, di-Base64, atau ditulis ke `vps-status.json`.

---

## 4. Menjalankan sesi

1. Tab **Actions** → **VpsFree — VPS 6 Jam** (`vps-6h.yml`) → **Run workflow**.
2. Isi input (opsional, sudah ada default):
   - `durasi_menit` — 10–342 menit (default `342`).
   - `hostname` — prefix hostname Tailscale (default `vpsfree`).
   - `vps_user` — nama user sudo (default `vps`; root selalu aktif).
   - `runner` — `ubuntu-24.04`, `ubuntu-22.04`, atau `ubuntu-latest`.
   - `perpanjang_otomatis` — `ya`/`tidak` (default `ya`).
3. Tunggu step **Setup akses Tailscale** selesai. Di log akan muncul IP Tailscale (`100.x.x.x`).
4. Login perangkat ke tailnet yang sama, lalu:

```bash
ssh vps@100.x.x.x -p 22
# atau sebagai root:
ssh root@100.x.x.x -p 22
```

IP dan status juga bisa dibaca dari branch `status` → `vps-status.json`.

---

## 5. Berhenti & perpanjangan (renewal)

- **Auto-stop:** sesi berhenti sendiri 3 menit sebelum `expires_at`. Batas keras job 360 menit.
- **Renewal otomatis** (`perpanjang_otomatis=ya`): `keepalive.sh` menyimpan state lalu men-dispatch sesi berikutnya sekitar **20 menit sebelum** waktu habis, sehingga sesi baru sudah pulih saat sesi lama berakhir. Sesi lama tetap melayani sampai batas waktunya; renewal **tidak** menghapus state.
- **State** disimpan setiap 15 menit dan saat sesi berakhir ke GitHub Release tag `vpsfree-state-latest` (asset `vps-state.tar.gz`), plus artifact `vpsfree-state`.
- Yang ikut dipulihkan: isi home (`/home/<user>`), `/etc/ssh/sshd_config.d`, dan `/var/lib/tailscale` (agar node Tailscale memakai identitas/IP yang sama).

> Saat state dipulihkan, nama node Tailscale dipertahankan (tidak diganti tiap renewal); nama `<prefix>-<nomor-run>` hanya dipakai pada sesi pertama.

> **Menghentikan total:** cancel run yang sedang berjalan **dan** run antrean di tab Actions. Fallback estafet tidak akan men-dispatch ulang saat run di-cancel, tetapi sesi estafet yang sudah terjadwal tetap berjalan bila tidak di-cancel.

> Catatan: runner GitHub-hosted adalah mesin ephemeral, jadi perpindahan sesi tidak bisa benar-benar 100% tanpa jeda. Implementasi meminimalkan downtime dan mempertahankan data + identitas Tailscale. Untuk nol-downtime sejati, pakai runner Ubuntu **self-hosted**.

---

## 6. Struktur repository

```
.github/workflows/
  vps-6h.yml        # sesi VPS (schema 6)
  validate-vps.yml  # bash -n + ShellCheck
scripts/
  lib-common.sh     # helper: logger, baca/tulis out/vps-status.json
  setup-vps.sh      # root/user sudo, SSH, firewall, status awal
  setup-akses.sh    # Tailscale + pembatasan SSH ke tailnet
  restore-state.sh  # pulihkan state sesi sebelumnya
  persist-state.sh  # simpan state (--checkpoint untuk berkala)
  publish-status.sh # publikasi status ke branch status
  keepalive.sh      # heartbeat, checkpoint, handover, auto-stop
  finalize-vps.sh   # putuskan Tailscale sesi ini
  cleanup-actions.sh# hapus run lama
```

---

## 7. Validasi

```bash
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck --severity=error scripts/*.sh
```

CI menjalankan keduanya lewat `.github/workflows/validate-vps.yml` (dipicu saat `scripts/**` berubah).

---

## 8. Keamanan, batasan, dan limit GitHub

- SSH hanya lewat tailnet; ufw menolak inbound selain `tailscale0` / `100.64.0.0/10` ke port 22.
- Port 22 runner GitHub tidak punya inbound publik.
- Jangan menaruh password/auth key di file, log, atau status. `.gitignore` sudah mengabaikan `*.env` dan `out/`.
- **Gunakan repository private.** State Tailscale (`/var/lib/tailscale`) berisi kunci node dan ikut disimpan agar IP tetap sama; Release/artifact bisa dibaca siapa pun bila repo publik. Password tidak pernah ikut disimpan.
- Runner GitHub-hosted bersifat **ephemeral** (VM baru per job) dan job dibatasi **6 jam**. Karena itu durasi dibatasi 342 menit + timeout job 360 menit.
- Batas penyimpanan artifact mengikuti plan GitHub (Free 500 MB / Pro 1 GB / Team 2 GB); asset Release maksimal 2 GB. Bila state terlalu besar, upload artifact bisa gagal (dilewati, job tetap lanjut) dan Release menjadi sumber utama.
- Renewal bisa tertunda bila ada run lain di antrean (concurrency group `vpsfree-active-session`).
- Tidak ada jaminan bebas suspend dari GitHub, kelangsungan IP di luar tailnet, atau cakupan provider Tailscale.
- Gunakan auth key yang bisa dicabut bila perangkat hilang.
