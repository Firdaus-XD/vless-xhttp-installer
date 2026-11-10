#!/usr/bin/env bash
#===============================================================================
#  VLESS + XHTTP Auto-Installer (Xray-core)
#  ---------------------------------------------------------------
#  Satu kali bayar, tanpa langganan, tanpa lisensi per-IP, tanpa callback,
#  tanpa phone-home. Script ini HANYA menghubungi:
#    - api.github.com / github.com  (unduh Xray-core)
#    - mirror Debian/Ubuntu         (apt install dependensi)
#    - get.acme.sh / Let's Encrypt (sertifikat TLS, hanya saat install)
#  Semua kredensial (domain, UUID, path) dibuat di mesin Anda sendiri.
#
#  Target: Debian 11 / 12, Ubuntu 20.04 / 22.04 / 24.04 (x86_64, arm64)
#
#  Cara pakai:
#    curl -fsSL https://CONTOH-DOMAIN-Anda/install-vless-xhttp.sh -o install.sh
#    chmod +x install.sh
#    sudo ./install.sh
#  atau non-interaktif (untuk skrip/testing):
#    sudo ./install.sh --domain vpn.contoh.com --user user1 --path /xhttpvl --yes
#
#  Setelah terinstall, jalankan lagi tanpa argumen untuk membuka menu:
#    sudo ./install.sh            (atau: sudo vless-xhttp)
#  Menu: tambah user, hapus user, lihat daftar user + URI, cek status,
#  restart Xray, uninstall bersih.
#===============================================================================

set -uo pipefail

#----------------------------- Konstanta --------------------------------------
SCRIPT_NAME="install-vless-xhttp.sh"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_USERS="${XRAY_DIR}/users.json"
XRAY_CERT_DIR="${XRAY_DIR}/certs"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"
MENU_CMD="/usr/local/bin/vless-xhttp"
CERT_INFO="${XRAY_DIR}/cert-info"
DEFAULT_PATH="/xhttpvl"
XRAY_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_FALLBACK_TAG="v26.11.9"

#----------------------------- Warna & log ------------------------------------
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_GREEN="\033[0;32m"; C_YELLOW="\033[1;33m"
  C_RED="\033[0;31m"; C_BLUE="\033[0;34m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_BOLD=""
fi

info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[PERINGATAN]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

#----------------------------- Util -------------------------------------------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Script ini harus dijalankan sebagai root (sudo)."
}

detect_os() {
  # Mengisi OS_ID, OS_VERSION, OS_CODENAME
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VERSION="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
  else
    die "Tidak bisa mendeteksi OS (/etc/os-release tidak ada)."
  fi
  case "${OS_ID}" in
    debian)
      [[ "${OS_VERSION}" == "11" || "${OS_VERSION}" == "12" ]] \
        || die "Debian ${OS_VERSION} belum didukung (butuh Debian 11 atau 12)."
      ;;
    ubuntu)
      [[ "${OS_VERSION}" == "20.04" || "${OS_VERSION}" == "22.04" || "${OS_VERSION}" == "24.04" ]] \
        || die "Ubuntu ${OS_VERSION} belum didukung (butuh 20.04 / 22.04 / 24.04)."
      ;;
    *) die "OS '${OS_ID}' belum didukung (butuh Debian 11/12 atau Ubuntu 20.04/22.04/24.04)." ;;
  esac
  info "OS terdeteksi: ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="64" ;;
    aarch64|arm64) ARCH="arm64-v8a" ;;
    *) die "Arsitektur '$(uname -m)' belum didukung." ;;
  esac
  info "Arsitektur: $(uname -m) (paket Xray: ${ARCH})"
}

valid_domain() {
  # Domain sederhana: label.label(.label), tanpa spasi, tanpa skema
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_username() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}

valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9/_.-]*$ ]]
}

