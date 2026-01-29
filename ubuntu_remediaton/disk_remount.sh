#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date -Is)] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (use sudo)."; }

# Resolve fstab-style spec (UUID=..., LABEL=..., /dev/...) to a concrete /dev path
resolve_spec_to_dev() {
  local spec="$1"
  if [[ "$spec" =~ ^UUID= ]]; then
    blkid -U "${spec#UUID=}" 2>/dev/null || return 1
  elif [[ "$spec" =~ ^LABEL= ]]; then
    blkid -L "${spec#LABEL=}" 2>/dev/null || return 1
  elif [[ "$spec" == /dev/* ]]; then
    [[ -b "$spec" ]] || return 1
    echo "$spec"
  else
    # Try blkid token forms like PARTUUID=...
    local dev
    dev="$(blkid -o device -t "$spec" 2>/dev/null | head -n1 || true)"
    [[ -n "$dev" ]] || return 1
    echo "$dev"
  fi
}

# Get device currently mounted at /var/log/pulsar, else from /etc/fstab.
# NOTE: We DO NOT guess another disk. If neither exists, we refuse.
get_pulsar_device() {
  local spec dev
  if findmnt -rn /var/log/pulsar >/dev/null 2>&1; then
    spec="$(findmnt -rn -o SOURCE /var/log/pulsar)"
  else
    spec="$(awk '
      $0 ~ /^[[:space:]]*#/ {next}
      NF>=2 && $2=="/var/log/pulsar" {print $1; exit}
    ' /etc/fstab || true)"
  fi

  [[ -n "${spec:-}" ]] || die "No mount or fstab entry found for /var/log/pulsar. Refusing (no guessing allowed)."

  dev="$(resolve_spec_to_dev "$spec" || true)"
  [[ -n "${dev:-}" && -b "$dev" ]] || die "Could not resolve /var/log/pulsar source '$spec' to a block device."
  echo "$dev"
}

get_fstype() {
  local dev="$1"
  local t
  t="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
  [[ -n "$t" ]] || die "No filesystem detected on $dev."
  echo "$t"
}

get_uuid() {
  local dev="$1"
  local u
  u="$(blkid -o value -s UUID "$dev" 2>/dev/null || true)"
  [[ -n "$u" ]] || die "No UUID found on $dev (fstab should use UUID)."
  echo "$u"
}

# Recursively list underlying slave block devices for dm/raid stacks (e.g. /dev/dm-0 -> nvme0n1p2)
list_slaves_recursive() {
  local devbase="$1"   # e.g. dm-0
  local sys="/sys/block/$devbase/slaves"
  [[ -d "$sys" ]] || return 0
  local s
  for s in "$sys"/*; do
    [[ -e "$s" ]] || continue
    local name
    name="$(basename "$s")"
    echo "/dev/$name"
    # recurse if slave is itself a dm device
    if [[ "$name" == dm-* ]]; then
      list_slaves_recursive "$name"
    fi
  done
}

# Return the physical parent disk for a partition/device if possible (e.g. /dev/nvme1n1p1 -> /dev/nvme1n1)
parent_disk() {
  local dev="$1"
  local pk
  pk="$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)"
  [[ -n "$pk" ]] || return 1
  echo "/dev/$pk"
}

# Build a "protected set" covering the root device stack:
# - mount sources for /, /boot, /boot/efi (if present)
# - any underlying slaves for dm devices
# - the physical disks those map to
build_protected_sets() {
  local m src dev devbase dsk

  PROTECTED_DEVS=()
  PROTECTED_DISKS=()

  for m in / /boot /boot/efi; do
    src="$(findmnt -rn -o SOURCE "$m" 2>/dev/null || true)"
    [[ -n "$src" ]] || continue

    # resolve symlinks (/dev/mapper/...) to real dev if possible
    if [[ "$src" == /dev/* ]]; then
      dev="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    else
      dev="$src"
    fi
    PROTECTED_DEVS+=("$dev")

    # If it's a dm device, add all its slaves as protected too
    if [[ "$dev" =~ ^/dev/dm- ]]; then
      devbase="$(basename "$dev")"
      while read -r sdev; do
        [[ -b "$sdev" ]] && PROTECTED_DEVS+=("$sdev")
      done < <(list_slaves_recursive "$devbase" || true)
    fi
  done

  # Dedup devices
  mapfile -t PROTECTED_DEVS < <(printf "%s\n" "${PROTECTED_DEVS[@]}" | awk 'NF{seen[$0]=1} END{for(k in seen) print k}')

  for dev in "${PROTECTED_DEVS[@]}"; do
    if dsk="$(parent_disk "$dev" 2>/dev/null)"; then
      PROTECTED_DISKS+=("$dsk")
    fi
  done

  # Dedup disks
  mapfile -t PROTECTED_DISKS < <(printf "%s\n" "${PROTECTED_DISKS[@]}" | awk 'NF{seen[$0]=1} END{for(k in seen) print k}')
}

is_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

get_mount_opts_from_fstab_or_current() {
  local opts=""
  if findmnt -rn /var/log/pulsar >/dev/null 2>&1; then
    opts="$(findmnt -rn -o OPTIONS /var/log/pulsar || true)"
  fi
  if [[ -z "$opts" ]]; then
    opts="$(awk '
      $0 ~ /^[[:space:]]*#/ {next}
      NF>=4 && $2=="/var/log/pulsar" {print $4; exit}
    ' /etc/fstab || true)"
  fi
  [[ -n "$opts" ]] || opts="defaults,nofail,x-systemd.device-timeout=30"
  echo "$opts"
}

update_fstab() {
  local uuid="$1" fstype="$2" opts="$3"
  local ts backup tmp
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="/etc/fstab.bak.${ts}"
  tmp="/etc/fstab.tmp.${ts}"

  cp -a /etc/fstab "$backup"
  log "Backed up /etc/fstab -> $backup"

  # Change mountpoint /var/log/pulsar -> /data if line exists.
  # Also remove any existing /data line for same UUID to avoid duplicates.
  awk -v oldmp="/var/log/pulsar" -v newmp="/data" -v uuid="UUID=${uuid}" -v fstype="$fstype" -v opts="$opts" '
    BEGIN{ found_old=0 }
    /^[[:space:]]*#/ { print; next }
    NF<2 { print; next }
    {
      if ($2==newmp && $1==uuid) { next }

      if ($2==oldmp) {
        $1=uuid
        $2=newmp
        $3=fstype
        $4=opts
        found_old=1
        print
        next
      }
      print
    }
    END{
      if (found_old==0) {
        print ""
        print "# Added by remount_pulsar_to_data_root_safe.sh"
        print uuid " " newmp " " fstype " " opts " 0 2"
      }
    }
  ' /etc/fstab > "$tmp"

  [[ -s "$tmp" ]] || die "Generated fstab is empty; refusing to overwrite."
  mv "$tmp" /etc/fstab
  log "Updated /etc/fstab for /data (and backed up original)."
  log "fstab backup: $backup"
}

main() {
  require_root

  build_protected_sets
  log "Protected root stack devices:"
  printf "  %s\n" "${PROTECTED_DEVS[@]}"
  log "Protected physical disks:"
  printf "  %s\n" "${PROTECTED_DISKS[@]}"

  local target_dev target_disk fstype uuid opts mp
  target_dev="$(get_pulsar_device)"
  log "Device for /var/log/pulsar: $target_dev"

  # HARD safety: never touch root device stack
  if is_in_list "$target_dev" "${PROTECTED_DEVS[@]}"; then
    die "Refusing: target device $target_dev is part of the protected root stack."
  fi

  target_disk="$(parent_disk "$target_dev" 2>/dev/null || true)"
  [[ -n "${target_disk:-}" ]] || die "Refusing: could not determine parent disk for $target_dev (safety)."

  if is_in_list "$target_disk" "${PROTECTED_DISKS[@]}"; then
    die "Refusing: target disk $target_disk is the same as (or part of) the root/boot disk stack."
  fi

  # If target is mounted somewhere, allow only /var/log/pulsar
  if findmnt -rn -S "$target_dev" >/dev/null 2>&1; then
    mp="$(findmnt -rn -S "$target_dev" -o TARGET | head -n1 || true)"
    [[ "$mp" == "/var/log/pulsar" ]] || die "Refusing: $target_dev is mounted at $mp (not /var/log/pulsar)."
  fi

  fstype="$(get_fstype "$target_dev")"
  uuid="$(get_uuid "$target_dev")"
  opts="$(get_mount_opts_from_fstab_or_current "$target_dev")"

  log "Target filesystem: TYPE=$fstype UUID=$uuid"
  log "Mount options: $opts"

  if mountpoint -q /var/log/pulsar; then
    log "Unmounting /var/log/pulsar..."
    umount /var/log/pulsar || die "Unmount failed. Try: sudo fuser -vm /var/log/pulsar"
  else
    log "/var/log/pulsar not currently a mountpoint; continuing."
  fi

  if mountpoint -q /data; then
    die "/data is already a mountpoint. Refusing."
  fi
  mkdir -p /data
  chmod 0755 /data

  log "Mounting UUID=$uuid on /data..."
  mount -t "$fstype" -o "$opts" "UUID=$uuid" /data

  update_fstab "$uuid" "$fstype" "$opts"

  findmnt /data >/dev/null || die "Validation failed: /data not mounted."
  log "Running mount -a to verify fstab..."
  mount -a

  log "SUCCESS: $target_dev mounted at /data and /etc/fstab updated."
}

main "$@"

