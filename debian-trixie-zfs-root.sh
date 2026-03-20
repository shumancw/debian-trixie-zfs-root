#!/bin/bash
set -e

# --- USER CONFIG ---
NEW_USER="admin"         # Change to your username
NEW_HOSTNAME="debian-zfs"
ZPOOL_NAME="rpool"
TARGET_DIST="trixie"

### 1. Preparation (We know this works now!)
echo "Installing base installer tools..."
apt-get update
apt-get install -y zfsutils-linux gdisk debootstrap dosfstools sudo network-manager

# Ensure ZFS module is actually loaded in the Live environment
modprobe zfs || { apt-get install -y linux-headers-$(uname -r) zfs-dkms && modprobe zfs; }

### 2. Disk Selection
declare -A BYID
SELECT=()
for dev in /dev/disk/by-id/*; do
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    REAL=$(basename "$(readlink -f "$dev")")
    if [[ -z "${BYID[$REAL]}" ]]; then
        BYID["$REAL"]="$dev"
        SIZE=$(lsblk -dn -o SIZE "/dev/$REAL")
        SELECT+=("$REAL" "$dev ($SIZE)" off)
    fi
done

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
whiptail --title "ZFS Drive Selection" --separate-output \
    --checklist "Select disks for the pool (Space to select, Enter to confirm):" 20 78 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1

DISKS=()
while read -r D; do DISKS+=("${BYID[$D]}"); done < "$TMPFILE"
[ ${#DISKS[@]} -eq 0 ] && { echo "No disks selected. Exiting."; exit 1; }

### 3. Partitioning
echo "Partitioning disks..."
for D in "${DISKS[@]}"; do
    sgdisk --zap-all "$D"
    # 1: BIOS Boot (for safety), 2: EFI, 3: ZFS
    sgdisk -n 1:34:2047 -t 1:EF02 -n 2:2048:+512M -t 2:EF00 -n 3:0:0 -t 3:BF01 "$D"
done
udevadm settle

### 4. Pool & Dataset Creation
echo "Creating ZFS Pool..."
# Creating a simple stripe/mirror based on disk count for this example
zpool create -f -o ashift=12 -o altroot=/target \
    -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on \
    -O normalization=formD -O mountpoint=none "$ZPOOL_NAME" "${DISKS[@]/%/-part3}"

zfs create -o mountpoint=/ "$ZPOOL_NAME/ROOT"
zpool set bootfs="$ZPOOL_NAME/ROOT" "$ZPOOL_NAME"
mount -t zfs "$ZPOOL_NAME/ROOT" /target

### 5. Debootstrap
echo "Installing Debian $TARGET_DIST (this will take a few minutes)..."
debootstrap --include=zfs-initramfs,zfsutils-linux,linux-image-amd64,grub-efi-amd64,network-manager,sudo,nano,locales \
    --components main,contrib,non-free,non-free-firmware "$TARGET_DIST" /target http://deb.debian.org/debian/

### 6. Network & User Setup
echo "$NEW_HOSTNAME" > /target/etc/hostname
cp /etc/resolv.conf /target/etc/resolv.conf
cp /etc/hostid /target/etc/hostid

# Simple DHCP setup for the first Ethernet/WiFi card found
PRIMARY_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)
cat << EOF > /target/etc/network/interfaces
auto lo
iface lo inet loopback

allow-hotplug $PRIMARY_IFACE
iface $PRIMARY_IFACE inet dhcp
EOF

# Create the sudo user
chroot /target bash -c "
useradd -m -s /bin/bash $NEW_USER
echo '$NEW_USER ALL=(ALL) ALL' > /etc/sudoers.d/$NEW_USER
chmod 0440 /etc/sudoers.d/$NEW_USER
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
"

### 7. Bootloader & ZFS Fixes
for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "/target$i"; done

chroot /target bash -c "
# Force ZFS to import correctly on boot
echo 'zfs_import_dir=\"/dev/disk/by-id\"' >> /etc/default/zfs
update-initramfs -u -k all
update-grub
"

# Install EFI Grub to all selected disks for redundancy
for D in "${DISKS[@]}"; do
    mkdosfs -F 32 "${D}-part2"
    mkdir -p /target/boot/efi
    mount "${D}-part2" /target/boot/efi
    chroot /target grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck --bootloader-id="Debian-ZFS"
    umount /target/boot/efi
done

echo "--------------------------------------------------"
echo "INSTALLATION COMPLETE!"
echo "Set password for USER: $NEW_USER"
chroot /target passwd "$NEW_USER"
echo "Set password for ROOT:"
chroot /target passwd root
echo "--------------------------------------------------"

sync
echo "You can now reboot. Don't forget to remove the Live CD!"