port_in_use() { # $1 = port
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
  else
    return 1
  fi
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    # Fallback: UUID v4 dari /dev/urandom
    local hex variant
    hex="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    variant="$(printf '%02x' $((0x${hex:16:2} & 0x3f | 0x80)))"
    echo "${hex:0:8}-${hex:8:4}-4${hex:13:3}-${variant}${hex:18:2}-${hex:20:12}"
  fi
}

urlencode_path() { # "/xhttpvl" -> "%2Fxhttpvl"
  local p="$1"
  echo "%2F${p#/}"
}

#----------------------------- Dependensi -------------------------------------
install_deps() {
  # Bila semua dependensi sudah ada, apt dilewati sepenuhnya — instalasi
  # jadi lebih cepat dan tetap jalan di mesin tanpa akses mirror APT.
  local missing=() dep
  for dep in curl wget jq openssl socat unzip; do
    command -v "${dep}" >/dev/null 2>&1 || missing+=("${dep}")
  done
  command -v ss >/dev/null 2>&1 || missing+=("iproute2")
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=("ca-certificates")
  command -v uuidgen >/dev/null 2>&1 || missing+=("uuid-runtime")
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Semua dependensi sudah terinstall — apt dilewati."
    return 0
  fi
  info "Dependensi belum lengkap (${missing[*]}), menginstall via apt..."
  export DEBIAN_FRONTEND=noninteractive
  local upd_out
  upd_out="$(apt-get update 2>&1)" || die "apt-get update gagal. Periksa koneksi internet & mirror APT Anda."
  if echo "${upd_out}" | grep -q "Failed to fetch"; then
    echo "${upd_out}" | grep "Failed to fetch" | head -5 >&2
    die "apt-get update gagal mengambil daftar paket (cek koneksi internet & DNS Anda, lalu jalankan lagi)."
  fi
  apt-get install -y -qq curl wget jq openssl socat unzip ca-certificates iproute2 uuid-runtime \
    || die "apt-get install gagal."
  ok "Dependensi terinstall."
}

#----------------------------- Xray-core --------------------------------------
install_xray() {
  if [[ -x "${XRAY_BIN}" ]]; then
    info "Xray sudah terinstall: $("${XRAY_BIN}" version 2>/dev/null | head -1 || echo '?')"
    return 0
  fi
  info "Mengambil info rilis Xray-core terbaru dari GitHub..."
  local tag url tmpdir
  tag="$(curl -fsSL --max-time 30 "${XRAY_API}" 2>/dev/null | jq -r '.tag_name // empty' || true)"
  if [[ -z "${tag}" ]]; then
    warn "GitHub API tidak bisa dihubungi, memakai versi fallback ${XRAY_FALLBACK_TAG}."
    tag="${XRAY_FALLBACK_TAG}"
  fi
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${ARCH}.zip"
  info "Mengunduh Xray-core ${tag} ..."
  tmpdir="$(mktemp -d)"
  curl -fsSL --max-time 120 -o "${tmpdir}/xray.zip" "${url}" \
    || { rm -rf "${tmpdir}"; die "Gagal mengunduh Xray-core dari ${url}"; }
  unzip -o -q "${tmpdir}/xray.zip" -d "${tmpdir}/xray" \
    || { rm -rf "${tmpdir}"; die "Gagal mengekstrak Xray-core."; }
  install -m 755 "${tmpdir}/xray/xray" "${XRAY_BIN}"
  mkdir -p /usr/local/share/xray
  [[ -f "${tmpdir}/xray/geoip.dat" ]]  && install -m 644 "${tmpdir}/xray/geoip.dat"  /usr/local/share/xray/geoip.dat
  [[ -f "${tmpdir}/xray/geosite.dat" ]] && install -m 644 "${tmpdir}/xray/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "${tmpdir}"
  ok "Xray-core terinstall: $("${XRAY_BIN}" version | head -1)"
}

