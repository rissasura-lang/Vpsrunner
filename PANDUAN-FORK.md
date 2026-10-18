# Membuat atau memperbarui repository VpsFree

Kredit: KallAncrit. Template asli: `xykal/XyRDP`. Ikuti [README aktif](README.md).

1. Fork repository ini (atau salin isinya) dengan nama repository pilihanmu.
2. Aktifkan Actions, lalu isi secrets `VPS_PASSWORD` (password root/user sudo) dan `TAILSCALE_AUTH_KEY`.
3. Jalankan workflow VpsFree. Akses hanya lewat Tailscale + SSH port 22. Tidak ada port publik.
4. Perangkat harus login ke tailnet yang sama. Jangan mencetak atau menyimpan password/auth key.
5. Sesi berakhir otomatis pada batas waktu. Renewal berjalan sebelum waktu habis dan tidak menghapus state.

Repository lama (versi RDP/Windows) perlu menyinkronkan `.github/workflows/vps-6h.yml` + seluruh `scripts/` (bash), lalu menghapus berkas Windows/RDP lama.
