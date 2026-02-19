#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# netboot PXE + unattended Ubuntu (v5.12)
# - Strict 2-stage iPXE chainloading (ProxyDHCP)
# - Uses ACTUAL desktop ISO for desktop, server ISO for server
# - Each target has own kernel/initrd/ISO from matching ISO
# - imgargs iPXE pattern with ds=nocloud-net for autoinstall
# - First-boot systemd service installs packages after reboot
# - Includes Chrome, VLC, Docker, openssh-server etc. by default
# ==============================================================================

# ----------------------------- Config -----------------------------------------
HOST_IP="${HOST_IP:-192.168.1.172}"
GATEWAY="${GATEWAY:-192.168.1.1}" # informational only
SUBNET="${SUBNET:-192.168.1.0}"
SUBNET_MASK="${SUBNET_MASK:-255.255.255.0}"
TIMEZONE="${TIMEZONE:-UTC}"

BASE="${BASE:-/opt/netboot-pxe}"
TFTP_ROOT="${TFTP_ROOT:-$BASE/tftp}"
ISO_DIR="${ISO_DIR:-$BASE/isos}"
NGINX_PORT="${NGINX_PORT:-8081}"

UBUNTU_RELEASE_PAGE="${UBUNTU_RELEASE_PAGE:-https://releases.ubuntu.com/noble/}"
WINDOWS_DOWNLOAD_URL="${WINDOWS_DOWNLOAD_URL:-https://www.microsoft.com/en-us/software-download/windows11}"
WINDOWS_ISO_PATH="${WINDOWS_ISO_PATH:-}"
WINDOWS_ISO_URL="${WINDOWS_ISO_URL:-}"

UBUNTU_USERNAME="${UBUNTU_USERNAME:-admin}"
UBUNTU_PASSWORD="${UBUNTU_PASSWORD:-admin}"
UBUNTU_HOSTNAME_SERVER="${UBUNTU_HOSTNAME_SERVER:-ubuntu-server}"
UBUNTU_HOSTNAME_DESKTOP="${UBUNTU_HOSTNAME_DESKTOP:-ubuntu-desktop}"