#----------------------------- Sertifikat TLS ---------------------------------
# Hasil: menulis $CERT_INFO (DOMAIN, CERT_FILE, KEY_FILE, CERT_MODE)
obtain_cert() { # $1 = domain ; $2 = "acme"|"selfsigned"
  local domain="$1" mode="$2"
  mkdir -p "${XRAY_CERT_DIR}"
  local cert_file="${XRAY_CERT_DIR}/fullchain.pem"
  local key_file="${XRAY_CERT_DIR}/privkey.pem"

  if [[ "${mode}" == "acme" ]]; then
    if port_in_use 80; then
      warn "Port 80 sedang dipakai sesuatu — acme.sh mode standalone butuh port 80 kosong."
      warn "Beralih ke sertifikat self-signed (klien harus mengaktifkan allowInsecure)."
      mode="selfsigned"
    fi
  fi

  if [[ "${mode}" == "acme" ]]; then
    info "Menginstall acme.sh & menerbitkan sertifikat Let's Encrypt untuk ${domain}..."
    if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
      curl -fsSL --max-time 60 https://get.acme.sh | sh -s email="${domain}-admin@${domain}" >/dev/null 2>&1 \
        || { warn "Install acme.sh gagal."; mode="selfsigned"; }
    fi
  fi

  if [[ "${mode}" == "acme" ]]; then
    local acme="${HOME}/.acme.sh/acme.sh"
    "${acme}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    if "${acme}" --issue -d "${domain}" --standalone --keylength ec-256 >/dev/null 2>&1; then
      "${acme}" --install-cert -d "${domain}" --ecc \
        --fullchain-file "${cert_file}" --key-file "${key_file}" \
        --reloadcmd "systemctl restart xray || true" >/dev/null 2>&1 \
        || { warn "Install sertifikat ke ${XRAY_CERT_DIR} gagal."; mode="selfsigned"; }
    else
      warn "Penerbitan sertifikat Let's Encrypt GAGAL (domain belum mengarah ke IP VPS ini / port 80 terhalang)."
      mode="selfsigned"
    fi
  fi

  if [[ "${mode}" == "selfsigned" ]]; then
    warn "Membuat sertifikat self-signed untuk ${domain} (valid 10 tahun)."
    warn "Klien HARUS mengaktifkan allowInsecure / skip-cert-verify, atau sertifikat tidak akan dipercaya."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout "${key_file}" -out "${cert_file}" -days 3650 -nodes \
      -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
      || die "Gagal membuat sertifikat self-signed."
    chmod 600 "${key_file}"; chmod 644 "${cert_file}"
  fi

  [[ -s "${cert_file}" && -s "${key_file}" ]] \
    || die "File sertifikat tidak ditemukan setelah pembuatan."
  {
    echo "DOMAIN=${domain}"
    echo "CERT_FILE=${cert_file}"
    echo "KEY_FILE=${key_file}"
    echo "CERT_MODE=${mode}"
  } > "${CERT_INFO}"
  chmod 600 "${CERT_INFO}"
  ok "Sertifikat siap (mode: ${mode})."
}

