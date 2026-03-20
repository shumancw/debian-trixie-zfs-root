#!/bin/bash
set -e

# --- CONFIGURATION (Adjust as needed) ---
NEW_USER="admin"
NEW_HOSTNAME="debian-zfs"
TARGET_DIST="trixie"

### 1. Prepare Environment [cite: 432]
echo "Step 1: Setting up repositories and installing ZFS..."
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
echo "deb http://deb.debian.org/debian $TARGET_DIST main contrib non-free-firmware" > /etc/apt/sources.list [cite: 437]
apt update [cite: 438]
apt install --yes debootstrap gdisk zfsutils-linux linux-headers-generic [cite: 451, 453]
modprobe zfs

### 2. Disk Selection
# (Using the same interactive selector from before for convenience)
declare -A BYID
SELECT=()
for dev in /dev/disk/by-id/*; do
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    REAL=$(basename "$(readlink -f "$dev")")
    [[ "$REAL" == loop* ]] && continue
    if [[ -z "${BYID[$REAL]}" ]]; then
        BYID["$REAL"]="$dev"
        SIZE=$(lsblk -dn -o SIZE "/dev/$REAL")
        SELECT+=("$REAL" "$dev ($SIZE)" off)
    fi
done
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
whiptail --title "ZFS Drive Selection" --separate-output \
    --checklist "Select disks:" 20 78 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1
DISKS=()
while read -r D; do DISKS+=("${BYID[$D]}"); done < "$TMPFILE"

### 3. Disk Formatting [cite: 454]
echo "Step 3: Partitioning disks..."
for D in "${DISKS[@]}"; do
    sgdisk --zap-all "$D" [cite: 484]
    # Partition 1: BIOS Boot [cite: 490]
    sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$D"
    # Partition 2: EFI [cite: 493]
    sgdisk -n2:1M:+512M -t2:EF00 "$D"
    # Partition 3: Boot Pool [cite: 497]
    sgdisk -n3:0:+1G -t3:BF01 "$D"
    # Partition 4: Root Pool [cite: 502]
    sgdisk -n4:0:0 -t4:BF00 "$D"
done
udevadm settle && sleep 2

### 4. Pool & Dataset Creation [cite: 509, 534]
echo "Step 4: Creating pools and datasets..."
# Boot Pool (bpool) - Restricted features for GRUB [cite: 522]
zpool create -o ashift=12 -o autotrim=on -o compatibility=grub2 \
    -O devices=off -O acltype=posixacl -O xattr=sa -O compression=lz4 \
    -O normalization=formD -O relatime=on -O canmount=off \
    -O mountpoint=/boot -R /mnt bpool "${DISKS[@]/%/-part3}" [cite: 510-520]

# Root Pool (rpool) [cite: 537]
zpool create -f -o ashift=12 -o autotrim=on \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 \
    -O normalization=formD -O relatime=on -O canmount=off \
    -O mountpoint=/ -R /mnt rpool "${DISKS[@]/%/-part4}" [cite: 538-544]

# Create container datasets [cite: 603]
zfs create -o canmount=off -o mountpoint=none rpool/ROOT [cite: 604]
zfs create -o canmount=off -o mountpoint=none bpool/BOOT [cite: 605]

# Create system datasets [cite: 610, 612]
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian [cite: 611]
zfs mount rpool/ROOT/debian [cite: 611]
zfs create -o mountpoint=/boot bpool/BOOT/debian [cite: 612]

# Optional datasets for better snapshot management [cite: 615, 629]
zfs create rpool/home
zfs create -o mountpoint=/root rpool/home/root [cite: 618]
zfs create -o canmount=off rpool/var [cite: 620]
zfs create rpool/var/log [cite: 625]
zfs create rpool/var/spool [cite: 627]

### 5. System Installation [cite: 602]
echo "Step 5: Installing Debian $TARGET_DIST..."
debootstrap "$TARGET_DIST" /mnt [cite: 634]
cp /etc/zfs/zpool.cache /mnt/etc/zfs/ [cite: 636]
echo "$NEW_HOSTNAME" > /mnt/etc/hostname

### 6. System Configuration [cite: 380]
# Bind filesystems and chroot [cite: 641]
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

chroot /mnt bash --login <<EOF
apt update
apt install --yes console-setup locales [cite: 642]
apt install --yes dpkg-dev linux-headers-generic linux-image-generic zfs-initramfs [cite: 643]
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf [cite: 643]

# GRUB Setup [cite: 647, 674]
apt install --yes dosfstools grub-efi-amd64 shim-signed [cite: 648]
mkdosfs -F 32 -s 1 -n EFI ${DISKS[0]}-part2 [cite: 648]
mkdir -p /boot/efi
mount ${DISKS[0]}-part2 /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy [cite: 674]

# GRUB ZFS Fix [cite: 669]
sed -i 's|GRUB_CMDLINE_LINUX=""|GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"|' /etc/default/grub
update-grub [cite: 671]

# User setup [cite: 690]
useradd -m -s /bin/bash $NEW_USER
usermod -a -G sudo $NEW_USER
EOF

echo "Done. Set passwords below."
chroot /mnt passwd root [cite: 652]
chroot /mnt passwd $NEW_USER

### 7. Cleanup [cite: 385, 684]
zpool export -a [cite: 686]
echo "Installation Finished. Reboot and enjoy your ZFS-root system!"
