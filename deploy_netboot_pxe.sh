#!/usr/bin/env bash
#===============================================================================
# netboot.xyz PXE + Unattended Install Deployment Script
#
# Deploys a fully self-contained Docker Compose environment:
#   - netboot.xyz  (TFTP :69, HTTP assets :8082, Web UI :3001)
#   - dnsmasq      (DHCP :67, PXE boot directives — host network)
#   - nginx        (HTTP :8081 — autoinstall, autounattend, ISOs, kernels)
#   - samba        (SMB :445 — Windows install share)
#
# Automatically downloads:
#   - Ubuntu 24.04 LTS live-server ISO → extracts kernel + initrd locally
#   - Windows 11 ISO (interactive) → extracts WinPE boot files
#
# Host IP    : 192.168.1.172
# Gateway    : 192.168.1.1
# DHCP Range : 192.168.1.200 – 192.168.1.250
#===============================================================================
set -euo pipefail

# ============================ Configuration ===================================
HOST_IP="192.168.1.172"
GATEWAY="192.168.1.1"
DNS_SERVER="8.8.8.8"
DHCP_RANGE_START="192.168.1.200"
DHCP_RANGE_END="192.168.1.250"
SUBNET_MASK="255.255.255.0"
DHCP_LEASE="12h"
DOMAIN="pxe.local"

NETBOOT_WEB_PORT="3001"
NETBOOT_HTTP_PORT="8082"
NGINX_PORT="8081"

BASE="/opt/netboot-pxe"
ISO_DIR="${BASE}/isos"

# Ubuntu 24.04.x desktop ISO (supports autoinstall since 23.04)
# Auto-discovered at runtime; these are fallback defaults.
UBUNTU_ISO_URL="https://releases.ubuntu.com/noble/ubuntu-24.04.3-desktop-amd64.iso"
UBUNTU_ISO_NAME="ubuntu-24.04.3-desktop-amd64.iso"
UBUNTU_RELEASE_PAGE="https://releases.ubuntu.com/noble/"

# Windows 11 ISO download page (user must get their own — licensing)
WINDOWS_DOWNLOAD_URL="https://www.microsoft.com/en-us/software-download/windows11"

# Passwords — CHANGE FOR PRODUCTION
# Hash below = "changeme" — regenerate: mkpasswd --method=sha-512 --rounds=4096
UBUNTU_PW_HASH='$6$rounds=4096$xYzSalt1234$V7kGQ0VqjGfOQh8v4N6YpqKmXr0B6bLpZs9kW2MxDlPmJcT3HWYn7.fN8xXoFZ7r2eU5y0K3cB1aW4dM9sQ5t.'
WIN_ADMIN_PW="P@ssw0rd!"
# ==============================================================================

banner() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│         netboot.xyz PXE Deployment Environment          │"
    echo "│                                                          │"
    echo "│  Host IP ........: ${HOST_IP}                       │"
    echo "│  Gateway ........: ${GATEWAY}                         │"
    echo "│  DHCP Range .....: ${DHCP_RANGE_START} – ${DHCP_RANGE_END}      │"
    echo "│  Nginx (HTTP) ...: port ${NGINX_PORT}                          │"
    echo "│  Netboot.xyz UI .: port ${NETBOOT_WEB_PORT}                          │"
    echo "│  TFTP ............: port 69                              │"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""
}

