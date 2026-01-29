# Remount `/var/log/pulsar` disk to `/data` (Root-safe)

This guide provides a **root-safe** procedure and script to:

- Identify the block device currently used by `/var/log/pulsar` (from the active mount, or from `/etc/fstab`)
- **Refuse to run** if that device is part of the **root/boot device stack** (including dm-crypt/LVM/RAID under `/`)
- Unmount `/var/log/pulsar`
- Create `/data`
- Mount the same "other" device on `/data`
- Update `/etc/fstab` so the mount persists across reboot (with a timestamped backup)

> **Safety guarantee:** the script **never guesses** a device. If `/var/log/pulsar` is not mounted and not present in `/etc/fstab`, it refuses.  
> It also refuses if the target device is on the same physical disk as `/` or belongs to the root device stack.

---

## What you'll get

After a successful run:

- The device previously mounted at `/var/log/pulsar` will be mounted at `/data`
- `/etc/fstab` will contain an entry using `UUID=...` for `/data`
- A backup of `/etc/fstab` is created (e.g. `/etc/fstab.bak.20260129-120000`)

---

## Preconditions / assumptions

- Ubuntu Desktop (works on Ubuntu Server too)
- `/var/log/pulsar` is either:
  - currently mounted, **or**
  - present as a mount in `/etc/fstab`
- The `/var/log/pulsar` filesystem already exists (the script **does not format** disks)
- You run the script with `sudo`

---

## Quick sanity checks (recommended)

Check disk layout:

```bash
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,PKNAME
```


Confirm what is mounted where:

findmnt / /boot /boot/efi /var/log/pulsar


If your “other disk” is NVMe, you’ll typically see:

Root disk: /dev/nvme0n1 (root partition like /dev/nvme0n1p2)

Other disk: /dev/nvme1n1 (partition like /dev/nvme1n1p1) mounted on /var/log/pulsar

Optional: stop services writing to /var/log/pulsar

Unmounting can fail if the directory is busy. If you have a Pulsar service:

sudo systemctl stop pulsar 2>/dev/null || true


If you’re unsure what’s holding it open:

sudo fuser -vm /var/log/pulsar
# or (if installed)
sudo lsof +f -- /var/log/pulsar

Install / Save the script

Save the script below as:

remount_pulsar_to_data_root_safe.sh

Make it executable:

chmod +x remount_pulsar_to_data_root_safe.sh

Run
sudo ./remount_pulsar_to_data_root_safe.sh

Verify

Confirm /data is now mounted:

findmnt /data


Check fstab contains /data and does not still use /var/log/pulsar:

grep -nE '(/data|/var/log/pulsar)' /etc/fstab


Validate all fstab mounts parse correctly:

sudo mount -a


Reboot test (recommended):

sudo reboot


After reboot:

findmnt /data

Rollback

The script creates a timestamped backup of /etc/fstab:

Example:

/etc/fstab.bak.20260129-120000

To rollback:

Replace /etc/fstab with the backup:

sudo cp -a /etc/fstab.bak.YYYYMMDD-HHMMSS /etc/fstab


Unmount /data and remount according to restored fstab:

sudo umount /data || true
sudo mount -a