UBUNTU_PW_HASH="${UBUNTU_PW_HASH:-}"
if [[ -z "$UBUNTU_PW_HASH" ]]; then
  UBUNTU_PW_HASH=$(openssl passwd -6 "$UBUNTU_PASSWORD" 2>/dev/null) || \
  UBUNTU_PW_HASH=$(python3 -c "import crypt; print(crypt.crypt('${UBUNTU_PASSWORD}', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null) || \
  UBUNTU_PW_HASH='$6$rounds=4096$xYzSalt1234$V7kGQ0VqjGfOQh8v4N6YpqKmXr0B6bLpZs9kW2MxDlPmJcT3HWYn7.fN8xXoFZ7r2eU5y0K3cB1aW4dM9sQ5t.'
fi

# ── First-boot packages ──
# These are installed via apt after first reboot (with full network).
# Override any of these with environment variables before running.
FIRSTBOOT_PACKAGES_COMMON="${FIRSTBOOT_PACKAGES_COMMON:-openssh-server curl wget vim htop net-tools git ca-certificates gnupg lsb-release}"
FIRSTBOOT_PACKAGES_DESKTOP="${FIRSTBOOT_PACKAGES_DESKTOP:-vlc}"
FIRSTBOOT_PACKAGES_SERVER="${FIRSTBOOT_PACKAGES_SERVER:-}"

# These require adding external repos first (handled in firstboot script)
INSTALL_CHROME="${INSTALL_CHROME:-yes}"
INSTALL_DOCKER="${INSTALL_DOCKER:-yes}"

# Optional: path to a custom first-boot script to run AFTER package installation.
#   FIRSTBOOT_CUSTOM_SCRIPT="/path/to/my-setup.sh" ./deploy.sh
FIRSTBOOT_CUSTOM_SCRIPT="${FIRSTBOOT_CUSTOM_SCRIPT:-}"

WIN_ADMIN_USER="${WIN_ADMIN_USER:-Admin}"
WIN_ADMIN_PW="${WIN_ADMIN_PW:-P@ssw0rd!}"

# ----------------------------- helpers ----------------------------------------
die(){ echo "[ERROR] $*" >&2; exit 1; }

banner() {
cat <<EOF

┌────────────────────────────────────────────────────────────┐
│ netboot PXE Deployment (v5.12)                            │
│ Host IP: ${HOST_IP} | HTTP: ${NGINX_PORT} | TFTP: 69/udp  │
│ ProxyDHCP mode (router DHCP untouched: ${GATEWAY})        │
│ Desktop ISO for desktop, Server ISO for server            │
└────────────────────────────────────────────────────────────┘
EOF
}

safe_apt_update() {
  apt-get update -qq && return 0 || true
  echo "[*] apt update had errors; temporarily disabling broken third-party repos..."
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list; do
    if apt-get update -o Dir::Etc::sourcelist="$f" -o Dir::Etc::sourceparts="/dev/null" 2>&1 | \
      grep -qiE "does not have a Release|is not signed|EXPKEYSIG"; then
      mv "$f" "$f.disabled"
    fi
  done
  apt-get update -qq || true
  for f in /etc/apt/sources.list.d/*.disabled; do mv "$f" "${f%.disabled}"; done
  shopt -u nullglob
}

fetch_to_file() {
  local out="$1"; shift
  local u
  for u in "$@"; do
    [[ -n "$u" ]] || continue
    wget -q -O "$out" "$u" && [[ -s "$out" ]] && return 0
    curl -fsSL "$u" -o "$out" && [[ -s "$out" ]] && return 0
  done
  return 1
}

extract_iso_artifacts() {
  local iso_path="$1"
  local target_dir="$2"
  local canonical_iso_name="$3"
  local mnt

  rm -f "$target_dir/vmlinuz" "$target_dir/initrd"
  mnt=$(mktemp -d)
  mount -o loop,ro "$iso_path" "$mnt"

  if [[ -f "$mnt/casper/vmlinuz" ]]; then
    cp -f "$mnt/casper/vmlinuz" "$target_dir/vmlinuz"
  elif [[ -f "$mnt/casper/vmlinuz.efi" ]]; then
    cp -f "$mnt/casper/vmlinuz.efi" "$target_dir/vmlinuz"
  else
    umount "$mnt" || true; rmdir "$mnt" || true
    die "vmlinuz missing in $(basename "$iso_path")"
  fi

  if [[ -f "$mnt/casper/initrd" ]]; then
    cp -f "$mnt/casper/initrd" "$target_dir/initrd"
  else
    local found=0
    for f in initrd.lz initrd.gz; do
      if [[ -f "$mnt/casper/$f" ]]; then
        cp -f "$mnt/casper/$f" "$target_dir/initrd"
        found=1; break
      fi
    done
    [[ $found -eq 1 ]] || { umount "$mnt" || true; rmdir "$mnt" || true; die "initrd missing in $(basename "$iso_path")"; }
  fi

  umount "$mnt"; rmdir "$mnt"

  rm -f "$target_dir/$canonical_iso_name"
  ln -f "$iso_path" "$target_dir/$canonical_iso_name" 2>/dev/null || \
    cp -f "$iso_path" "$target_dir/$canonical_iso_name"
}

# ----------------------------- install/prep -----------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root"

  if ! command -v docker >/dev/null 2>&1; then
    echo "[*] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose v2 required"

  echo "[*] Installing prerequisites..."
  safe_apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    p7zip-full curl wget ca-certificates iproute2 tftp-hpa ipxe openssl wimtools >/dev/null 2>&1 || true

  echo "[*] Stopping conflicting local DHCP/TFTP services..."
  for svc in isc-dhcp-server isc-dhcp-server6 dnsmasq tftpd-hpa; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  modprobe nf_conntrack_tftp 2>/dev/null || true
  echo "nf_conntrack_tftp" >/etc/modules-load.d/tftp-conntrack.conf 2>/dev/null || true
}

create_dirs() {
  echo "[*] Creating directories..."
  mkdir -p "$BASE"/{config/{dnsmasq,nginx},http/{ubuntu-desktop,ubuntu-server,windows,winpe},assets}
  mkdir -p "$TFTP_ROOT" "$ISO_DIR"
}

# ----------------------------- configs ----------------------------------------
write_compose() {
  echo "[*] Writing docker-compose.yaml..."
  cat >"$BASE/docker-compose.yaml" <<EOF
services:
  dnsmasq:
    image: alpine:latest
    container_name: dnsmasq-pxe
    restart: unless-stopped
    network_mode: host
    cap_add: [NET_ADMIN, NET_BIND_SERVICE]
    command: sh -c "apk add --no-cache dnsmasq && dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf --log-facility=-"
    volumes:
      - ./config/dnsmasq/dnsmasq.conf:/etc/dnsmasq.conf:ro
      - ./tftp:/var/lib/tftpboot:ro

  nginx:
    image: nginx:stable-alpine
    container_name: nginx-pxe
    restart: unless-stopped
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./http:/usr/share/nginx/html:ro
    ports: ["${NGINX_PORT}:80"]

  samba:
    image: dperson/samba:latest
    container_name: samba-pxe
    restart: unless-stopped
    ports: ["445:445","139:139"]
    volumes: ["./http/windows:/shared/install"]
    command: -s "install;/shared/install;yes;no;yes;all" -u "pxe;pxe" -p
EOF
}

write_dnsmasq() {
  echo "[*] Writing dnsmasq.conf..."
  cat >"$BASE/config/dnsmasq/dnsmasq.conf" <<EOF
port=0
bind-dynamic
dhcp-range=${SUBNET},proxy,${SUBNET_MASK}

enable-tftp
tftp-root=/var/lib/tftpboot
tftp-no-fail
tftp-no-blocksize
dhcp-no-override
dhcp-option=vendor:PXEClient,6,2b

dhcp-userclass=set:ipxe,iPXE

dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-match=set:bios,option:client-arch,0

pxe-service=tag:!ipxe,x86PC,"iPXE BIOS",undionly.kpxe,${HOST_IP}
pxe-service=tag:!ipxe,x86-64_EFI,"iPXE UEFI x64",snponly.efi,${HOST_IP}
dhcp-boot=tag:!ipxe,tag:efi-x86_64,snponly.efi,,${HOST_IP}
dhcp-boot=tag:!ipxe,tag:bios,undionly.kpxe,,${HOST_IP}
dhcp-boot=tag:!ipxe,undionly.kpxe,,${HOST_IP}

dhcp-boot=tag:ipxe,http://${HOST_IP}:${NGINX_PORT}/custom.ipxe

log-dhcp
log-queries
log-facility=-
EOF
}

write_nginx() {
  echo "[*] Writing nginx.conf..."
  cat >"$BASE/config/nginx/nginx.conf" <<'EOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;
events { worker_connections 1024; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;
  tcp_nopush on;
  keepalive_timeout 300;
  client_max_body_size 0;
  proxy_buffering off;
  log_format pxe '$remote_addr [$time_local] "$request" $status $body_bytes_sent';
  access_log /var/log/nginx/access.log pxe;
  server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    autoindex on;

    location ~ /user-data$ { default_type text/yaml; }
    location ~ /meta-data$ { default_type text/yaml; }
    location ~ /vendor-data$ { default_type text/yaml; }

    location ~* \.iso$ { sendfile off; tcp_nopush off; directio 512; }
    location /ubuntu-desktop/ { alias /usr/share/nginx/html/ubuntu-desktop/; autoindex on; }
    location /ubuntu-server/  { alias /usr/share/nginx/html/ubuntu-server/;  autoindex on; }
    location /windows/        { alias /usr/share/nginx/html/windows/;        autoindex on; }
    location /winpe/          { alias /usr/share/nginx/html/winpe/;          autoindex on; }
  }
}
EOF
}

write_custom_ipxe() {
  echo "[*] Writing custom.ipxe..."
  cat >"$TFTP_ROOT/custom.ipxe" <<EOF
#!ipxe
:start
menu PXE Deployment Server (${HOST_IP})
item --gap -- ---------------- Unattended ----------------
item ubuntu-desktop Ubuntu 24.04 Desktop (hands-off)
item ubuntu-server  Ubuntu 24.04 Server  (hands-off)
item windows11      Windows 11 Pro (autounattend, if staged)
item --gap -- ---------------- Other ---------------------
item netbootxyz     netboot.xyz full menu (online)
item shell          iPXE shell
item reboot         Reboot
item poweroff       Shutdown
choose --default ubuntu-desktop --timeout 15000 selected || goto ubuntu-desktop
goto \${selected}

:ubuntu-desktop
set base http://${HOST_IP}:${NGINX_PORT}/ubuntu-desktop
kernel \${base}/vmlinuz
initrd \${base}/initrd
imgargs vmlinuz initrd=initrd ip=dhcp root=/dev/ram0 ramdisk_size=8388608 cloud-config-url=/dev/null url=\${base}/ubuntu-24.04-desktop-amd64.iso autoinstall ds=nocloud-net;s=\${base}/ apport=0
boot || goto fail

:ubuntu-server
set base http://${HOST_IP}:${NGINX_PORT}/ubuntu-server
kernel \${base}/vmlinuz
initrd \${base}/initrd
imgargs vmlinuz initrd=initrd ip=dhcp root=/dev/ram0 ramdisk_size=1500000 cloud-config-url=/dev/null url=\${base}/ubuntu-24.04-live-server-amd64.iso autoinstall ds=nocloud-net;s=\${base}/ apport=0
boot || goto fail

:windows11
set winpe http://${HOST_IP}:${NGINX_PORT}/winpe
set win   http://${HOST_IP}:${NGINX_PORT}/windows
kernel \${winpe}/wimboot || goto fail
initrd \${winpe}/BCD            BCD || goto fail
initrd \${winpe}/boot.sdi       boot.sdi || goto fail
initrd \${winpe}/boot.wim       boot.wim || goto fail
initrd \${win}/autounattend.xml autounattend.xml || goto fail
boot || goto fail

:netbootxyz
chain --autofree https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe || goto fail

:fail
echo Boot failed. Check logs and /opt/netboot-pxe/test.sh
prompt Press key to return...
goto start
:shell
shell
goto start
:reboot
reboot
:poweroff
poweroff
EOF
  cp -f "$TFTP_ROOT/custom.ipxe" "$BASE/http/custom.ipxe"
  sed -i 's/\r$//' "$TFTP_ROOT/custom.ipxe" "$BASE/http/custom.ipxe"
}

write_firstboot_scripts() {
  echo "[*] Writing first-boot provisioning scripts..."

  # ── First-boot script for DESKTOP ──
  # Variables are expanded NOW (at deploy time) and baked into the script.
  cat >"$BASE/http/ubuntu-desktop/pxe-firstboot.sh" <<FBEOF
#!/usr/bin/env bash
# PXE first-boot provisioning (desktop) - runs once then removes itself
set -x
exec &>/var/log/pxe-firstboot.log

echo "[\$(date)] PXE first-boot provisioning starting..."

# Wait for network (up to 90s)
for i in \$(seq 1 90); do
  ping -c1 -W1 archive.ubuntu.com >/dev/null 2>&1 && break
  sleep 1
done

export DEBIAN_FRONTEND=noninteractive

apt-get update -q || true

# ── Standard apt packages ──
apt-get install -y ${FIRSTBOOT_PACKAGES_COMMON} || true
apt-get install -y ${FIRSTBOOT_PACKAGES_DESKTOP} || true

# ── Google Chrome ──
if [[ "${INSTALL_CHROME}" == "yes" ]]; then
  echo "[\$(date)] Installing Google Chrome..."
  wget -q -O /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || true
  apt-get install -y /tmp/google-chrome.deb || true
  rm -f /tmp/google-chrome.deb
fi

# ── Docker ──
if [[ "${INSTALL_DOCKER}" == "yes" ]]; then
  echo "[\$(date)] Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || true
  chmod a+r /etc/apt/keyrings/docker.asc || true
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo "\\\$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list || true
  apt-get update -q || true
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
  usermod -aG docker ${UBUNTU_USERNAME} || true
  systemctl enable docker || true
  systemctl start docker || true
fi

# Enable SSH if installed
systemctl enable ssh 2>/dev/null || true
systemctl start ssh 2>/dev/null || true

# Run custom script if present
if [[ -x /opt/pxe-firstboot-custom.sh ]]; then
  echo "[\$(date)] Running custom first-boot script..."
  /opt/pxe-firstboot-custom.sh || true
fi

# Clean up
apt-get autoremove -y || true
apt-get clean || true

# Disable and remove this service
systemctl disable pxe-firstboot.service
rm -f /etc/systemd/system/pxe-firstboot.service
rm -f /opt/pxe-firstboot.sh

echo "[\$(date)] PXE first-boot provisioning complete."
FBEOF

  # ── First-boot script for SERVER ──
  cat >"$BASE/http/ubuntu-server/pxe-firstboot.sh" <<FBEOF
#!/usr/bin/env bash
# PXE first-boot provisioning (server) - runs once then removes itself
set -x
exec &>/var/log/pxe-firstboot.log

echo "[\$(date)] PXE first-boot provisioning starting..."

# Wait for network (up to 90s)
for i in \$(seq 1 90); do
  ping -c1 -W1 archive.ubuntu.com >/dev/null 2>&1 && break
  sleep 1
done

export DEBIAN_FRONTEND=noninteractive

apt-get update -q || true

# ── Standard apt packages ──
apt-get install -y ${FIRSTBOOT_PACKAGES_COMMON} || true
apt-get install -y ${FIRSTBOOT_PACKAGES_SERVER} || true

# ── Docker ──
if [[ "${INSTALL_DOCKER}" == "yes" ]]; then
  echo "[\$(date)] Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || true
  chmod a+r /etc/apt/keyrings/docker.asc || true
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo "\\\$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list || true
  apt-get update -q || true
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
  usermod -aG docker ${UBUNTU_USERNAME} || true
  systemctl enable docker || true
  systemctl start docker || true
fi

# Run custom script if present
if [[ -x /opt/pxe-firstboot-custom.sh ]]; then
  echo "[\$(date)] Running custom first-boot script..."
  /opt/pxe-firstboot-custom.sh || true
fi

# Clean up
apt-get autoremove -y || true
apt-get clean || true

# Disable and remove this service
systemctl disable pxe-firstboot.service
rm -f /etc/systemd/system/pxe-firstboot.service
rm -f /opt/pxe-firstboot.sh

echo "[\$(date)] PXE first-boot provisioning complete."
FBEOF

  # ── systemd unit (same for both) ──
  for p in ubuntu-server ubuntu-desktop; do
    cat >"$BASE/http/$p/pxe-firstboot.service" <<'SVCEOF'
[Unit]
Description=PXE First-Boot Provisioning
After=network-online.target
Wants=network-online.target
ConditionPathExists=/opt/pxe-firstboot.sh

[Service]
Type=oneshot
ExecStart=/opt/pxe-firstboot.sh
RemainAfterExit=false
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
SVCEOF
  done

  # ── Embed custom script if provided ──
  if [[ -n "$FIRSTBOOT_CUSTOM_SCRIPT" && -f "$FIRSTBOOT_CUSTOM_SCRIPT" ]]; then
    echo "[*] Embedding custom first-boot script: $FIRSTBOOT_CUSTOM_SCRIPT"
    for p in ubuntu-server ubuntu-desktop; do
      cp -f "$FIRSTBOOT_CUSTOM_SCRIPT" "$BASE/http/$p/pxe-firstboot-custom.sh"
      chmod +x "$BASE/http/$p/pxe-firstboot-custom.sh"
    done
  fi

  chmod +x "$BASE/http/ubuntu-desktop/pxe-firstboot.sh"
  chmod +x "$BASE/http/ubuntu-server/pxe-firstboot.sh"
}

write_seeds() {
  echo "[*] Writing autoinstall seeds..."

  # ── Server seed ──
  cat >"$BASE/http/ubuntu-server/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_GB.UTF-8
  keyboard:
    layout: gb
    variant: ""
  timezone: ${TIMEZONE}
  source:
    id: ubuntu-server
    search_drivers: false
  network:
    version: 2
    ethernets:
      any:
        match:
          name: "e*"
        dhcp4: true
  storage:
    layout:
      name: lvm
  identity:
    hostname: ${UBUNTU_HOSTNAME_SERVER}
    username: ${UBUNTU_USERNAME}
    password: "${UBUNTU_PW_HASH}"
  ssh:
    install-server: false
    allow-pw: true
  updates: security
  late-commands:
    - echo '${UBUNTU_USERNAME} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-${UBUNTU_USERNAME}
    - chmod 440 /target/etc/sudoers.d/90-${UBUNTU_USERNAME}
    - sed -i 's/enabled=1/enabled=0/' /target/etc/default/apport || true
    - curtin in-target --target=/target -- systemctl disable apport.service || true
    - curtin in-target --target=/target -- systemctl mask apport.service || true
    # Install first-boot provisioning service
    - wget -q -O /target/opt/pxe-firstboot.sh http://${HOST_IP}:${NGINX_PORT}/ubuntu-server/pxe-firstboot.sh || true
    - chmod +x /target/opt/pxe-firstboot.sh || true
    - wget -q -O /target/etc/systemd/system/pxe-firstboot.service http://${HOST_IP}:${NGINX_PORT}/ubuntu-server/pxe-firstboot.service || true
    - curtin in-target --target=/target -- systemctl enable pxe-firstboot.service || true
    - wget -q -O /target/opt/pxe-firstboot-custom.sh http://${HOST_IP}:${NGINX_PORT}/ubuntu-server/pxe-firstboot-custom.sh && chmod +x /target/opt/pxe-firstboot-custom.sh || true
  shutdown: reboot
EOF

  # ── Desktop seed ──
  cat >"$BASE/http/ubuntu-desktop/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_GB.UTF-8
  keyboard:
    layout: gb
    variant: ""
  timezone: ${TIMEZONE}
  source:
    id: ubuntu-desktop-minimal
    search_drivers: false
  network:
    version: 2
    renderer: NetworkManager
    ethernets:
      any:
        match:
          name: "e*"
        dhcp4: true
  storage:
    layout:
      name: lvm
  identity:
    hostname: ${UBUNTU_HOSTNAME_DESKTOP}
    username: ${UBUNTU_USERNAME}
    password: "${UBUNTU_PW_HASH}"
  ssh:
    install-server: false
    allow-pw: true
  updates: security
  late-commands:
    - echo '${UBUNTU_USERNAME} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-${UBUNTU_USERNAME}
    - chmod 440 /target/etc/sudoers.d/90-${UBUNTU_USERNAME}
    - sed -i 's/enabled=1/enabled=0/' /target/etc/default/apport || true
    - curtin in-target --target=/target -- systemctl disable apport.service || true
    - curtin in-target --target=/target -- systemctl mask apport.service || true
    - curtin in-target --target=/target -- systemctl disable whoopsie.service || true
    - curtin in-target --target=/target -- systemctl mask whoopsie.service || true
    - mkdir -p /target/etc/dconf/db/local.d || true
    - 'echo "[com.ubuntu.update-notifier]" > /target/etc/dconf/db/local.d/99-no-crash-dialog || true'
    - 'echo "show-apport-crashes=false" >> /target/etc/dconf/db/local.d/99-no-crash-dialog || true'
    - curtin in-target --target=/target -- dconf update || true
    # Install first-boot provisioning service
    - wget -q -O /target/opt/pxe-firstboot.sh http://${HOST_IP}:${NGINX_PORT}/ubuntu-desktop/pxe-firstboot.sh || true
    - chmod +x /target/opt/pxe-firstboot.sh || true
    - wget -q -O /target/etc/systemd/system/pxe-firstboot.service http://${HOST_IP}:${NGINX_PORT}/ubuntu-desktop/pxe-firstboot.service || true
    - curtin in-target --target=/target -- systemctl enable pxe-firstboot.service || true
    - wget -q -O /target/opt/pxe-firstboot-custom.sh http://${HOST_IP}:${NGINX_PORT}/ubuntu-desktop/pxe-firstboot-custom.sh && chmod +x /target/opt/pxe-firstboot-custom.sh || true
  shutdown: reboot
EOF

  # ── NoCloud meta-data + vendor-data for both ──
  for p in ubuntu-server ubuntu-desktop; do
    cat >"$BASE/http/$p/meta-data" <<EOF
instance-id: ${p}-001
local-hostname: ${p}
EOF
    cat >"$BASE/http/$p/vendor-data" <<'EOF'
#cloud-config
{}
EOF
  done

  sed -i 's/\r$//' "$BASE"/http/ubuntu-{desktop,server}/{user-data,meta-data,vendor-data}
}

write_windows_autounattend() {
  echo "[*] Writing windows/autounattend.xml..."
  cat >"$BASE/http/windows/autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration><WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>512</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>128</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>EFI</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall><OSImage>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>
      </OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>${WIN_ADMIN_USER}</FullName><Organization>PXE</Organization></UserData>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts><LocalAccounts>
        <LocalAccount wcm:action="add"><n>${WIN_ADMIN_USER}</n><Group>Administrators</Group>
          <Password><Value>${WIN_ADMIN_PW}</Value><PlainText>true</PlainText></Password>
        </LocalAccount>
      </LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>${WIN_ADMIN_USER}</Username>
        <Password><Value>${WIN_ADMIN_PW}</Value><PlainText>true</PlainText></Password><LogonCount>1</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
EOF
}

# ----------------------------- payloads ---------------------------------------
download_ipxe_bootstrap() {
  echo "[*] Downloading iPXE bootstrap files..."
  local undi="$TFTP_ROOT/undionly.kpxe"
  local snp="$TFTP_ROOT/snponly.efi"
  local wim="$TFTP_ROOT/wimboot"

  [[ -r /usr/lib/ipxe/undionly.kpxe ]] && cp -f /usr/lib/ipxe/undionly.kpxe "$undi"
  [[ -r /usr/lib/ipxe/snponly.efi ]]  && cp -f /usr/lib/ipxe/snponly.efi "$snp"
  [[ -r /usr/lib/ipxe/ipxe.efi && ! -s "$snp" ]] && cp -f /usr/lib/ipxe/ipxe.efi "$snp"

  [[ -s "$undi" ]] || fetch_to_file "$undi" \
    "http://boot.ipxe.org/undionly.kpxe" "https://boot.ipxe.org/undionly.kpxe" || die "Failed downloading undionly.kpxe"

  [[ -s "$snp" ]] || fetch_to_file "$snp" \
    "http://boot.ipxe.org/x86_64-efi/snponly.efi" \
    "https://boot.ipxe.org/x86_64-efi/snponly.efi" \
    "http://boot.ipxe.org/x86_64-efi/ipxe.efi" \
    "https://boot.ipxe.org/x86_64-efi/ipxe.efi" || die "Failed downloading snponly.efi/ipxe.efi"

  [[ -s "$wim" ]] || fetch_to_file "$wim" \
    "http://boot.ipxe.org/wimboot" "https://boot.ipxe.org/wimboot" \
    "https://github.com/ipxe/wimboot/releases/latest/download/wimboot" || die "Failed downloading wimboot"

  install -m 0644 "$wim" "$BASE/http/winpe/wimboot"
  ls -lh "$undi" "$snp" "$wim" | awk '{print "    "$NF" "$5}'
}

download_ubuntu_iso() {
  local pattern="$1"
  local fallback_name="$2"
  local iso_dir="$3"
  local iso_name iso_url iso_path existing

  iso_name=$(wget -qO- "$UBUNTU_RELEASE_PAGE" 2>/dev/null \
    | grep -oP "${pattern}" | sort -V | tail -1 || true)
  [[ -n "${iso_name:-}" ]] || iso_name="$fallback_name"
  iso_url="${UBUNTU_RELEASE_PAGE}${iso_name}"
  iso_path="${iso_dir}/${iso_name}"

  existing=$(find "$iso_dir" -maxdepth 1 -name "${fallback_name%.iso}*.iso" | sort -V | tail -1 || true)
  if [[ -n "${existing:-}" && -f "$existing" ]]; then
    iso_path="$existing"
    echo "[*] Using existing $(basename "$iso_path")" >&2
  else
    echo "[*] Downloading ${iso_name}..." >&2
    wget --progress=bar:force:noscroll --continue -O "$iso_path" "$iso_url" || {
      local codename="noble"
      for mirror in \
        "https://mirror.arizona.edu/ubuntu-releases/${codename}/${iso_name}" \
        "https://mirror.us.leaseweb.net/ubuntu-releases/${codename}/${iso_name}" \
        "https://releases.ubuntu.com/${codename}/${iso_name}"; do
        wget --progress=bar:force:noscroll --continue -O "$iso_path" "$mirror" && break
      done
    }
  fi

  [[ -f "$iso_path" && $(stat -c%s "$iso_path" 2>/dev/null || echo 0) -gt 500000000 ]] \
    || die "Invalid ISO: $iso_path"

  echo "$iso_path"
}

download_and_extract_server() {
  echo "[*] Preparing Ubuntu Server ISO..."
  local iso_path
  iso_path=$(download_ubuntu_iso \
    'ubuntu-24\.04\.[0-9]+-live-server-amd64\.iso(?=")' \
    "ubuntu-24.04.4-live-server-amd64.iso" \
    "$ISO_DIR")
  extract_iso_artifacts "$iso_path" "$BASE/http/ubuntu-server" \
    "ubuntu-24.04-live-server-amd64.iso"
  echo "[*] Server artifacts ready"
}

download_and_extract_desktop() {
  echo "[*] Preparing Ubuntu Desktop ISO..."
  local iso_path
  iso_path=$(download_ubuntu_iso \
    'ubuntu-24\.04\.[0-9]+-desktop-amd64\.iso(?=")' \
    "ubuntu-24.04.4-desktop-amd64.iso" \
    "$ISO_DIR")
  extract_iso_artifacts "$iso_path" "$BASE/http/ubuntu-desktop" \
    "ubuntu-24.04-desktop-amd64.iso"
  echo "[*] Desktop artifacts ready"
}

stage_windows_if_available() {
  local winiso=""
  if [[ -n "$WINDOWS_ISO_PATH" && -f "$WINDOWS_ISO_PATH" ]]; then
    winiso="$WINDOWS_ISO_PATH"
  elif [[ -n "$WINDOWS_ISO_URL" ]]; then
    winiso="$ISO_DIR/Win11.iso"
    wget --progress=bar:force:noscroll --continue -O "$winiso" "$WINDOWS_ISO_URL" || true
  else
    winiso=$(find "$ISO_DIR" -maxdepth 1 \( -iname 'Win11*.iso' -o -iname 'Win_11*.iso' -o -iname '*windows*11*.iso' \) | head -1 || true)
  fi
  [[ -n "${winiso:-}" && -f "$winiso" ]] || { echo "[*] No Windows ISO staged (optional)."; return 0; }

  echo "[*] Extracting WinPE from $winiso ..."
  local mnt; mnt=$(mktemp -d)
  mkdir -p "$BASE/http/winpe" "$BASE/http/windows"

  if mount -o loop,ro "$winiso" "$mnt" 2>/dev/null; then
    for c in boot/bcd boot/BCD Boot/BCD EFI/Microsoft/Boot/BCD; do
      [[ -f "$mnt/$c" ]] && { cp -f "$mnt/$c" "$BASE/http/winpe/BCD"; break; }
    done
    for c in boot/boot.sdi Boot/boot.sdi; do
      [[ -f "$mnt/$c" ]] && { cp -f "$mnt/$c" "$BASE/http/winpe/boot.sdi"; break; }
    done
    [[ -f "$mnt/sources/boot.wim" ]] && cp -f "$mnt/sources/boot.wim" "$BASE/http/winpe/boot.wim"
    [[ -f "$mnt/sources/install.wim" ]] && cp -f "$mnt/sources/install.wim" "$BASE/http/windows/install.wim"
    [[ -f "$mnt/sources/install.esd" ]] && cp -f "$mnt/sources/install.esd" "$BASE/http/windows/install.esd"
    umount "$mnt"; rmdir "$mnt"
  else
    7z x -o"$mnt" "$winiso" boot/ Boot/ sources/boot.wim sources/install.wim sources/install.esd >/dev/null 2>&1 || true
    find "$mnt" -iname 'bcd' | head -1 | xargs -r -I{} cp -f {} "$BASE/http/winpe/BCD"
    find "$mnt" -iname 'boot.sdi' | head -1 | xargs -r -I{} cp -f {} "$BASE/http/winpe/boot.sdi"
    find "$mnt" -iname 'boot.wim' | head -1 | xargs -r -I{} cp -f {} "$BASE/http/winpe/boot.wim"
    find "$mnt" -iname 'install.wim' | head -1 | xargs -r -I{} cp -f {} "$BASE/http/windows/install.wim"
    find "$mnt" -iname 'install.esd' | head -1 | xargs -r -I{} cp -f {} "$BASE/http/windows/install.esd"
    rm -rf "$mnt"
  fi

  # Inject NVMe/VMD/storage drivers into boot.wim so WinPE can see disks
  inject_windows_drivers
}

inject_windows_drivers() {
  local bootwim="$BASE/http/winpe/boot.wim"
  [[ -f "$bootwim" ]] || { echo "[!] No boot.wim found, skipping driver injection"; return 0; }

  command -v wimupdate >/dev/null 2>&1 || command -v wimlib-imagex >/dev/null 2>&1 || {
    echo "[!] wimtools not installed, skipping driver injection"
    echo "    Install with: apt-get install wimtools"
    return 0
  }

  local WIMCMD="wimupdate"
  command -v wimupdate >/dev/null 2>&1 || WIMCMD="wimlib-imagex update"

  local drv_dir="$BASE/drivers"
  mkdir -p "$drv_dir"

  echo "[*] Downloading Intel RST/VMD/NVMe drivers for Windows..."

  # ── Method 1: Try the pre-extracted GitHub repo (fastest, most reliable) ──
  local gh_ok=0
  for gen_dir in IRST_12-15G IRST_11-13G; do
    local gh_url="https://github.com/blastille/Intel-Rapid-Storage-Technology-RST-VMD-Drivers-Extracted/archive/refs/heads/main.zip"
    if [[ ! -d "$drv_dir/rst-extracted" ]]; then
      echo "[*] Downloading pre-extracted Intel RST drivers from GitHub..."
      wget -q -O "$drv_dir/rst-github.zip" "$gh_url" 2>/dev/null && {
        mkdir -p "$drv_dir/rst-extracted"
        7z x -o"$drv_dir/rst-extracted" "$drv_dir/rst-github.zip" >/dev/null 2>&1 || \
        unzip -qo "$drv_dir/rst-github.zip" -d "$drv_dir/rst-extracted" 2>/dev/null || true
        rm -f "$drv_dir/rst-github.zip"
        gh_ok=1
      } || true
    else
      gh_ok=1
    fi
    break  # Only need to download once
  done

  # Collect all .inf/.sys/.cat driver files into a flat staging directory
  local staging="$drv_dir/staging"
  rm -rf "$staging"
  mkdir -p "$staging"

  if [[ $gh_ok -eq 1 ]]; then
    # Find VMD driver files (iaStorVD.inf, iaStorVD.sys, iaStorVD.cat etc.)
    find "$drv_dir/rst-extracted" -type f \( -iname '*.inf' -o -iname '*.sys' -o -iname '*.cat' \) | while read -r f; do
      cp -f "$f" "$staging/" 2>/dev/null || true
    done
  fi

  # ── Method 2: Also grab the Microsoft inbox NVMe driver (stornvme) ──
  # This is already in boot.wim usually, but we ensure it's there

  # Count driver files found
  local inf_count
  inf_count=$(find "$staging" -maxdepth 1 -iname '*.inf' 2>/dev/null | wc -l)
  if [[ $inf_count -eq 0 ]]; then
    echo "[!] No driver .inf files found to inject. Skipping."
    echo "    You can manually place driver files in: $drv_dir/staging/"
    echo "    Then re-run this script to inject them."
    return 0
  fi

  echo "[*] Found $inf_count driver .inf files to inject into boot.wim"
  ls -la "$staging"/*.inf 2>/dev/null | awk '{print "    "$NF}' || true

  # ── Inject drivers into boot.wim using wimlib ──
  # WinPE auto-loads drivers from \$WinPeDriver$\ at boot time
  # We also place them in \Windows\INF and \Windows\System32\drivers
  # for maximum compatibility

  # Get the number of images in boot.wim (usually 2: WinPE setup + WinPE install)
  local img_count
  img_count=$(wimlib-imagex info "$bootwim" 2>/dev/null | grep -i "Image Count" | awk '{print $NF}' || echo "2")
  [[ -n "$img_count" && "$img_count" -gt 0 ]] || img_count=2

  echo "[*] Injecting drivers into boot.wim ($img_count images)..."

  for idx in $(seq 1 "$img_count"); do
    echo "    Image $idx/$img_count..."

    # Build wimupdate command file
    local cmdfile
    cmdfile=$(mktemp)

    # Add entire staging dir as \$WinPeDriver$\IntelRST\
    # WinPE will auto-discover and load drivers from $WinPeDriver$
    echo "add '$staging' '/\$WinPeDriver\$/IntelRST'" >> "$cmdfile"

    # Also add .inf files to \Windows\INF\ and .sys to \Windows\System32\drivers\
    for f in "$staging"/*.inf; do
      [[ -f "$f" ]] && echo "add '$f' '/Windows/INF/$(basename "$f")'" >> "$cmdfile"
    done
    for f in "$staging"/*.sys; do
      [[ -f "$f" ]] && echo "add '$f' '/Windows/System32/drivers/$(basename "$f")'" >> "$cmdfile"
    done
    for f in "$staging"/*.cat; do
      [[ -f "$f" ]] && echo "add '$f' '/Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/$(basename "$f")'" >> "$cmdfile"
    done

    $WIMCMD "$bootwim" "$idx" < "$cmdfile" 2>&1 | tail -3 || {
      echo "    [!] Warning: wimupdate failed for image $idx (non-fatal)"
    }
    rm -f "$cmdfile"
  done

  echo "[*] Driver injection into boot.wim complete"
  echo "    Injected Intel RST/VMD drivers for NVMe disk detection"

  # ── Also inject into install.wim if present (so post-install Windows has drivers) ──
  local installwim="$BASE/http/windows/install.wim"
  if [[ -f "$installwim" ]]; then
    local inst_count
    inst_count=$(wimlib-imagex info "$installwim" 2>/dev/null | grep -i "Image Count" | awk '{print $NF}' || echo "0")
    if [[ -n "$inst_count" && "$inst_count" -gt 0 ]]; then
      echo "[*] Injecting drivers into install.wim ($inst_count images)..."
      for idx in $(seq 1 "$inst_count"); do
        local cmdfile
        cmdfile=$(mktemp)
        for f in "$staging"/*.inf; do
          [[ -f "$f" ]] && echo "add '$f' '/Windows/INF/$(basename "$f")'" >> "$cmdfile"
        done
        for f in "$staging"/*.sys; do
          [[ -f "$f" ]] && echo "add '$f' '/Windows/System32/drivers/$(basename "$f")'" >> "$cmdfile"
        done
        for f in "$staging"/*.cat; do
          [[ -f "$f" ]] && echo "add '$f' '/Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/$(basename "$f")'" >> "$cmdfile"
        done
        $WIMCMD "$installwim" "$idx" < "$cmdfile" 2>&1 | tail -1 || true
        rm -f "$cmdfile"
      done
      echo "[*] install.wim driver injection complete"
    fi
  fi
}

# ----------------------------- ops scripts ------------------------------------
write_helpers() {
  cat >"$BASE/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker compose up -d --remove-orphans
docker compose ps
EOF

  cat >"$BASE/stop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker compose down
EOF

  cat >"$BASE/logs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker compose logs -f --tail=200 "$@"
EOF

  cat >"$BASE/test.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "=== PXE Stack Health Check (v5.12) ==="
cd "$BASE"; docker compose ps || true; echo

echo "[ports]"
for p in "67/udp" "69/udp" "${NGINX_PORT}/tcp"; do
  n="\${p%%/*}"; proto="\${p##*/}"
  if [[ "\$proto" == "tcp" ]]; then ss -tlnp | grep -q ":\$n " && echo "  ✓ \$p" || echo "  ✗ \$p";
  else ss -ulnp | grep -q ":\$n " && echo "  ✓ \$p" || echo "  ✗ \$p"; fi
done

echo; echo "[tftp files]"
for f in undionly.kpxe snponly.efi custom.ipxe wimboot; do
  [[ -f "$TFTP_ROOT/\$f" ]] && echo "  ✓ \$f" || echo "  ✗ \$f"
done

echo; echo "[http endpoints]"
for u in \
  "/custom.ipxe" \
  "/ubuntu-desktop/user-data" "/ubuntu-desktop/meta-data" "/ubuntu-desktop/vendor-data" \
  "/ubuntu-desktop/pxe-firstboot.sh" "/ubuntu-desktop/pxe-firstboot.service" \
  "/ubuntu-desktop/vmlinuz" "/ubuntu-desktop/initrd" "/ubuntu-desktop/ubuntu-24.04-desktop-amd64.iso" \
  "/ubuntu-server/user-data" "/ubuntu-server/meta-data" "/ubuntu-server/vendor-data" \
  "/ubuntu-server/pxe-firstboot.sh" "/ubuntu-server/pxe-firstboot.service" \
  "/ubuntu-server/vmlinuz" "/ubuntu-server/initrd" "/ubuntu-server/ubuntu-24.04-live-server-amd64.iso"; do
  c=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "http://${HOST_IP}:${NGINX_PORT}\$u" || true)
  [[ "\$c" == "200" ]] && echo "  ✓ \$u (\$c)" || echo "  ✗ \$u (\$c)"