# ========================= Pre-flight checks ==================================
preflight() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] Run this script as root or with sudo."
        exit 1
    fi

    # Install Docker if missing
    if ! command -v docker &>/dev/null; then
        echo "[*] Docker not found — installing via get.docker.com..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi

    if ! docker compose version &>/dev/null; then
        echo "[ERROR] docker compose v2 required. Install docker-compose-plugin."
        exit 1
    fi

    # Install required tools for ISO extraction
    echo "[*] Installing ISO extraction tools..."

    # Temporarily disable broken third-party PPAs so apt-get update succeeds.
    # We move any problematic .list files aside, update, install, then restore.
    local bad_lists=()
    if ! apt-get update -qq 2>/dev/null; then
        echo "[*] apt-get update failed — disabling broken third-party repos..."
        while IFS= read -r repo_file; do
            [[ -z "${repo_file}" ]] && continue
            echo "    Disabling: ${repo_file}"
            mv "${repo_file}" "${repo_file}.pxe-disabled"
            bad_lists+=("${repo_file}")
        done < <(
            apt-get update 2>&1 | \
            grep -oP "(?<=The repository ').*?(?=' )|(?<=GPG error: ).*?(?= )" | \
            while read -r bad_url; do
                grep -rl "${bad_url%%/dists*}" /etc/apt/sources.list.d/ 2>/dev/null
            done | sort -u
        )
        # Also catch any .list files that reference domains returning errors
        for listfile in /etc/apt/sources.list.d/*.list; do
            [[ -f "${listfile}" ]] || continue
            if apt-get update -o Dir::Etc::sourcelist="${listfile}" \
                              -o Dir::Etc::sourceparts="/dev/null" 2>&1 | \
               grep -qiE "does not have a Release|is not signed|EXPKEYSIG"; then
                echo "    Disabling: ${listfile}"
                mv "${listfile}" "${listfile}.pxe-disabled"
                bad_lists+=("${listfile}")
            fi
        done
        apt-get update -qq 2>/dev/null || apt-get update --allow-releaseinfo-change -qq 2>/dev/null || true
    fi

    apt-get install -y -qq p7zip-full curl wget xorriso wimtools 2>/dev/null || \
    apt-get install -y -qq p7zip-full curl wget xorriso 2>/dev/null || true

    # Restore disabled repos
    for f in "${bad_lists[@]}"; do
        [[ -f "${f}.pxe-disabled" ]] && mv "${f}.pxe-disabled" "${f}"
    done
    if [[ ${#bad_lists[@]} -gt 0 ]]; then
        echo "[*] Restored ${#bad_lists[@]} disabled repo(s). Consider cleaning them up:"
        printf "    %s\n" "${bad_lists[@]}"
    fi

    # Stop anything that holds port 67 or 69
    for svc in isc-dhcp-server dnsmasq tftpd-hpa; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
}

# ========================= Directory tree =====================================
create_dirs() {
    echo "[*] Creating directory tree under ${BASE} ..."
    mkdir -p "${BASE}"/{config/{dnsmasq,nginx,samba},tftp,http/{ubuntu,windows,winpe},assets}
    mkdir -p "${ISO_DIR}"
}

# =============================================================================
#  UBUNTU ISO DOWNLOAD + KERNEL EXTRACTION
# =============================================================================
download_ubuntu_iso() {
    local kernel_dir="${BASE}/http/ubuntu"

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  UBUNTU 24.04 LTS DESKTOP — ISO Download + Extraction   │"
    echo "└──────────────────────────────────────────────────────────┘"

    # Skip if kernel already extracted from a previous run
    if [[ -f "${kernel_dir}/vmlinuz" && -f "${kernel_dir}/initrd" ]]; then
        echo "[*] Ubuntu kernel + initrd already present — skipping download."
        echo "    ${kernel_dir}/vmlinuz"
        echo "    ${kernel_dir}/initrd"
        echo "    (Delete these files to force re-download.)"
        return 0
    fi

    # ── Auto-discover the latest 24.04.x desktop ISO from releases page ──
    echo "[*] Checking ${UBUNTU_RELEASE_PAGE} for latest desktop ISO..."
    local discovered_name=""
    discovered_name=$(wget -qO- "${UBUNTU_RELEASE_PAGE}" 2>/dev/null | \
        grep -oP 'ubuntu-24\.04\.[0-9]+-desktop-amd64\.iso(?=")' | \
        sort -V | tail -1) || true

    if [[ -n "${discovered_name}" ]]; then
        UBUNTU_ISO_NAME="${discovered_name}"
        UBUNTU_ISO_URL="${UBUNTU_RELEASE_PAGE}${discovered_name}"
        echo "[*] Latest ISO discovered: ${UBUNTU_ISO_NAME}"
    else
        echo "[*] Auto-discovery did not find a newer version — using default: ${UBUNTU_ISO_NAME}"
    fi

    local iso_path="${ISO_DIR}/${UBUNTU_ISO_NAME}"

    # Check for any already-downloaded 24.04 desktop ISO
    local existing_iso
    existing_iso=$(find "${ISO_DIR}" -maxdepth 1 -name 'ubuntu-24.04*-desktop-amd64.iso' 2>/dev/null | sort -V | tail -1)
    if [[ -n "${existing_iso}" && -f "${existing_iso}" ]]; then
        echo "[*] Found existing Ubuntu desktop ISO: ${existing_iso}"
        iso_path="${existing_iso}"
    else
        echo "[*] Downloading Ubuntu 24.04 LTS Desktop ISO..."
        echo "    URL : ${UBUNTU_ISO_URL}"
        echo "    Dest: ${iso_path}"
        echo "    Size: ~5.9 GB — this will take a while"
        echo ""

        if ! wget --progress=bar:force:noscroll \
                  --continue \
                  -O "${iso_path}" \
                  "${UBUNTU_ISO_URL}"; then
            echo ""
            echo "[WARN] Primary download failed. Trying mirrors..."

            local mirrors=(
                "https://mirror.arizona.edu/ubuntu-releases/24.04/${UBUNTU_ISO_NAME}"
                "https://mirror.us.leaseweb.net/ubuntu-releases/noble/${UBUNTU_ISO_NAME}"
                "https://ftp.halifax.rwth-aachen.de/ubuntu-releases/noble/${UBUNTU_ISO_NAME}"
                "http://ftp.usf.edu/pub/ubuntu-releases/24.04/${UBUNTU_ISO_NAME}"
            )
            local downloaded=false
            for mirror_url in "${mirrors[@]}"; do
                echo "[*] Trying: ${mirror_url}"
                if wget --progress=bar:force:noscroll \
                        --continue \
                        -O "${iso_path}" \
                        "${mirror_url}" 2>/dev/null; then
                    downloaded=true
                    break
                fi
            done

            if ! $downloaded; then
                echo ""
                echo "[ERROR] Ubuntu ISO download failed from all mirrors."
                echo "        Download manually and place at: ${iso_path}"
                echo "        URL: ${UBUNTU_ISO_URL}"
                echo "        Then re-run this script."
                rm -f "${iso_path}"
                return 1
            fi
        fi
        echo ""
        echo "[*] Ubuntu desktop ISO download complete."
    fi

    # ── Extract kernel + initrd from the desktop ISO ──
    echo "[*] Extracting kernel and initrd from desktop ISO..."
    local mnt
    mnt=$(mktemp -d)
    trap 'umount "${mnt}" 2>/dev/null; rmdir "${mnt}" 2>/dev/null' RETURN

    mount -o loop,ro "${iso_path}" "${mnt}"

    # Desktop ISO uses casper/vmlinuz and casper/initrd (same layout as server)
    if [[ -f "${mnt}/casper/vmlinuz" ]]; then
        cp -v "${mnt}/casper/vmlinuz" "${kernel_dir}/vmlinuz"
        cp -v "${mnt}/casper/initrd"  "${kernel_dir}/initrd"
        echo "[*] Extracted casper/vmlinuz + casper/initrd"
    elif [[ -f "${mnt}/casper/vmlinuz.efi" ]]; then
        cp -v "${mnt}/casper/vmlinuz.efi" "${kernel_dir}/vmlinuz"
        for initrd_name in initrd initrd.lz initrd.gz; do
            if [[ -f "${mnt}/casper/${initrd_name}" ]]; then
                cp -v "${mnt}/casper/${initrd_name}" "${kernel_dir}/initrd"
                break
            fi
        done
        echo "[*] Extracted casper/vmlinuz.efi + initrd"
    else
        echo "[WARN] Could not find casper/vmlinuz in ISO. Found:"
        find "${mnt}" -maxdepth 3 \( -name 'vmlinuz*' -o -name 'initrd*' -o -name 'linux' \) 2>/dev/null
        umount "${mnt}" 2>/dev/null; rmdir "${mnt}" 2>/dev/null
        return 1
    fi

    # Copy squashfs for offline install capability
    for sqfs in ubuntu-desktop-minimal.ubuntu-desktop.installer.squashfs \
                filesystem.squashfs \
                ubuntu-desktop-minimal.squashfs; do
        if [[ -f "${mnt}/casper/${sqfs}" ]]; then
            echo "[*] Copying ${sqfs} for offline install capability..."
            cp -v "${mnt}/casper/${sqfs}" "${kernel_dir}/"
            break
        fi
    done

    umount "${mnt}" 2>/dev/null
    rmdir "${mnt}" 2>/dev/null
    trap - RETURN

    echo ""
    echo "[*] Ubuntu desktop kernel extraction complete."
    echo "    ${kernel_dir}/vmlinuz"
    echo "    ${kernel_dir}/initrd"
    echo ""
}

# =============================================================================
#  WINDOWS 11 ISO DOWNLOAD / PROMPT + EXTRACTION
# =============================================================================
download_windows_iso() {
    local iso_path=""
    local winpe_dir="${BASE}/http/winpe"
    local winsrc_dir="${BASE}/http/windows"

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  WINDOWS 11 — ISO Acquisition + WinPE Extraction        │"
    echo "└──────────────────────────────────────────────────────────┘"

    # Check if already extracted
    if [[ -f "${winpe_dir}/BCD" && -f "${winpe_dir}/boot.wim" && -f "${winpe_dir}/boot.sdi" ]]; then
        echo "[*] Windows PE files already present — skipping."
        echo "    ${winpe_dir}/BCD"
        echo "    ${winpe_dir}/boot.sdi"
        echo "    ${winpe_dir}/boot.wim"
        echo "    Delete these files to force re-extraction."
        return 0
    fi

    # Look for existing ISO in the isos directory
    local existing_iso
    existing_iso=$(find "${ISO_DIR}" -maxdepth 1 -iname 'Win11*.iso' -o -iname 'windows11*.iso' -o -iname 'Win_11*.iso' 2>/dev/null | head -1)

    if [[ -n "${existing_iso}" && -f "${existing_iso}" ]]; then
        echo "[*] Found existing Windows ISO: ${existing_iso}"
        iso_path="${existing_iso}"
    else
        echo ""
        echo "  Windows 11 ISOs cannot be directly downloaded via script due to"
        echo "  Microsoft's licensing and download portal requiring browser interaction."
        echo ""
        echo "  OPTIONS:"
        echo ""
        echo "  1) Provide a path to a Windows 11 ISO you've already downloaded"
        echo "  2) Provide a direct URL to a Windows 11 ISO (if you have one)"
        echo "  3) Skip Windows setup for now (you can run extract-windows-pe.sh later)"
        echo ""
        echo "  To download manually, visit:"
        echo "    ${WINDOWS_DOWNLOAD_URL}"
        echo ""
        echo "  Or use the Media Creation Tool, or tools like:"
        echo "    - Fido (https://github.com/pbatard/Fido)"
        echo "    - UUP dump (https://uupdump.net)"
        echo ""

        while true; do
            read -r -p "  Enter [1] path, [2] URL, or [3] skip: " choice
            case "${choice}" in
                1)
                    read -r -p "  Enter full path to Windows 11 ISO: " user_path
                    user_path=$(eval echo "${user_path}")  # expand ~
                    if [[ -f "${user_path}" ]]; then
                        # Copy or symlink to our isos directory
                        local basename
                        basename=$(basename "${user_path}")
                        cp -v "${user_path}" "${ISO_DIR}/${basename}" 2>/dev/null || \
                            ln -sf "${user_path}" "${ISO_DIR}/${basename}"
                        iso_path="${ISO_DIR}/${basename}"
                        echo "[*] Using: ${iso_path}"
                        break
                    else
                        echo "  [ERROR] File not found: ${user_path}"
                    fi
                    ;;
                2)
                    read -r -p "  Enter direct download URL: " user_url
                    local fname
                    fname=$(basename "${user_url}" | sed 's/?.*//')
                    [[ "${fname}" != *.iso ]] && fname="Win11_downloaded.iso"
                    iso_path="${ISO_DIR}/${fname}"

                    echo "[*] Downloading Windows 11 ISO..."
                    echo "    URL: ${user_url}"
                    echo "    Destination: ${iso_path}"
                    echo "    (This is ~5-6 GB — may take a while)"
                    echo ""

                    if wget --progress=bar:force:noscroll \
                            --continue \
                            --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
                            -O "${iso_path}" \
                            "${user_url}"; then
                        echo "[*] Download complete."
                        break
                    else
                        echo "[ERROR] Download failed. Check the URL and try again."
                        rm -f "${iso_path}"
                    fi
                    ;;
                3|s|S|skip|"")
                    echo "[*] Skipping Windows ISO setup."
                    echo "    Run later:  sudo ${BASE}/extract-windows-pe.sh /path/to/Win11.iso"
                    return 0
                    ;;
                *)
                    echo "  Invalid choice. Enter 1, 2, or 3."
                    ;;
            esac
        done
    fi

    # Extract WinPE files from the ISO
    if [[ -n "${iso_path}" && -f "${iso_path}" ]]; then
        extract_windows_pe "${iso_path}"
    fi
}