#----------------------------- Konfigurasi Xray --------------------------------
# users.json: [{"name":"user1","uuid":"..."}]
# cert-info: DOMAIN, CERT_FILE, KEY_FILE, CERT_MODE
# path disimpan di $XRAY_DIR/xhttp-path
build_config() {
  local domain cert_file key_file xpath
  # shellcheck disable=SC1090
  . "${CERT_INFO}"
  domain="${DOMAIN}"; cert_file="${CERT_FILE}"; key_file="${KEY_FILE}"
  xpath="$(cat "${XRAY_DIR}/xhttp-path")"
  mkdir -p "${XRAY_LOG_DIR}"
  jq -n \
    --arg cert "${cert_file}" \
    --arg key "${key_file}" \
    --arg path "${xpath}" \
    --slurpfile clients "${XRAY_USERS}" \
    '{
      log: { loglevel: "warning",
             access: "/var/log/xray/access.log",
             error: "/var/log/xray/error.log" },
      inbounds: [ {
        port: 443,
        protocol: "vless",
        # users.json memakai kunci name/uuid; Xray VLESS butuh id + email.
        settings: { clients: ($clients[0] | map({id: .uuid, email: .name})), decryption: "none" },
        streamSettings: {
          network: "xhttp",
          security: "tls",
          tlsSettings: {
            certificates: [ { certificateFile: $cert, keyFile: $key } ],
            alpn: ["h2", "http/1.1"]
          },
          xhttpSettings: { path: $path, mode: "auto" }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls"] }
      }, {
        port: 80,
        protocol: "vless",
        settings: { clients: ($clients[0] | map({id: .uuid, email: .name})), decryption: "none" },
        streamSettings: {
          network: "xhttp",
          security: "none",
          xhttpSettings: { path: $path, mode: "auto" }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls"] }
      } ],
      outbounds: [ { protocol: "freedom", tag: "direct" } ]
    }' > "${XRAY_CONFIG}.tmp" \
    || die "Gagal membangun config.json."
  mv "${XRAY_CONFIG}.tmp" "${XRAY_CONFIG}"
  chmod 600 "${XRAY_CONFIG}"
}

test_config() {
  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" 2>&1 \
    || die "Validasi config Xray GAGAL. Periksa ${XRAY_CONFIG}."
  ok "Config Xray valid (xray run -test lolos)."
}

write_systemd_unit() {
  cat > "${XRAY_SERVICE}" <<'EOF'
[Unit]
Description=Xray Service (VLESS + XHTTP)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1
  ok "Service systemd xray dibuat & di-enable."
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 443/tcp >/dev/null 2>&1; ufw allow 80/tcp >/dev/null 2>&1
    ok "Firewall UFW: port 443 & 80 dibuka."
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=443/tcp --add-port=80/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "Firewall firewalld: port 443 & 80 dibuka."
  fi
}

#----------------------------- URI & user --------------------------------------
build_uri() { # $1 = name ; $2 = uuid ; $3 = domain ; $4 = path
  local name="$1" uuid="$2" domain="$3" path="$4"
  echo "vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&path=$(urlencode_path "${path}")#${name}"
}

get_domain() { grep '^DOMAIN=' "${CERT_INFO}" | cut -d= -f2-; }
get_path()   { cat "${XRAY_DIR}/xhttp-path"; }

add_user_record() { # $1 = name -> echo uuid
  local name="$1" uuid
  uuid="$(new_uuid)"
  jq --arg name "${name}" --arg uuid "${uuid}" \
    '. + [{name: $name, uuid: $uuid}]' "${XRAY_USERS}" > "${XRAY_USERS}.tmp" \
    && mv "${XRAY_USERS}.tmp" "${XRAY_USERS}"
  echo "${uuid}"
}

user_exists() { # $1 = name
  jq -e --arg name "$1" '.[] | select(.name == $name)' "${XRAY_USERS}" >/dev/null 2>&1
}

restart_xray() {
  if systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray || die "Gagal restart service xray."
  else
    systemctl start xray || die "Gagal start service xray."
  fi
}

#----------------------------- Install -----------------------------------------
do_install() {
  require_root
  detect_os
  detect_arch

  local domain="${ARG_DOMAIN:-}" xpath="${ARG_PATH:-${DEFAULT_PATH}}"
  local first_user="${ARG_USER:-user1}" cert_mode="acme"
  [[ -n "${ARG_SELFSIGNED:-}" ]] && cert_mode="selfsigned"

  echo "=================================================================="
  echo "  VLESS + XHTTP Auto-Installer (Xray-core)"
  echo "=================================================================="
  echo ""

  if [[ -f "${XRAY_CONFIG}" && -z "${ARG_FORCE:-}" ]]; then
    err "Xray sudah terinstall di mesin ini."
    err "Jalankan script tanpa argumen untuk membuka menu manajemen,"
    err "atau jalankan dengan --install untuk install ulang."
    exit 1
  fi

  # --- Input interaktif bila argumen tidak diberikan ---
  if [[ -z "${domain}" ]]; then
    while true; do
      read -rp "Domain VPS Anda (sudah diarahkan ke IP VPS ini, mis. vpn.contoh.com): " domain
      valid_domain "${domain}" && break
      err "Format domain tidak valid. Contoh: vpn.contoh.com"
    done
  fi
  valid_domain "${domain}" || die "Format domain tidak valid: ${domain}"

  if [[ -z "${ARG_PATH:-}" ]]; then
    read -rp "Path XHTTP [${DEFAULT_PATH}]: " _p
    [[ -n "${_p:-}" ]] && xpath="${_p}"
  fi
  valid_path "${xpath}" || die "Format path tidak valid: ${xpath} (harus diawali /)"

  if [[ -z "${ARG_USER:-}" ]]; then
    read -rp "Nama user pertama [user1]: " _u
    [[ -n "${_u:-}" ]] && first_user="${_u}"
  fi
  valid_username "${first_user}" || die "Nama user tidak valid (huruf/angka/_/- saja, maks 32 karakter)."

  if port_in_use 443; then
    warn "Port 443 sedang dipakai oleh proses lain! Xray tidak akan bisa start."
    if [[ -z "${ARG_YES:-}" ]]; then
      read -rp "Lanjutkan saja? [y/N]: " _c
      [[ "${_c:-}" =~ ^[Yy]$ ]] || die "Install dibatalkan."
    fi
  fi

  if [[ "${cert_mode}" == "acme" ]]; then
    info "Domain ${domain} harus sudah mengarah (DNS A/AAAA) ke IP publik VPS ini."
    info "Jika belum, penerbitan sertifikat akan gagal dan installer memakai self-signed."
  fi
  if [[ -z "${ARG_YES:-}" ]]; then
    echo ""
    echo "Ringkasan install:"
    echo "  Domain     : ${domain}"
    echo "  Path XHTTP : ${xpath}"
    echo "  User awal  : ${first_user}"
    echo "  Sertifikat : ${cert_mode}"
    echo "  Port       : 443 (TLS)"
    read -rp "Lanjut install? [Y/n]: " _c
    [[ "${_c:-}" =~ ^[Nn]$ ]] && die "Install dibatalkan."
  fi

  install_deps
  install_xray

  mkdir -p "${XRAY_DIR}" "${XRAY_LOG_DIR}"
  echo "${xpath}" > "${XRAY_DIR}/xhttp-path"
  echo '[]' > "${XRAY_USERS}"
  obtain_cert "${domain}" "${cert_mode}"

  local uuid
  uuid="$(add_user_record "${first_user}")"
  build_config
  test_config
  write_systemd_unit
  open_firewall
  restart_xray

  sleep 2
  if systemctl is-active --quiet xray; then
    ok "Service xray AKTIF."
  else
    err "Service xray tidak aktif. Cek log: journalctl -u xray -n 50"
    systemctl status xray --no-pager 2>&1 | head -30 || true
    exit 1
  fi
  if port_in_use 443; then ok "Port 443 listen."; else warn "Port 443 belum terlihat listen — cek journalctl -u xray."; fi

  local uri
  uri="$(build_uri "${first_user}" "${uuid}" "${domain}" "${xpath}")"
  echo ""
  echo "=================================================================="
  echo -e "${C_BOLD}${C_GREEN}  INSTALL SELESAI${C_RESET}"
  echo "=================================================================="
  echo "  Domain     : ${domain}"
  echo "  Path XHTTP : ${xpath}"
  echo "  User       : ${first_user}"
  echo "  UUID       : ${uuid}"
  echo "  Sertifikat : ${cert_mode}"
  echo ""
  echo "  URI VLESS (import ke v2rayNG / NekoBox / FoXray / Streisand):"
  echo ""
  echo "  ${uri}"
  echo ""
  echo "  Menu manajemen: jalankan lagi script ini tanpa argumen,"
  echo "  atau ketik: vless-xhttp"
  echo "=================================================================="

  # Simpan salinan script sebagai perintah menu
  cp "$0" "${MENU_CMD}" 2>/dev/null || true
  chmod +x "${MENU_CMD}" 2>/dev/null || true
}

#----------------------------- Menu --------------------------------------------
menu_list_users() {
  local domain xpath count
  domain="$(get_domain)"; xpath="$(get_path)"
  count="$(jq 'length' "${XRAY_USERS}")"
  echo ""
  echo "Daftar user (${count}):"
  echo "------------------------------------------------------------------"
  jq -r '.[] | "\(.name)\t\(.uuid)"' "${XRAY_USERS}" | while IFS=$'\t' read -r name uuid; do
    echo "  - ${name}  (${uuid})"
    echo "    $(build_uri "${name}" "${uuid}" "${domain}" "${xpath}")"
  done
  echo "------------------------------------------------------------------"
}

menu_add_user() {
  local name uuid
  while true; do
    read -rp "Nama user baru (huruf/angka/_/-, maks 32): " name
    valid_username "${name}" || { err "Nama tidak valid."; continue; }
    user_exists "${name}" && { err "User '${name}' sudah ada."; continue; }
    break
  done
  uuid="$(add_user_record "${name}")"
  build_config && test_config
  restart_xray
  local domain xpath
  domain="$(get_domain)"; xpath="$(get_path)"
  echo ""
  ok "User '${name}' ditambahkan."
  echo "  URI: $(build_uri "${name}" "${uuid}" "${domain}" "${xpath}")"
}

menu_del_user() {
  local name
  menu_list_users
  read -rp "Nama user yang dihapus: " name
  user_exists "${name}" || { err "User '${name}' tidak ditemukan."; return 0; }
  read -rp "Yakin hapus '${name}'? [y/N]: " _c
  [[ "${_c:-}" =~ ^[Yy]$ ]] || { info "Dibatalkan."; return 0; }
  jq --arg name "${name}" 'map(select(.name != $name))' "${XRAY_USERS}" > "${XRAY_USERS}.tmp" \
    && mv "${XRAY_USERS}.tmp" "${XRAY_USERS}"
  build_config && test_config
  restart_xray
  ok "User '${name}' dihapus."
}

menu_status() {
  echo ""
  echo "Xray-core: $("${XRAY_BIN}" version 2>/dev/null | head -1 || echo 'tidak terinstall')"
  echo "Service  : $(systemctl is-active xray 2>/dev/null || echo 'unknown')"
  echo "Config   : ${XRAY_CONFIG}"
  echo "Domain   : $(get_domain 2>/dev/null || echo '-')"
  echo "Path     : $(get_path 2>/dev/null || echo '-')"
  echo "Sertifikat: $(grep '^CERT_MODE=' "${CERT_INFO}" 2>/dev/null | cut -d= -f2 || echo '-')"
  echo "Port 443 : $(port_in_use 443 && echo 'LISTEN' || echo 'tidak listen')"
  echo "User     : $(jq -r '.[].name' "${XRAY_USERS}" 2>/dev/null | tr '\n' ' ' || echo '-')"
  echo ""
  systemctl status xray --no-pager 2>/dev/null | head -12 || true
}

menu_uninstall() {
  echo ""
  warn "Ini akan menghapus Xray, config, user, sertifikat, dan service."
  read -rp "Yakin uninstall bersih? Ketik YA untuk lanjut: " _c
  [[ "${_c:-}" == "YA" ]] || { info "Dibatalkan."; return 0; }
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f "${XRAY_SERVICE}"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "${XRAY_DIR}" "${XRAY_LOG_DIR}" "${XRAY_BIN}" /usr/local/share/xray "${MENU_CMD}"
  ok "Uninstall selesai. (acme.sh di ~/.acme.sh dibiarkan; hapus manual bila perlu.)"
}

show_menu() {
  require_root
  [[ -f "${XRAY_CONFIG}" ]] || die "Xray belum terinstall. Jalankan: $0 --install"
  while true; do
    echo ""
    echo "=================================================================="
    echo "  VLESS + XHTTP — Menu Manajemen  (domain: $(get_domain))"
    echo "=================================================================="
    echo "  1) Tambah user"
    echo "  2) Hapus user"
    echo "  3) Lihat daftar user + URI"
    echo "  4) Cek status Xray"
    echo "  5) Restart Xray"
    echo "  6) Uninstall bersih"
    echo "  0) Keluar"
    echo "------------------------------------------------------------------"
    read -rp "Pilih [0-6]: " choice
    case "${choice}" in
      1) menu_add_user ;;
      2) menu_del_user ;;
      3) menu_list_users ;;
      4) menu_status ;;
      5) restart_xray && ok "Xray di-restart." ;;
      6) menu_uninstall; break ;;
      0) echo "Sampai jumpa."; break ;;
      *) err "Pilihan tidak valid." ;;
    esac
  done
}

