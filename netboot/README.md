# PXE Netboot Deployment Script v5.12

Fully automated PXE network boot server for hands-off installation of Ubuntu 24.04 Desktop, Ubuntu 24.04 Server, and Windows 11 Pro. Runs entirely in Docker containers using ProxyDHCP mode, meaning it works alongside your existing router's DHCP without any changes to your network.

---

## What It Does

When you run this script on any Linux machine, it sets up a complete PXE boot server. Any computer on the same network can then boot from the network and automatically install an operating system — no USB drives, no manual steps, no keyboard interaction required.

The PXE boot menu offers three options:

- **Ubuntu 24.04 Desktop** — full desktop with GNOME, auto-installs via Subiquity autoinstall
- **Ubuntu 24.04 Server** — headless server, auto-installs via Subiquity autoinstall
- **Windows 11 Pro** — boots WinPE with autounattend.xml (requires staging a Windows ISO)

After Ubuntu installs and reboots, a first-boot service automatically installs additional software including Google Chrome, Docker, VLC, OpenSSH, and more.

---

## Requirements

**PXE server machine (the machine running this script):**

- Any Linux system (Ubuntu 20.04+ recommended)
- Docker and Docker Compose v2 (installed automatically if missing)
- ~20 GB free disk space (for ISOs and extracted files)
- Wired network connection to the same LAN as target machines

**Target machines (machines to be installed):**

- PXE/network boot enabled in BIOS/UEFI
- UEFI or Legacy BIOS supported
- Wired ethernet connection (Wi-Fi does not support PXE)
- For Windows: Intel 11th gen+ CPUs with NVMe will have drivers auto-injected

---

## Quick Start

### 1. Download and run with defaults

```bash
sudo bash deploy-netboot-pxe-v5.12.sh
```

This uses all default settings. The script will download Ubuntu ISOs automatically (~6 GB total), set up Docker containers, and start the PXE server. The whole process takes 5–15 minutes depending on your internet speed.

### 2. Boot a target machine from the network

1. Connect the target machine to the same network via ethernet
2. Enter BIOS/UEFI and set **Network/PXE Boot** as the first boot option
3. The iPXE menu will appear with a 15-second countdown
4. Select an OS or let it default to Ubuntu Desktop
5. Walk away — the installation completes unattended

### 3. Log in after installation

Ubuntu credentials: **admin / admin** (default)

---

## Configuration

Every setting is controlled via environment variables. Set them before running the script to override defaults.

### Network Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST_IP` | `192.168.1.172` | IP address of the PXE server machine |
| `GATEWAY` | `192.168.1.1` | Your router's IP (informational only) |
| `SUBNET` | `192.168.1.0` | Network subnet |
| `SUBNET_MASK` | `255.255.255.0` | Subnet mask |
| `NGINX_PORT` | `8081` | HTTP port for serving boot files |

> **Important:** `HOST_IP` must be the actual IP of the machine running the script. If it's wrong, PXE clients won't be able to download boot files.

### Ubuntu Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `UBUNTU_USERNAME` | `admin` | Login username created on installed machines |
| `UBUNTU_PASSWORD` | `admin` | Login password (hash generated automatically) |
| `UBUNTU_HOSTNAME_DESKTOP` | `ubuntu-desktop` | Hostname for desktop installs |
| `UBUNTU_HOSTNAME_SERVER` | `ubuntu-server` | Hostname for server installs |
| `TIMEZONE` | `UTC` | System timezone |

### Windows Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `WIN_ADMIN_USER` | `Admin` | Windows administrator username |
| `WIN_ADMIN_PW` | `P@ssw0rd!` | Windows administrator password |
| `WINDOWS_ISO_PATH` | *(empty)* | Path to a local Windows 11 ISO file |
| `WINDOWS_ISO_URL` | *(empty)* | URL to download a Windows 11 ISO |

### First-Boot Packages

After Ubuntu installs and reboots, a systemd oneshot service runs to install additional software. This only runs once, then disables and removes itself.

| Variable | Default | Description |
|----------|---------|-------------|
| `FIRSTBOOT_PACKAGES_COMMON` | `openssh-server curl wget vim htop net-tools git ca-certificates gnupg lsb-release` | Packages installed on both desktop and server |
| `FIRSTBOOT_PACKAGES_DESKTOP` | `vlc` | Additional packages for desktop only |
| `FIRSTBOOT_PACKAGES_SERVER` | *(empty)* | Additional packages for server only |
| `INSTALL_CHROME` | `yes` | Install Google Chrome (downloaded from Google directly) |
| `INSTALL_DOCKER` | `yes` | Install Docker CE from Docker's official apt repo |
| `FIRSTBOOT_CUSTOM_SCRIPT` | *(empty)* | Path to a custom shell script to run after packages |