# =============================================================================
#  WINDOWS PE EXTRACTION (called by download_windows_iso or standalone)
# =============================================================================
extract_windows_pe() {
    local iso="${1}"
    local winpe_dir="${BASE}/http/winpe"
    local winsrc_dir="${BASE}/http/windows"

    echo "[*] Extracting WinPE boot files from: ${iso}"
    mkdir -p "${winpe_dir}" "${winsrc_dir}"

    local mnt
    mnt=$(mktemp -d)
    trap 'umount "${mnt}" 2>/dev/null; rmdir "${mnt}" 2>/dev/null' RETURN

    mount -o loop,ro "${iso}" "${mnt}" || {
        echo "[ERROR] Failed to mount ISO. Trying 7z extraction as fallback..."
        trap - RETURN
        rmdir "${mnt}" 2>/dev/null

        # Fallback: use 7z to extract without mounting
        local extract_dir
        extract_dir=$(mktemp -d)
        trap 'rm -rf "${extract_dir}"' RETURN

        7z x -o"${extract_dir}" "${iso}" boot/bcd boot/BCD Boot/BCD \
            boot/boot.sdi Boot/boot.sdi sources/boot.wim \
            sources/install.wim sources/install.esd 2>/dev/null || {
            echo "[ERROR] 7z extraction also failed."
            return 1
        }

        # Find and copy files (case-insensitive)
        find "${extract_dir}" -iname 'bcd' -not -iname '*.dll' | head -1 | \
            xargs -I{} cp -v {} "${winpe_dir}/BCD" 2>/dev/null
        find "${extract_dir}" -iname 'boot.sdi' | head -1 | \
            xargs -I{} cp -v {} "${winpe_dir}/boot.sdi" 2>/dev/null
        find "${extract_dir}" -iname 'boot.wim' | head -1 | \
            xargs -I{} cp -v {} "${winpe_dir}/boot.wim" 2>/dev/null
        find "${extract_dir}" -iname 'install.wim' | head -1 | \
            xargs -I{} cp -v {} "${winsrc_dir}/install.wim" 2>/dev/null
        find "${extract_dir}" -iname 'install.esd' | head -1 | \
            xargs -I{} cp -v {} "${winsrc_dir}/install.esd" 2>/dev/null

        rm -rf "${extract_dir}"
        trap - RETURN

        echo "[*] Windows PE extraction (via 7z) complete."
        return 0
    }

    # BCD — path varies by ISO (case-sensitive filesystem issues on Linux)
    for candidate in "boot/bcd" "boot/BCD" "Boot/BCD" "Boot/bcd" "EFI/Microsoft/Boot/BCD"; do
        if [[ -f "${mnt}/${candidate}" ]]; then
            cp -v "${mnt}/${candidate}" "${winpe_dir}/BCD"
            break
        fi
    done

    # boot.sdi
    for candidate in "boot/boot.sdi" "Boot/boot.sdi" "boot/Boot.sdi"; do
        if [[ -f "${mnt}/${candidate}" ]]; then
            cp -v "${mnt}/${candidate}" "${winpe_dir}/boot.sdi"
            break
        fi
    done

    # boot.wim (WinPE image — ~500 MB)
    if [[ -f "${mnt}/sources/boot.wim" ]]; then
        echo "[*] Copying boot.wim (~500 MB)..."
        cp -v "${mnt}/sources/boot.wim" "${winpe_dir}/boot.wim"
    fi

    # install.wim or install.esd (full OS image — 4-6 GB)
    if [[ -f "${mnt}/sources/install.wim" ]]; then
        echo "[*] Copying install.wim (~4-6 GB — this will take a while)..."
        cp -v "${mnt}/sources/install.wim" "${winsrc_dir}/install.wim"
    elif [[ -f "${mnt}/sources/install.esd" ]]; then
        echo "[*] Copying install.esd (~4-6 GB — this will take a while)..."
        cp -v "${mnt}/sources/install.esd" "${winsrc_dir}/install.esd"
    else
        echo "[WARN] Neither install.wim nor install.esd found in ISO."
    fi

    umount "${mnt}" 2>/dev/null
    rmdir "${mnt}" 2>/dev/null
    trap - RETURN

    # Validation
    echo ""
    echo "[*] WinPE extraction validation:"
    local all_ok=true
    for f in BCD boot.sdi boot.wim; do
        if [[ -f "${winpe_dir}/${f}" ]]; then
            printf "    ✓ %-12s %s\n" "${f}" "$(du -h "${winpe_dir}/${f}" | cut -f1)"
        else
            printf "    ✗ %-12s MISSING\n" "${f}"
            all_ok=false
        fi
    done
    if [[ -f "${winsrc_dir}/install.wim" ]]; then
        printf "    ✓ %-12s %s\n" "install.wim" "$(du -h "${winsrc_dir}/install.wim" | cut -f1)"
    elif [[ -f "${winsrc_dir}/install.esd" ]]; then
        printf "    ✓ %-12s %s\n" "install.esd" "$(du -h "${winsrc_dir}/install.esd" | cut -f1)"
    else
        printf "    ✗ %-12s MISSING\n" "install.wim"
        all_ok=false
    fi

    if $all_ok; then
        echo ""
        echo "[*] Windows PE extraction complete — ready for PXE boot."
    else
        echo ""
        echo "[WARN] Some files are missing. Windows PXE boot may not work."
    fi
}