done

echo; echo "[user-data validation]"
for p in ubuntu-server ubuntu-desktop; do
  first=\$(head -1 "$BASE/http/\$p/user-data")
  if [[ "\$first" == "#cloud-config" ]]; then
    echo "  ✓ \$p/user-data starts with #cloud-config"
  else
    echo "  ✗ \$p/user-data DOES NOT start with #cloud-config (got: \$first)"
  fi
  if grep -q "^autoinstall:" "$BASE/http/\$p/user-data"; then
    echo "  ✓ \$p/user-data has autoinstall: key"
  else
    echo "  ✗ \$p/user-data MISSING autoinstall: key"
  fi
done

echo; echo "[firstboot packages baked in]"
echo "  Common  : ${FIRSTBOOT_PACKAGES_COMMON}"
echo "  Desktop : ${FIRSTBOOT_PACKAGES_DESKTOP:-<none>}"
echo "  Server  : ${FIRSTBOOT_PACKAGES_SERVER:-<none>}"
echo "  Chrome  : ${INSTALL_CHROME}"
echo "  Docker  : ${INSTALL_DOCKER}"

echo; echo "[troubleshooting]"
echo "  Watch logs:  cd $BASE && docker compose logs -f dnsmasq nginx"
echo "  After install, check firstboot log on target: /var/log/pxe-firstboot.log"
EOF

  chmod +x "$BASE"/{start,stop,logs,test}.sh
}