---

## Examples

### Basic: custom IP and password

```bash
sudo HOST_IP=10.0.0.50 \
     UBUNTU_PASSWORD="SecurePass123" \
     bash deploy-netboot-pxe-v5.12.sh
```

### Desktop with extra apps, no Docker

```bash
sudo HOST_IP=192.168.1.100 \
     UBUNTU_PASSWORD="mypassword" \
     FIRSTBOOT_PACKAGES_DESKTOP="vlc gimp blender code" \
     INSTALL_DOCKER=no \
     bash deploy-netboot-pxe-v5.12.sh
```

### Server with Docker and custom hostname

```bash
sudo HOST_IP=192.168.1.100 \
     UBUNTU_HOSTNAME_SERVER="prod-web-01" \
     FIRSTBOOT_PACKAGES_SERVER="fail2ban ufw nginx" \
     INSTALL_CHROME=no \
     bash deploy-netboot-pxe-v5.12.sh
```

### With a Windows 11 ISO

```bash
sudo HOST_IP=192.168.1.100 \
     WINDOWS_ISO_PATH="/home/user/Win11_23H2_English_x64.iso" \
     bash deploy-netboot-pxe-v5.12.sh
```

The Windows ISO is not downloaded automatically. You need to provide your own from [Microsoft's download page](https://www.microsoft.com/en-us/software-download/windows11). Place it in `/opt/netboot-pxe/isos/` or specify its path with `WINDOWS_ISO_PATH`.

### With a custom first-boot script

Create a script with any additional setup you need:

```bash
#!/bin/bash
# my-setup.sh — runs as root on first boot after packages are installed

# Add a PPA and install something
add-apt-repository -y ppa:some/ppa
apt-get update && apt-get install -y some-package

# Install snaps
snap install discord
snap install spotify

# Configure firewall
ufw allow ssh
ufw allow 80/tcp
ufw --force enable

# Clone a repo
su - admin -c "git clone https://github.com/myorg/dotfiles.git ~/.dotfiles"
```

Then deploy:

```bash
sudo FIRSTBOOT_CUSTOM_SCRIPT="/home/user/my-setup.sh" \
     bash deploy-netboot-pxe-v5.12.sh
```

---

## Managing the Server

After deployment, management scripts are located at `/opt/netboot-pxe/`:

```bash
cd /opt/netboot-pxe

./start.sh          # Start all containers
./stop.sh           # Stop all containers
./logs.sh           # Tail all container logs (Ctrl+C to exit)
./logs.sh nginx     # Tail only nginx logs
./logs.sh dnsmasq   # Tail only dnsmasq logs
./test.sh           # Run a health check on all services and endpoints
```

### Health Check

Run `./test.sh` to verify everything is working. It checks:

- Docker containers are running
- Required ports are listening (67/udp, 69/udp, 8081/tcp)
- TFTP boot files exist (undionly.kpxe, snponly.efi, wimboot)
- All HTTP endpoints return 200 (kernel, initrd, ISOs, user-data, firstboot scripts)
- user-data files have correct format (`#cloud-config` header, `autoinstall:` key)
- First-boot package configuration summary

### Watching an Install in Real Time

While a client is PXE booting, watch the logs to see each file being requested:

```bash
cd /opt/netboot-pxe && docker compose logs -f dnsmasq nginx
```

You should see requests in this order for a Ubuntu Desktop install:

```
GET /custom.ipxe                                    ← iPXE menu
GET /ubuntu-desktop/vmlinuz                         ← Linux kernel
GET /ubuntu-desktop/initrd                          ← Initial ramdisk
GET /ubuntu-desktop/ubuntu-24.04-desktop-amd64.iso  ← Full ISO (~6 GB)
GET /ubuntu-desktop/user-data                       ← Autoinstall config
GET /ubuntu-desktop/meta-data                       ← Cloud-init metadata
GET /ubuntu-desktop/vendor-data                     ← Cloud-init vendor data
```

---

## How It Works

### Boot Flow

```
Target PC powers on
    │
    ├─ Firmware PXE → broadcasts DHCP discover
    │
    ├─ Router responds with IP address (normal DHCP)
    ├─ dnsmasq responds with PXE boot info (ProxyDHCP, no IP conflict)
    │
    ├─ If Legacy BIOS → downloads undionly.kpxe via TFTP
    ├─ If UEFI        → downloads snponly.efi via TFTP
    │
    ├─ iPXE loads → fetches custom.ipxe via HTTP
    │
    ├─ User selects OS (or 15s timeout → Ubuntu Desktop)
    │
    ├─ iPXE downloads kernel + initrd + ISO via HTTP
    │
    ├─ Installer boots with autoinstall config from nocloud-net
    │
    ├─ Partitions disk, installs OS, sets up user account
    │
    ├─ late-commands: installs firstboot service, disables crash reporter
    │
    ├─ Machine reboots into installed OS
    │
    └─ pxe-firstboot.service runs ONCE:
        ├─ Waits for network
        ├─ apt-get update + installs common packages
        ├─ Downloads and installs Google Chrome .deb
        ├─ Adds Docker repo + installs Docker CE
        ├─ Runs custom script (if provided)
        └─ Disables and removes itself
```

### Architecture

The script deploys three Docker containers:

| Container | Purpose | Ports |
|-----------|---------|-------|
| `dnsmasq-pxe` | ProxyDHCP + TFTP server | 67/udp, 69/udp (host network) |
| `nginx-pxe` | HTTP server for boot files, ISOs, configs | 8081/tcp |
| `samba-pxe` | SMB share for Windows install files | 445/tcp, 139/tcp |

### Directory Structure

```
/opt/netboot-pxe/
├── docker-compose.yaml
├── start.sh / stop.sh / logs.sh / test.sh
├── config/
│   ├── dnsmasq/dnsmasq.conf          ← ProxyDHCP + TFTP config
│   └── nginx/nginx.conf              ← HTTP server config
├── tftp/
│   ├── undionly.kpxe                  ← iPXE for Legacy BIOS
│   ├── snponly.efi                    ← iPXE for UEFI
│   ├── wimboot                        ← WinPE boot loader
│   └── custom.ipxe                    ← Boot menu script
├── http/
│   ├── custom.ipxe                    ← Copy of boot menu (HTTP)
│   ├── ubuntu-desktop/
│   │   ├── vmlinuz                    ← Kernel from desktop ISO
│   │   ├── initrd                     ← Initrd from desktop ISO
│   │   ├── ubuntu-24.04-desktop-amd64.iso  ← Full desktop ISO
│   │   ├── user-data                  ← Autoinstall seed
│   │   ├── meta-data                  ← Cloud-init metadata
│   │   ├── vendor-data                ← Cloud-init vendor data
│   │   ├── pxe-firstboot.sh           ← First-boot provisioning script
│   │   └── pxe-firstboot.service      ← Systemd unit for first-boot
│   ├── ubuntu-server/
│   │   └── (same structure as desktop)
│   ├── windows/
│   │   ├── autounattend.xml           ← Windows unattended config
│   │   ├── install.wim / install.esd  ← Windows install image
│   └── winpe/
│       ├── wimboot                    ← WinPE loader
│       ├── BCD                        ← Boot configuration data
│       ├── boot.sdi                   ← System deployment image
│       └── boot.wim                   ← WinPE image (with injected drivers)
├── drivers/
│   └── staging/                       ← Intel RST/VMD drivers for Windows
└── isos/
    ├── ubuntu-24.04.x-desktop-amd64.iso
    └── ubuntu-24.04.x-live-server-amd64.iso
```

---

## Windows 11 Setup

Windows support is optional. The Ubuntu targets work without any Windows ISO.

### Staging a Windows ISO

The script does not download Windows ISOs automatically. To enable Windows PXE install:

1. Download a Windows 11 ISO from [microsoft.com/software-download/windows11](https://www.microsoft.com/en-us/software-download/windows11)

2. Either place it in the ISOs directory:
   ```bash
   cp Win11_23H2_English_x64.iso /opt/netboot-pxe/isos/
   sudo bash deploy-netboot-pxe-v5.12.sh   # Re-run to extract WinPE files
   ```

3. Or specify it during deployment:
   ```bash
   sudo WINDOWS_ISO_PATH="/path/to/Win11.iso" bash deploy-netboot-pxe-v5.12.sh
   ```

### NVMe Driver Injection

Modern Intel systems (11th gen and newer) use VMD (Volume Management Device) to manage NVMe SSDs. Windows Setup cannot see these drives without the Intel RST/VMD driver.

The script automatically:

1. Downloads pre-extracted Intel RST/VMD driver files (covers 8th–15th gen Intel)
2. Injects them into `boot.wim` using `wimlib` (Linux equivalent of DISM)
3. Places drivers in `$WinPeDriver$` (auto-loaded by WinPE) and `Windows\INF` + `Windows\System32\drivers`
4. Also injects into `install.wim` so the installed Windows already has the drivers

If automatic download fails, manually place `.inf`, `.sys`, and `.cat` driver files in:
```
/opt/netboot-pxe/drivers/staging/
```
Then re-run the script.

---

## Troubleshooting

### PXE client doesn't get a boot menu

- Verify `HOST_IP` matches the actual IP of the server: `ip addr show`
- Check dnsmasq is running: `docker ps | grep dnsmasq`
- Check dnsmasq logs for DHCP activity: `cd /opt/netboot-pxe && ./logs.sh dnsmasq`
- Ensure no other DHCP/PXE server is on the network competing
- Some BIOS/UEFI require enabling "Network Boot" or "PXE Boot" explicitly
- Try both Legacy and UEFI boot modes

### Ubuntu install goes interactive / asks questions

- Run `./test.sh` and verify user-data starts with `#cloud-config` and has `autoinstall:` key
- Check that the nginx logs show `GET /ubuntu-desktop/user-data` returning 200
- If using desktop, the GUI installer will briefly appear but should auto-proceed — this is normal
- If it prompts for input, the user-data wasn't picked up — check for YAML syntax errors

### "Something went wrong" during Ubuntu install

Check the error in the log window. Common causes:

- **"system install failed for openssh-server"** — the installer tried to download a package that isn't on the ISO and there's no internet. Fixed in v5.12 — SSH is now installed via first-boot service after reboot.
- **"cannot create /target/etc/dconf/db/local.d/"** — a late-command tried to write to a directory that doesn't exist. Fixed in v5.12 — `mkdir -p` runs first.
- **Crash reporter dialog appears** — apport is triggering error popups. Fixed in v5.12 — apport is disabled via kernel cmdline (`apport=0`) and late-commands.

### Windows says "No drives found" / "Install driver to show hardware"

- This means WinPE can't see the NVMe SSD because it's behind Intel VMD
- Re-run the deploy script to trigger automatic driver injection into boot.wim
- Or manually place Intel RST VMD drivers (iaStorVD.inf, iaStorVD.sys) in `/opt/netboot-pxe/drivers/staging/` and re-run
- As a BIOS workaround: disable "Intel VMD" or "RST" in BIOS and switch to AHCI mode (only for fresh installs)

### First-boot packages didn't install

- SSH into the machine (if openssh-server installed) or log in locally
- Check the log: `cat /var/log/pxe-firstboot.log`
- If the service hasn't run yet, check its status: `systemctl status pxe-firstboot.service`
- If the machine had no internet at first boot, the package installs would fail. Connect to internet and re-run: `sudo /opt/pxe-firstboot.sh`

### ISOs are not downloading

- The script tries `releases.ubuntu.com` first, then falls back to mirrors
- If behind a corporate firewall/proxy, download ISOs manually and place them in `/opt/netboot-pxe/isos/`
- Existing ISOs in the `isos/` directory are detected and reused automatically

---

## Re-running the Script

The script is safe to re-run. It will:

- Reuse existing ISOs (won't re-download)
- Overwrite configuration files with current settings
- Restart Docker containers with the new config
- Re-inject Windows drivers if a Windows ISO is staged

This means you can change settings and re-run without waiting for ISO downloads:

```bash
sudo UBUNTU_PASSWORD="newpassword" \
     FIRSTBOOT_PACKAGES_DESKTOP="vlc gimp" \
     bash deploy-netboot-pxe-v5.12.sh
```

---

## Ports Used

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| 67 | UDP | dnsmasq | ProxyDHCP (PXE boot offers) |
| 69 | UDP | dnsmasq | TFTP (initial iPXE bootstrap) |
| 8081 | TCP | nginx | HTTP (boot files, ISOs, configs) |
| 445 | TCP | samba | SMB (Windows install files) |
| 139 | TCP | samba | SMB (legacy NetBIOS) |

ProxyDHCP on port 67 works alongside your router's DHCP. It doesn't hand out IP addresses — it only provides PXE boot information to clients that request it.

---

## Security Notes

- The default credentials are `admin`/`admin` — change them for any non-lab environment
- The PXE server responds to any machine on the network that PXE boots — there is no authentication
- The first-boot service runs as root and downloads packages from the internet
- Windows autounattend.xml contains the admin password in plaintext
- This is designed for lab, development, and internal deployment use — not for untrusted networks