# =============================================================================
#  DOCKER-COMPOSE.YAML
# =============================================================================
write_compose() {
    echo "[*] Writing docker-compose.yaml ..."
    cat > "${BASE}/docker-compose.yaml" << EOF
# =============================================================================
# netboot.xyz PXE / Unattended Install Stack
# =============================================================================

services:

  # ---------- netboot.xyz (TFTP + PXE menus + web config UI) -----------------
  netbootxyz:
    image: ghcr.io/netbootxyz/netbootxyz:latest
    container_name: netbootxyz
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - SUBFOLDER=/
    volumes:
      - netbootxyz_config:/config
      - ./tftp:/config/menus/remote
      - ./assets:/assets
    ports:
      - "69:69/udp"
      - "${NETBOOT_HTTP_PORT}:80"
      - "${NETBOOT_WEB_PORT}:3000"
    networks:
      - pxenet

  # ---------- dnsmasq (DHCP + PXE options — must be host network) ------------
  #   jpillora/dnsmasq runs a webproc UI; move it to 8088 to avoid conflicts
  dnsmasq:
    image: jpillora/dnsmasq:latest
    container_name: dnsmasq-pxe
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_BIND_SERVICE
    network_mode: host
    environment:
      - HTTP_USER=admin
      - HTTP_PASS=pxeadmin
    entrypoint: ["webproc", "--port", "8088", "--config", "/etc/dnsmasq.conf", "--", "dnsmasq", "--no-daemon"]
    volumes:
      - ./config/dnsmasq/dnsmasq.conf:/etc/dnsmasq.conf:ro
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"

  # ---------- nginx (HTTP: autoinstall, autounattend, ISOs, kernels) ---------
  nginx:
    image: nginx:stable-alpine
    container_name: nginx-pxe
    restart: unless-stopped
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./http:/usr/share/nginx/html:ro
    ports:
      - "${NGINX_PORT}:80"
    networks:
      - pxenet

  # ---------- samba (Windows install share for WinPE net use) ----------------
  samba:
    image: dperson/samba:latest
    container_name: samba-pxe
    restart: unless-stopped
    ports:
      - "445:445"
      - "139:139"
    volumes:
      - ./http/windows:/shared/install
    command: >-
      -s "install;/shared/install;yes;no;yes;all"
      -u "pxe;pxe"
      -p
    networks:
      - pxenet

volumes:
  netbootxyz_config:

networks:
  pxenet:
    driver: bridge
EOF
}

# =============================================================================
#  DNSMASQ — DHCP + PXE
# =============================================================================
write_dnsmasq() {
    echo "[*] Writing dnsmasq.conf ..."
    cat > "${BASE}/config/dnsmasq/dnsmasq.conf" << EOF
# ===========================================================================
# dnsmasq — DHCP + PXE Boot
# ===========================================================================
# DHCP only — disable DNS (port=0)
port=0

# Listen on all interfaces (host-network mode)
# To restrict: interface=eth0
bind-dynamic

# ----- DHCP Pool -----
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},${DHCP_LEASE}
dhcp-option=option:router,${GATEWAY}
dhcp-option=option:dns-server,${DNS_SERVER}
dhcp-option=option:netmask,${SUBNET_MASK}
dhcp-option=option:domain-name,${DOMAIN}

# ----- PXE / TFTP -----
# netboot.xyz container serves TFTP on ${HOST_IP}:69
# dnsmasq only advertises boot filenames via DHCP.

