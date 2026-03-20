#!/bin/bash
set -e

### 0. Force Repositories & Clear APT Locks
echo "Cleaning APT and forcing Trixie repositories..."
rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock*
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.sources

# Create a clean DEB822 source file
cat << EOF > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

apt-get clean
apt-get update

### 1. Install ZFS Tools
echo "Installing ZFS tools..."
# If this fails, the Live CD has no internet or the mirrors are down
apt-get install -y zfsutils-linux gdisk debootstrap dosfstools

# Load ZFS module or build if necessary
modprobe zfs || { 
    echo "Module not found, attempting DKMS build..."
    apt-get install -y linux-headers-$(uname -r) zfs-dkms
    modprobe zfs
}

### 2. Disk Selection
declare -A BYID
SELECT=()
for dev in /dev/disk/by-id/*; do
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    REALNAME=$(basename "$(readlink -f "$dev")")
    if [[ -z "${BYID[$REALNAME]}" ]]; then
        BYID["$REALNAME"]="$dev"
        SIZE=$(lsblk -dn -o SIZE "/dev/$REALNAME")
        SELECT+=("$REALNAME" "$dev ($SIZE)" off)
    fi
done

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
whiptail --title "Disk Selection" --separate-output --checklist "Select Disks for ZFS Pool" 20 75 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1

DISKS=()
while read -r D; do DISKS+=("${BYID[$D]}"); done < "$TMPFILE"
[ ${#DISKS[@]} -eq 0 ] && exit 1

### 3. Partitioning & Pool
ZPOOL="rpool"
for D in "${DISKS[@]}"; do
    sgdisk --zap-all "$D"
    sgdisk -n 1:34:2047 -t 1:EF02 -n 2:2048:+512M -t 2:EF00 -n 3:0:0 -t 3:BF01 "$D"
done
udevadm settle

# Create Pool (Using -part3 for ZFS)
zpool create -f -o ashift=12 -o altroot=/target -O compression=lz4 -O mountpoint=none "$ZPOOL" "${DISKS[@]/%/-part3}"
zfs create -o mountpoint=/ "$ZPOOL/ROOT"
zpool set bootfs="$ZPOOL/ROOT" "$ZPOOL"
mount -t zfs "$ZPOOL/ROOT" /target

### 4. Bootstrap
debootstrap --include=zfs-initramfs,zfsutils-linux,linux-image-amd64,grub-efi-amd64,network-manager,dhcpcd8 trixie /target http://deb.debian.org/debian/

### 5. Network Configuration
echo "Configuring Network..."
# Set Hostname
echo "${TARGET_HOSTNAME:-debian-zfs}" > /target/etc/hostname

# Copy DNS from Live Environment
[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /target/etc/resolv.conf

# Setup simple DHCP for all interfaces (Debian 13 style)
cat << EOF > /target/etc/network/interfaces
auto lo
iface lo inet loopback

# Primary interface (Dynamic)
allow-hotplug $(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)
iface $(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1) inet dhcp
EOF

### 6. System Finalization
for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "/target$i"; done
cp /etc/hostid /target/etc/hostid

chroot /target bash -c "
update-initramfs -u -k all
update-grub
"

# Install GRUB to all selected disks
for D in "${DISKS[@]}"; do
    EFIPART="${D}-part2"
    mkdosfs -F 32 "$EFIPART"
    mkdir -p /target/boot/efi
    mount "$EFIPART" /target/boot/efi
    chroot /target grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck
    umount /target/boot/efi
done

echo "SUCCESS. Set the root password now:"
chroot /target passwd

sync
echo "Done. You can now reboot into your new ZFS system."