# ----------------------------- main -------------------------------------------
main() {
  banner
  preflight
  create_dirs

  write_compose
  write_dnsmasq
  write_nginx
  write_custom_ipxe
  write_firstboot_scripts
  write_seeds
  write_windows_autounattend
  write_helpers

  download_ipxe_bootstrap
  download_and_extract_server
  download_and_extract_desktop
  stage_windows_if_available

  cp -f "$(readlink -f "$0")" "$BASE/deploy-netboot-pxe-v5.12.sh" 2>/dev/null || true
  chmod +x "$BASE/deploy-netboot-pxe-v5.12.sh" 2>/dev/null || true

  echo "[*] Starting stack..."
  cd "$BASE"
  docker compose up -d --remove-orphans
  sleep 2

  echo "[*] Running health check..."
  bash "$BASE/test.sh" || true

  cat <<EOF

┌────────────────────────────────────────────────────────────────┐
│ DEPLOYMENT COMPLETE (v5.12)                                   │
├────────────────────────────────────────────────────────────────┤
│ HTTP        : http://${HOST_IP}:${NGINX_PORT}                  │
│ Samba       : \\\\${HOST_IP}\\install                          │
│ Manage      : $BASE/start.sh | stop.sh | logs.sh | test.sh    │
│                                                                │
│ Credentials : ${UBUNTU_USERNAME} / ${UBUNTU_PASSWORD}          │
│                                                                │
│ PXE flow    : firmware -> iPXE -> /custom.ipxe                │
│ Desktop     : desktop ISO  | source: ubuntu-desktop-minimal   │
│ Server      : server ISO   | source: ubuntu-server            │
└────────────────────────────────────────────────────────────────┘

First-boot provisioning (runs once after reboot with full network):
  Common packages : ${FIRSTBOOT_PACKAGES_COMMON}
  Desktop extras  : ${FIRSTBOOT_PACKAGES_DESKTOP:-<none>}
  Server extras   : ${FIRSTBOOT_PACKAGES_SERVER:-<none>}
  Google Chrome   : ${INSTALL_CHROME}
  Docker (CE)     : ${INSTALL_DOCKER}
  Custom script   : ${FIRSTBOOT_CUSTOM_SCRIPT:-<none>}
  Log on target   : /var/log/pxe-firstboot.log

  To customize, set env vars before running:
    UBUNTU_PASSWORD="secret" \\
    FIRSTBOOT_PACKAGES_DESKTOP="gimp blender" \\
    INSTALL_CHROME=no \\
    INSTALL_DOCKER=no \\
    ./deploy-netboot-pxe-v5.12.sh

Watch logs while client boots:
  cd $BASE && docker compose logs -f dnsmasq nginx
EOF
}

main "$@"