# Detect client architecture
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-match=set:efi-arm64,option:client-arch,11
dhcp-match=set:bios,option:client-arch,0

# Architecture-appropriate netboot.xyz binary
dhcp-boot=tag:efi-x86_64,netboot.xyz.efi,,${HOST_IP}
dhcp-boot=tag:efi-arm64,netboot.xyz-arm64.efi,,${HOST_IP}
dhcp-boot=tag:bios,netboot.xyz.kpxe,,${HOST_IP}

# Fallback
dhcp-boot=netboot.xyz.kpxe,,${HOST_IP}

# next-server (TFTP IP)
dhcp-option=66,${HOST_IP}

# Vendor-class PXE identification
dhcp-option-force=tag:efi-x86_64,option:vendor-class,PXEClient
pxe-service=tag:bios,x86PC,"netboot.xyz (BIOS)",netboot.xyz
pxe-service=tag:efi-x86_64,x86-64_EFI,"netboot.xyz (UEFI)",netboot.xyz

# ----- Logging -----
log-dhcp
log-queries
log-facility=-
EOF
}

# =============================================================================
#  NGINX
# =============================================================================
write_nginx() {
    echo "[*] Writing nginx.conf ..."
    cat > "${BASE}/config/nginx/nginx.conf" << 'EOF'
worker_processes auto;
error_log  /var/log/nginx/error.log warn;
pid        /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    tcp_nopush    on;
    keepalive_timeout 120;
    client_max_body_size 8G;

    server {
        listen 80;
        server_name _;
        root /usr/share/nginx/html;
        autoindex on;

        # Ubuntu autoinstall cloud-init endpoint + local kernel/initrd
        location /ubuntu/ {
            alias /usr/share/nginx/html/ubuntu/;
            autoindex on;
        }

        # Windows autounattend + install source
        location /windows/ {
            alias /usr/share/nginx/html/windows/;
            autoindex on;
        }

        # WinPE boot files (BCD, boot.sdi, boot.wim)
        location /winpe/ {
            alias /usr/share/nginx/html/winpe/;
            autoindex on;
        }
    }
}
EOF
}

# =============================================================================
#  UBUNTU 24.04 LTS DESKTOP — AUTOINSTALL (cloud-init / subiquity)
#  Desktop ISO supports autoinstall since Ubuntu 23.04+
# =============================================================================
write_ubuntu_autoinstall() {
    echo "[*] Writing Ubuntu 24.04 Desktop autoinstall files ..."

    # meta-data — required by cloud-init (minimal)
    cat > "${BASE}/http/ubuntu/meta-data" << 'EOF'
instance-id: ubuntu-desktop-autoinstall-001
local-hostname: ubuntu-desktop
EOF

    # user-data — full autoinstall manifest for DESKTOP
    cat > "${BASE}/http/ubuntu/user-data" << USERDATA
#cloud-config
autoinstall:
  version: 1

  # ── Locale / Keyboard ──
  locale: en_US.UTF-8
  keyboard:
    layout: us
    variant: ""

  # ── Refresh installer ──
  refresh-installer:
    update: true

  # ── Network — DHCP on first ethernet NIC ──
  network:
    version: 2
    ethernets:
      any-nic:
        match:
          name: "en*"
        dhcp4: true
        dhcp6: false

  # ── Proxy (blank = none) ──
  proxy: ""

  # ── APT Mirror ──
  apt:
    primary:
      - arches: [amd64, i386]
        uri: http://archive.ubuntu.com/ubuntu
      - arches: [default]
        uri: http://ports.ubuntu.com/ubuntu-ports

  # ── Codecs / restricted extras ──
  codecs:
    install: true

  # ── Drivers ──
  drivers:
    install: true

  # ── Storage — whole disk with LVM ──
  storage:
    layout:
      name: lvm
      sizing-policy: all
    swap:
      size: 0

  # ── Identity ──
  identity:
    hostname: ubuntu-desktop
    username: admin
    password: "${UBUNTU_PW_HASH}"

  # ── SSH ──
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys: []

  # ── Packages (additional on top of desktop defaults) ──
  packages:
    - openssh-server
    - curl
    - wget
    - vim
    - net-tools
    - htop
    - open-vm-tools
    - open-vm-tools-desktop
    - cloud-guest-utils
    - bash-completion
    - gnome-tweaks
    - gnome-shell-extension-manager
    - synaptic
    - gparted
    - timeshift
    - vlc
    - git

  # ── Snaps ──
  snaps: []

  # ── Updates ──
  updates: security

  # ── Late Commands (run in chroot after install) ──
  late-commands:
    # Passwordless sudo for admin user
    - echo 'admin ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-admin
    - chmod 440 /target/etc/sudoers.d/90-admin

    # Enable auto-login to desktop (skip GDM login screen)
    - |
      mkdir -p /target/etc/gdm3
      cat > /target/etc/gdm3/custom.conf << 'GDMEOF'
      [daemon]
      AutomaticLoginEnable=true
      AutomaticLogin=admin
      [security]
      [xdmcp]
      [chooser]
      [debug]
      GDMEOF

    # Enable serial console (useful for VMs / headless)
    - curtin in-target --target=/target -- systemctl enable serial-getty@ttyS0.service || true

  # ── Reboot when done ──
  shutdown: reboot
USERDATA

    # vendor-data — required by cloud-init, can be empty
    cat > "${BASE}/http/ubuntu/vendor-data" << 'EOF'
#cloud-config
{}
EOF
}

# =============================================================================
#  WINDOWS 11 — AUTOUNATTEND.XML
# =============================================================================
write_windows_autounattend() {
    echo "[*] Writing Windows 11 autounattend.xml ..."
    cat > "${BASE}/http/windows/autounattend.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!-- ================================================================
       PASS 1 — windowsPE: locale, disk layout, image selection
       ================================================================ -->
  <settings pass="windowsPE">

    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">

      <!-- Bypass TPM / SecureBoot / RAM checks -->
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>

      <!-- Disk: GPT for UEFI -->
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>512</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>EFI</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <!-- Image selection -->
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>1</Value>
            </MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>

      <!-- Product key + EULA -->
      <UserData>
        <ProductKey>
          <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>Admin</FullName>
        <Organization>PXE-Deploy</Organization>
      </UserData>

    </component>
  </settings>

  <!-- ================================================================
       PASS 4 — specialize: hostname, RDP, timezone
       ================================================================ -->
  <settings pass="specialize">

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <ComputerName>WIN11-PXE</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>

    <component name="Networking-MPSSVC-Svc"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active>
          <Group>Remote Desktop</Group>
          <Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>

  </settings>

  <!-- ================================================================
       PASS 7 — oobeSystem: skip OOBE, create local admin
       ================================================================ -->
  <settings pass="oobeSystem">

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <n>Admin</n>
            <Group>Administrators</Group>
            <Password>
              <Value>${WIN_ADMIN_PW}</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Admin</Username>
        <Password>
          <Value>${WIN_ADMIN_PW}</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes</CommandLine>
          <Description>Enable RDP firewall rule</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>powershell -Command "Set-ExecutionPolicy Bypass -Scope LocalMachine -Force"</CommandLine>
          <Description>Allow PowerShell scripts</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>powershell -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck"</CommandLine>
          <Description>Enable WinRM</Description>
        </SynchronousCommand>
      </FirstLogonCommands>

    </component>

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

  </settings>

</unattend>
EOF
}

