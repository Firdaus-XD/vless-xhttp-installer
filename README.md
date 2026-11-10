# VLESS + XHTTP Auto-Installer (Xray-core)

Script installer otomatis untuk VPN **VLESS + XHTTP (Xray-core)** di **Debian 11 / 12** dan **Ubuntu 20.04 / 22.04 / 24.04**. Sekali bayar, tanpa langganan, tanpa lisensi per-IP, tanpa callback / phone-home.

## Yang diinstall

- **Xray-core** versi stabil terbaru (dari GitHub resmi XTLS) + service systemd (auto-start saat boot)
- **Inbound VLESS** port **443** + TLS, transport **XHTTP**
- **Sertifikat TLS otomatis** via acme.sh + Let's Encrypt (standalone, port 80) — kalau gagal, otomatis fallback ke self-signed dengan peringatan jelas
- **1 user pertama** dibuat saat install, lengkap dengan URI `vless://` siap import
- **Menu manajemen** — tambah/hapus user, lihat daftar user + URI, cek status, restart, uninstall bersih

## Kebutuhan

1. VPS **Debian 11 / 12** atau **Ubuntu 20.04 / 22.04 / 24.04** (x86_64 atau arm64), akses **root**
2. **Domain** yang sudah diarahkan (DNS A/AAAA) ke IP publik VPS — wajib untuk sertifikat Let's Encrypt
3. Port **443** dan **80** kosong (tidak dipakai aplikasi lain)

## Cara install

```bash
apt update && apt install -y curl
curl -fsSL https://raw.githubusercontent.com/Firdaus-XD/vless-xhttp-installer/main/install-vless-xhttp.sh -o install.sh
chmod +x install.sh
bash install.sh
```

> Penting: tampal perintah di atas **tanpa** tanda petik `'` di awal/akhir. `apt install curl` wajib dulu karena Debian minimal belum tentu punya `curl`. Kalau login sebagai `root`, `sudo` tidak diperlukan.

Lalu ikuti petunjuknya: masukkan domain, path XHTTP (default `/xhttpvl`), dan nama user pertama. Selesai — script menampilkan URI VLESS lengkap.

**Non-interaktif** (untuk skrip/testing):

```bash
bash install.sh --domain vpn.contoh.com --user user1 --path /xhttpvl --yes
```

Opsi lain: `--selfsigned` (pakai sertifikat self-signed, tanpa Let's Encrypt), `--install` (install ulang), `--menu`, `--uninstall`, `--help`.

## Setelah install

URI VLESS yang ditampilkan bisa langsung diimport ke:

- **Android:** v2rayNG, NekoBox
- **iOS:** FoXray, Streisand, Shadowrocket
- **Windows/macOS:** v2rayN, NekoRay, Clash Meta (mihomo)

Contoh URI:

```
vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@vpn.contoh.com:443?encryption=none&security=tls&sni=vpn.contoh.com&type=xhttp&path=%2Fxhttpvl#user1
```

## Menu manajemen

Jalankan lagi scriptnya tanpa argumen (atau ketik `vless-xhttp`):

```
1) Tambah user        — buat UUID baru + tampilkan URI-nya
2) Hapus user         — hapus user dari config
3) Lihat daftar user  — semua user + URI masing-masing
4) Cek status Xray    — versi, status service, port, user
5) Restart Xray
6) Uninstall bersih   — hapus service, config, user, sertifikat, binary
0) Keluar
```

Setiap perubahan user otomatis memvalidasi config (`xray run -test`) sebelum restart, jadi config rusak tidak akan membuat service mati.

## Fitur VLESS + XHTTP

- **VLESS:** protokol ringan dan cepat, autentikasi pakai UUID, tanpa enkripsi bawaan (keamanan dari TLS)
- **XHTTP:** transport berbasis HTTP — lalu lintasnya mirip browsing biasa sehingga lebih susah dideteksi dan diblokir
- **TLS (domain + SSL):** koneksi terenkripsi end-to-end
- **Multi-user:** tiap user punya UUID sendiri, bisa ditambah/dihapus kapan saja
- **Stabil di Debian 11**, bisa jalan di balik CDN / reverse proxy
- **Auto-start:** service systemd aktif otomatis setiap VPS reboot

## File & lokasi

| Lokasi | Isi |
|---|---|
| `/usr/local/bin/xray` | Binary Xray-core |
| `/usr/local/etc/xray/config.json` | Konfigurasi Xray (dibuat otomatis) |
| `/usr/local/etc/xray/users.json` | Daftar user (nama + UUID) |
| `/usr/local/etc/xray/certs/` | Sertifikat TLS (fullchain + privkey) |
| `/etc/systemd/system/xray.service` | Service systemd |
| `/var/log/xray/` | Log akses & error Xray |
| `/usr/local/bin/vless-xhttp` | Perintah menu manajemen |

## Privasi

Script ini **tidak** mengirim data apa pun ke pihak ketiga. Koneksi keluar hanya ke:

- `api.github.com` / `github.com` — unduh Xray-core
- Mirror APT Debian/Ubuntu — install dependensi
- `get.acme.sh` / Let's Encrypt — sertifikat TLS (hanya saat install)

Tidak ada phone-home, lisensi per-IP, callback, atau backdoor. Semua nilai (domain, UUID, path) dibuat di mesin Anda sendiri dan tidak pernah keluar dari VPS Anda.

## Catatan

- **Self-signed:** kalau sertifikat Let's Encrypt gagal diterbitkan (mis. domain belum mengarah ke VPS), installer otomatis memakai self-signed. Klien harus mengaktifkan `allowInsecure` / `skip-cert-verify` di pengaturan TLS-nya (di aplikasi seperti v2rayNG/NekoBox, opsi ini tetap ada). Catatan: di config mentah Xray-core v26+, opsi `allowInsecure` diganti `pinnedPeerCertSha256` — isi dengan fingerprint SHA256 sertifikat server.
- **Port 80** hanya dipakai sebentar saat penerbitan sertifikat (acme.sh standalone), setelah itu bebas dipakai aplikasi lain. Port **443** dipakai permanen oleh Xray.
- **Perpanjangan sertifikat:** acme.sh memasang cron otomatis untuk memperpanjang sertifikat Let's Encrypt sebelum kedaluwarsa.
- Kalau port 443 sudah dipakai aplikasi lain, install akan memberi peringatan — pindahkan aplikasi tersebut dulu.