#----------------------------- Argumen & main ----------------------------------
usage() {
  cat <<'EOF'
Pakai:
  sudo ./install-vless-xhttp.sh                 Install interaktif / buka menu
  sudo ./install-vless-xhttp.sh --install        Install ulang (paksa)
  sudo ./install-vless-xhttp.sh --domain vpn.contoh.com [--user user1]
                                [--path /xhttpvl] [--selfsigned] [--yes]
  sudo ./install-vless-xhttp.sh --menu           Buka menu manajemen
  sudo ./install-vless-xhttp.sh --uninstall      Uninstall bersih
  sudo ./install-vless-xhttp.sh --help           Tampilkan bantuan ini

Opsi:
  --domain DOMEN    Domain VPS (harus mengarah ke IP VPS untuk sertifikat)
  --user NAMA       Nama user pertama (default: user1)
  --path PATH       Path XHTTP (default: /xhttpvl)
  --selfsigned      Pakai sertifikat self-signed (tanpa Let's Encrypt)
  --yes             Lewati semua konfirmasi
  --install         Paksa jalankan installer walau Xray sudah terinstall
  --menu            Paksa buka menu manajemen
  --uninstall       Uninstall bersih
EOF
}

main() {
  ARG_DOMAIN=""; ARG_PATH=""; ARG_USER=""; ARG_SELFSIGNED=""; ARG_YES=""
  ARG_FORCE=""; ARG_MENU=""; ARG_UNINSTALL=""
  local action="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)    ARG_DOMAIN="${2:-}"; shift 2 ;;
      --path)      ARG_PATH="${2:-}"; shift 2 ;;
      --user)      ARG_USER="${2:-}"; shift 2 ;;
      --selfsigned) ARG_SELFSIGNED="1"; shift ;;
      --yes)       ARG_YES="1"; shift ;;
      --install)   ARG_FORCE="1"; action="install"; shift ;;
      --menu)      ARG_MENU="1"; action="menu"; shift ;;
      --uninstall) ARG_UNINSTALL="1"; action="uninstall"; shift ;;
      --help|-h)   usage; exit 0 ;;
      *) err "Argumen tidak dikenal: $1"; usage; exit 1 ;;
    esac
  done

  case "${action}" in
    install)   do_install ;;
    menu)      show_menu ;;
    uninstall) require_root; menu_uninstall ;;
    auto)
      if [[ -f "${XRAY_CONFIG}" ]]; then
        show_menu
      else
        do_install
      fi
      ;;
  esac
}

main "$@"