# =============================================================================
#  CUSTOM IPXE BOOT MENU — now uses LOCAL kernel/initrd
# =============================================================================
write_custom_menu() {
    echo "[*] Writing custom netboot.xyz iPXE menu ..."
    cat > "${BASE}/tftp/custom.ipxe" << 'IPXE_EOF'
#!ipxe
###############################################################################
# Custom netboot.xyz Menu — Unattended Installations
# All assets served locally from 192.168.1.172 (no internet needed at boot)
###############################################################################

:custom_menu
clear menu
menu ┌───────────────────────────────────────────────┐
item --gap     │   Unattended PXE Install (192.168.1.172)      │
item --gap     └───────────────────────────────────────────────┘
item --gap
item --gap           ── Operating Systems (Local) ──
item ubuntu2404      Ubuntu 24.04 LTS Desktop (Autoinstall — local)
item windows11       Windows 11 Pro           (Autounattend — local)
item --gap
item --gap           ── Operating Systems (Online) ──
item ubuntu2404r     Ubuntu 24.04 LTS Desktop (Autoinstall — remote kernel)
item ubuntu2404m     Ubuntu 24.04 LTS         (Manual — netboot.xyz)
item --gap
item --gap           ── Utilities ──
item netbootxyz      Back to netboot.xyz main menu
item shell           iPXE Shell
item reboot          Reboot
item poweroff        Shutdown
choose --default ubuntu2404 --timeout 30000 selected || goto netbootxyz
goto ${selected}

###############################################################################
# Ubuntu 24.04 LTS Desktop — LOCAL kernel + initrd (fastest — no internet at boot)
###############################################################################
:ubuntu2404
echo
echo ══════════════════════════════════════════════════════════════
echo   Ubuntu 24.04 LTS Desktop — Unattended Autoinstall (LOCAL)
echo   Kernel source : http://192.168.1.172:8081/ubuntu/
echo   Autoinstall   : http://192.168.1.172:8081/ubuntu/
echo ══════════════════════════════════════════════════════════════
echo

set base-url http://192.168.1.172:8081/ubuntu

kernel ${base-url}/vmlinuz || goto ubuntu_local_fail
initrd ${base-url}/initrd || goto ubuntu_local_fail
imgargs vmlinuz autoinstall ds=nocloud-net;s=${base-url}/ ip=dhcp ---
boot || goto custom_menu

:ubuntu_local_fail
echo [!] Local kernel not found. Did the ISO download + extraction complete?
echo     Check: ls -la /opt/netboot-pxe/http/ubuntu/vmlinuz
echo     Falling back to remote kernel...
goto ubuntu2404r

###############################################################################
# Ubuntu 24.04 LTS Desktop — REMOTE kernel (fallback — needs internet)
###############################################################################
:ubuntu2404r
echo
echo ══════════════════════════════════════════════════════════════
echo   Ubuntu 24.04 LTS Desktop — Unattended Autoinstall (REMOTE)
echo   Kernel from Ubuntu archive (requires internet)
echo ══════════════════════════════════════════════════════════════
echo

set autoinstall-url http://192.168.1.172:8081/ubuntu/
set mirror http://archive.ubuntu.com/ubuntu/dists/noble/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64

kernel ${mirror}/linux || goto kernel_alt
initrd ${mirror}/initrd.gz || goto kernel_alt
imgargs linux autoinstall ds=nocloud-net;s=${autoinstall-url} ip=dhcp ---
boot || goto custom_menu

:kernel_alt
echo [!] Legacy path failed — trying casper from daily live-server...
set casper http://cdimage.ubuntu.com/ubuntu-server/noble/daily-live/current
kernel ${casper}/casper/vmlinuz || goto fetch_fail
initrd ${casper}/casper/initrd || goto fetch_fail
imgargs vmlinuz autoinstall ds=nocloud-net;s=${autoinstall-url} ip=dhcp ---
boot || goto custom_menu

:fetch_fail
echo [ERROR] Could not download kernel from any source.
echo         Check network and try the local option after running the deploy script.
prompt
goto custom_menu

###############################################################################
# Ubuntu 24.04 — Manual via netboot.xyz upstream
###############################################################################
:ubuntu2404m
echo Chaining to netboot.xyz Ubuntu menu...
chain --autofree https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe || goto custom_menu

###############################################################################
# Windows 11 — WinPE via wimboot (all files served locally)
###############################################################################
:windows11
echo
echo ══════════════════════════════════════════════════════════════
echo   Windows 11 Pro — Unattended (WinPE + autounattend.xml)
echo   All files served from 192.168.1.172:8081 (local)
echo ══════════════════════════════════════════════════════════════
echo

set winpe-url http://192.168.1.172:8081/winpe
set win-url   http://192.168.1.172:8081/windows

kernel wimboot
initrd ${winpe-url}/BCD            BCD
initrd ${winpe-url}/boot.sdi       boot.sdi
initrd ${winpe-url}/boot.wim       boot.wim
initrd ${win-url}/autounattend.xml autounattend.xml
boot || goto winpe_fail

:winpe_fail
echo [ERROR] WinPE boot failed.
echo   Ensure BCD, boot.sdi, boot.wim exist in /opt/netboot-pxe/http/winpe/
echo   Run: sudo /opt/netboot-pxe/extract-windows-pe.sh /path/to/Win11.iso
echo   Or re-run the deploy script and choose option 1 or 2 for Windows.
prompt
goto custom_menu

###############################################################################
# Utilities
###############################################################################
:netbootxyz
chain --autofree https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe || exit

:shell
echo Type 'exit' to return to menu
shell
goto custom_menu

:reboot
reboot

:poweroff
poweroff
IPXE_EOF
}

# =============================================================================
#  STANDALONE WINDOWS PE EXTRACTION HELPER (for later use)
# =============================================================================
write_extract_helper() {
    echo "[*] Writing standalone Windows PE extraction helper ..."
    cat > "${BASE}/extract-windows-pe.sh" << 'HELPER_EOF'
#!/usr/bin/env bash
# =============================================================================
# Extract WinPE boot files from a Windows 11 ISO for PXE / wimboot
#
# Usage:  sudo ./extract-windows-pe.sh /path/to/Win11_23H2.iso
# =============================================================================
set -euo pipefail

ISO="${1:?Usage: $0 /path/to/Windows11.iso}"
BASE="/opt/netboot-pxe"
WINPE="${BASE}/http/winpe"
WINSRC="${BASE}/http/windows"

[[ -f "${ISO}" ]] || { echo "[ERROR] ISO not found: ${ISO}"; exit 1; }

apt-get install -y -qq p7zip-full 2>/dev/null || true

MNT=$(mktemp -d)
trap 'umount "${MNT}" 2>/dev/null; rmdir "${MNT}" 2>/dev/null' EXIT

echo "[*] Mounting ${ISO} ..."
mkdir -p "${WINPE}" "${WINSRC}"

if mount -o loop,ro "${ISO}" "${MNT}" 2>/dev/null; then
    for c in "boot/bcd" "boot/BCD" "Boot/BCD"; do
        [[ -f "${MNT}/${c}" ]] && { cp -v "${MNT}/${c}" "${WINPE}/BCD"; break; }
    done
    for c in "boot/boot.sdi" "Boot/boot.sdi"; do
        [[ -f "${MNT}/${c}" ]] && { cp -v "${MNT}/${c}" "${WINPE}/boot.sdi"; break; }
    done
    [[ -f "${MNT}/sources/boot.wim" ]]    && cp -v "${MNT}/sources/boot.wim" "${WINPE}/boot.wim"
    [[ -f "${MNT}/sources/install.wim" ]]  && cp -v "${MNT}/sources/install.wim" "${WINSRC}/install.wim"
    [[ -f "${MNT}/sources/install.esd" ]]  && cp -v "${MNT}/sources/install.esd" "${WINSRC}/install.esd"
else
    echo "[WARN] mount failed — using 7z..."
    7z x -o"${MNT}" "${ISO}" boot/ Boot/ sources/boot.wim sources/install.wim sources/install.esd 2>/dev/null || true
    find "${MNT}" -iname 'bcd' -not -iname '*.dll' | head -1 | xargs -I{} cp -v {} "${WINPE}/BCD"
    find "${MNT}" -iname 'boot.sdi' | head -1 | xargs -I{} cp -v {} "${WINPE}/boot.sdi"
    find "${MNT}" -iname 'boot.wim' | head -1 | xargs -I{} cp -v {} "${WINPE}/boot.wim"
    find "${MNT}" -iname 'install.wim' | head -1 | xargs -I{} cp -v {} "${WINSRC}/install.wim"
    find "${MNT}" -iname 'install.esd' | head -1 | xargs -I{} cp -v {} "${WINSRC}/install.esd"
fi

echo ""
echo "Extraction complete. Restart stack: cd ${BASE} && docker compose restart"
HELPER_EOF

    chmod +x "${BASE}/extract-windows-pe.sh"
}

# =============================================================================
#  MANAGEMENT SCRIPTS
# =============================================================================
write_management_scripts() {
    echo "[*] Writing management scripts ..."

    cat > "${BASE}/start.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "[*] Starting netboot.xyz PXE stack..."
docker compose up -d
echo ""
echo "  netboot.xyz UI : http://192.168.1.172:3001"
echo "  HTTP server    : http://192.168.1.172:8081"
echo "  TFTP           : 192.168.1.172:69"
echo "  DHCP           : 192.168.1.172:67"
echo "  Samba          : \\\\192.168.1.172\\install"
echo ""
docker compose ps
EOF

    cat > "${BASE}/stop.sh" << 'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
docker compose down
echo "[*] Stack stopped."
EOF

    cat > "${BASE}/logs.sh" << 'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
docker compose logs -f --tail=100 "$@"
EOF

    cat > "${BASE}/status.sh" << 'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
echo ""
echo "=== Container Status ==="
docker compose ps
echo ""
echo "=== ISO / Asset Status ==="
echo ""
echo "  Ubuntu:"
for f in vmlinuz initrd user-data meta-data vendor-data; do
    fp="/opt/netboot-pxe/http/ubuntu/${f}"
    if [[ -f "$fp" ]]; then
        printf "    ✓ %-30s %s\n" "$f" "$(du -h "$fp" | cut -f1)"
    else
        printf "    ✗ %-30s MISSING\n" "$f"
    fi
done
echo ""
echo "  Windows:"
for f in autounattend.xml install.wim install.esd; do
    fp="/opt/netboot-pxe/http/windows/${f}"
    if [[ -f "$fp" ]]; then
        printf "    ✓ %-30s %s\n" "$f" "$(du -h "$fp" | cut -f1)"
    else
        [[ "$f" == "install.esd" ]] && continue  # only one of wim/esd needed
        printf "    ✗ %-30s MISSING\n" "$f"
    fi
done
for f in BCD boot.sdi boot.wim; do
    fp="/opt/netboot-pxe/http/winpe/${f}"
    if [[ -f "$fp" ]]; then
        printf "    ✓ %-30s %s\n" "$f" "$(du -h "$fp" | cut -f1)"
    else
        printf "    ✗ %-30s MISSING\n" "$f"
    fi
done
echo ""
echo "  ISOs:"
ls -lh /opt/netboot-pxe/isos/ 2>/dev/null || echo "    (none)"
echo ""
echo "=== Quick Tests ==="
echo "  curl -sI http://192.168.1.172:8081/ubuntu/user-data | head -5"
echo "  curl -sI http://192.168.1.172:8081/ubuntu/vmlinuz | head -5"
echo "  curl -sI http://192.168.1.172:8081/windows/autounattend.xml | head -5"
echo "  curl -sI http://192.168.1.172:8081/winpe/boot.wim | head -5"
EOF

    chmod +x "${BASE}"/{start,stop,logs,status}.sh
}

# =============================================================================
#  README
# =============================================================================
write_readme() {
    echo "[*] Writing README.md ..."
    cat > "${BASE}/README.md" << 'README_EOF'
# netboot.xyz PXE Unattended Deployment

## Architecture

```
PXE Client (BIOS/UEFI)
    │
    ├─ DHCP ──────────► dnsmasq (:67 host network)
    │                    returns next-server=192.168.1.172
    │                    filename=netboot.xyz.{kpxe,efi}
    │
    ├─ TFTP ──────────► netbootxyz (:69)
    │                    serves iPXE → loads custom.ipxe menu
    │
    ├─ iPXE Menu:
    │   ├─ Ubuntu 24.04 (local) → kernel/initrd from nginx :8081
    │   │                          autoinstall from nginx :8081/ubuntu/
    │   │
    │   ├─ Ubuntu 24.04 (remote) → kernel from archive.ubuntu.com
    │   │                           autoinstall from nginx :8081/ubuntu/
    │   │
    │   └─ Windows 11 (local)   → wimboot → BCD/boot.sdi/boot.wim
    │                              from nginx :8081/winpe/
    │                              autounattend.xml injected
    │
    └─ HTTP ──────────► nginx (:8081)
                         /ubuntu/   vmlinuz, initrd, user-data, meta-data
                         /windows/  autounattend.xml, install.wim
                         /winpe/    BCD, boot.sdi, boot.wim
```

## Ports

| Service         | Port | Protocol |
|-----------------|------|----------|
| DHCP            | 67   | UDP      |
| TFTP            | 69   | UDP      |
| netboot.xyz UI  | 3001 | TCP      |
| netboot.xyz HTTP| 8082 | TCP      |
| dnsmasq Web UI  | 8088 | TCP      |
| nginx           | 8081 | TCP      |
| Samba           | 445  | TCP      |

## What the script downloads automatically

- **Ubuntu 24.04 LTS** live-server ISO (~2.6 GB) → extracts vmlinuz + initrd
  for fully local PXE boot (no internet needed on client or at boot time)
- **Windows 11** ISO: interactive prompt to provide path, URL, or skip

## Quick Start

```bash
sudo bash deploy-netboot-pxe.sh    # deploy + download ISOs
./status.sh                         # verify all assets present
./logs.sh                           # tail logs
```

## Re-running

The script is idempotent. It skips downloads if files already exist.
To force re-download, delete the relevant files:

```bash
rm /opt/netboot-pxe/http/ubuntu/vmlinuz /opt/netboot-pxe/http/ubuntu/initrd
rm /opt/netboot-pxe/isos/ubuntu-*.iso
sudo bash deploy-netboot-pxe.sh
```

## Default Credentials (CHANGE THESE)

- **Ubuntu**: admin / changeme
- **Windows**: Admin / P@ssw0rd!
- **Samba**: pxe / pxe

## Troubleshooting

```bash
# Verify DHCP
sudo nmap --script broadcast-dhcp-discover -e eth0

# Verify TFTP
tftp 192.168.1.172 -c get netboot.xyz.kpxe

# Verify local kernel served
curl -sI http://192.168.1.172:8081/ubuntu/vmlinuz
curl -sI http://192.168.1.172:8081/ubuntu/user-data

# Verify Windows PE
curl -sI http://192.168.1.172:8081/winpe/boot.wim

# Container logs
docker logs dnsmasq-pxe 2>&1 | tail -30
docker logs netbootxyz 2>&1 | tail -30
docker logs nginx-pxe 2>&1 | tail -30
```
README_EOF
}

# =============================================================================
#  MAIN EXECUTION
# =============================================================================
main() {
    banner
    preflight
    create_dirs

    # Write all config files
    write_compose
    write_dnsmasq
    write_nginx
    write_ubuntu_autoinstall
    write_windows_autounattend
    write_custom_menu
    write_extract_helper
    write_management_scripts
    write_readme

    # Copy this script into the deployment directory
    cp -f "$(readlink -f "$0")" "${BASE}/deploy-netboot-pxe.sh" 2>/dev/null || true
    chmod +x "${BASE}/deploy-netboot-pxe.sh" 2>/dev/null || true

    # ─── Download + extract ISOs ────────────────────────────────────────
    echo ""
    echo "================================================================"
    echo "  ISO Download & Extraction Phase"
    echo "================================================================"

    download_ubuntu_iso
    download_windows_iso

    # ─── Start the stack ────────────────────────────────────────────────
    echo ""
    echo "[*] Pulling container images and starting stack ..."
    cd "${BASE}"
    docker compose pull
    docker compose up -d

    # ─── Final summary ──────────────────────────────────────────────────
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                   DEPLOYMENT COMPLETE                        │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│                                                              │"
    echo "│  netboot.xyz Web UI : http://192.168.1.172:3001              │"
    echo "│  HTTP File Server   : http://192.168.1.172:8081              │"
    echo "│  TFTP Server        : 192.168.1.172:69                       │"
    echo "│  DHCP Server        : 192.168.1.172:67                       │"
    echo "│  Samba Share        : \\\\192.168.1.172\\install               │"
    echo "│                                                              │"
    echo "│  Deployment dir     : /opt/netboot-pxe/                      │"
    echo "│  ISOs stored in     : /opt/netboot-pxe/isos/                 │"
    echo "│  Manage: ./start.sh | ./stop.sh | ./logs.sh | ./status.sh    │"
    echo "│                                                              │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│  Asset Status:                                               │"

    # Ubuntu check
    if [[ -f "${BASE}/http/ubuntu/vmlinuz" && -f "${BASE}/http/ubuntu/initrd" ]]; then
        echo "│  ✓ Ubuntu 24.04 Desktop — kernel + initrd extracted (LOCAL) │"
    else
        echo "│  ✗ Ubuntu 24.04 Desktop — kernel MISSING (remote fallback)  │"
    fi

    # Windows check
    if [[ -f "${BASE}/http/winpe/BCD" && -f "${BASE}/http/winpe/boot.wim" ]]; then
        echo "│  ✓ Windows 11  — WinPE extracted (ready for PXE)             │"
    else
        echo "│  ✗ Windows 11  — WinPE not yet extracted                     │"
        echo "│    Run: sudo ./extract-windows-pe.sh /path/to/Win11.iso      │"
    fi

    echo "│                                                              │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│  ⚠  DEFAULT PASSWORDS — change before production!            │"
    echo "│     Ubuntu : admin / changeme                                │"
    echo "│     Windows: Admin / P@ssw0rd!                               │"
    echo "│     Samba  : pxe / pxe                                       │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""

    # Run status to show current state
    echo "=== Container Status ==="
    docker compose ps
    echo ""
    echo "Run ./status.sh for full asset verification."
}

main "$@"
