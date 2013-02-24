#!/bin/sh

if [ -z "$1" ]; then
    echo "Usage: $0 <config>" 1>&2
    exit 1
fi

set -e
. `readlink --canonicalize "$1"`

## ---------------------------------------------
## cleaning...
modprobe loop dm_mod
if [ -d "$ROOTFS" ]; then
    echo "*** Unmounting image..."
    for F in $FAKES; do
        umount "$ROOTFS"/"$F" > /dev/null 2>&1 || :
    done
    umount "$ROOTFS"/dev > /dev/null 2>&1 || :
    umount "$ROOTFS"/proc > /dev/null 2>&1 || :
    umount "$ROOTFS"/sys > /dev/null 2>&1 || :
    chroot "$ROOTFS" umount -a > /dev/null 2>&1 || :
    umount -f "$ROOTFS" > /dev/null 2>&1 || :
    rmdir "$ROOTFS"
fi
if [ -f $IMG ]; then
    echo "*** Removing old image..."
    LOOPDEVS=`losetup --associated "$IMG" | sed -E 's/^([^:]+).*$/\1/'`
    for LD in $LOOPDEVS; do
        kpartx -d "$LD" || :
        losetup --detach "$LD"
    done
    rm -f -- "$IMG"
fi
rm -rf -- "$TMPDIR"/fakefs

## ---------------------------------------------
## create disk image and mount it...
echo "*** Create block device..."
mkdir -p "$TMPDIR"
BYTES=`expr $DISKSIZE '*' 1024 '*' 1024`
dd if=/dev/zero of="$IMG" bs=1 count=1 seek=$(($BYTES - 1)) conv=notrunc
LOOPDEV=`losetup --find`
losetup "$LOOPDEV" "$IMG"
parted --script "$LOOPDEV" mklabel msdos
parted --script "$LOOPDEV" mkpart primary ext2 1 $DISKSIZE
kpartx -a "$LOOPDEV"
LOOPDEV1=/dev/mapper/`basename "$LOOPDEV"`p1
echo "*** Create filesystem..."
mkfs.ext3 -q "$LOOPDEV1"
mkdir -m 755 -p "$ROOTFS"
mount "$LOOPDEV1" "$ROOTFS"

## ---------------------------------------------
## initiating root fs directory...
mkdir -m 755 -p "$ROOTFS"/dev
mknod -m 666 "$ROOTFS"/dev/null c 1 3
mknod -m 666 "$ROOTFS"/dev/zero c 1 5
for F in $FAKES; do
    mkdir -p "$TMPDIR"/fakefs/"$F"
    mkdir -p "$ROOTFS"/"$F"
    mount "$TMPDIR"/fakefs/"$F" "$ROOTFS"/"$F" -o bind
done

## ---------------------------------------------
## register package repos...
echo "*** Register RPM repositories..."
for URL in $REPOS; do
    zypper \
        --root "$ROOTFS" \
        --non-interactive \
        --quiet \
        addrepo \
        --refresh \
        "$URL" "$URL"
done

## ---------------------------------------------
## installing packages...
echo "*** Installing packages..."
zypper \
    --root "$ROOTFS" \
    --gpg-auto-import-keys \
    --no-gpg-checks \
    --non-interactive \
    --quiet \
    install \
    --name \
    --download-in-advance \
    --auto-agree-with-licenses \
    --no-recommends \
    -- $PACKAGES

## ---------------------------------------------
## generate ssh key for access to target...
if [ ! -f .ssh/id_rsa ]; then
    mkdir -m755 -p .ssh
    ssh-keygen -t rsa -N "" -q -f .ssh/id_rsa
fi
if [ ! -f .ssh/config ]; then
    cat > .ssh/config <<-EOF
	IdentityFile .ssh/id_rsa
	UserKnownHostsFile .ssh/known_hosts
	StrictHostKeyChecking no
	Host *
	    User root
	EOF
fi

## ---------------------------------------------
## configuring system...
echo "*** Create essential system configurations..."
cat > "$ROOTFS"/etc/fstab << EOF
proc    /proc     proc    nosuid,noexec,gid=proc 0 0
sysfs   /sys      sysfs   defaults 0 0
devpts  /dev/pts  devpts  mode=0620,gid=5 0 0
EOF
# get disk geometry...
REGEXP='^([0-9]+) heads, ([0-9]+) sectors/track, ([0-9]+) cylinders.*$'
GEOMETRY=`fdisk -l "$LOOPDEV" | grep -E "$REGEXP" | sed -r "s@$REGEXP@\1 \2 \3@"`
set $GEOMETRY
cat > "$ROOTFS"/etc/lilo-loop.conf << EOF
boot=$LOOPDEV
disk=$LOOPDEV
  bios=0x80
  heads=$1
  sectors=$2
  cylinders=$3
  partition=$LOOPDEV1
  start=63
delay=1
vga=0
image=/boot/vmlinuz
  initrd=/boot/initrd
  append="root=/dev/sda1"
  label=Linux
EOF
cat > "$ROOTFS"/etc/sysconfig/bootloader << EOF
LOADER_TYPE=none
LOADER_LOCATION=none
EOF
cat > "$ROOTFS"/etc/sysconfig/network/ifcfg-eth0 << EOF
BOOTPROTO='dhcp'
MTU=''
REMOTE_IPADDR=''
STARTMODE='onboot'
EOF
if [ ! -z "$FQDN" ]; then
    echo "$FQDN" > "$ROOTFS"/etc/HOSTNAME
    SHORTNAME=`echo "$FQDN" | sed --regexp-extended 's/^([^\.]+)\..*$/\1/'`
    echo "127.0.0.1 $FQDN $SHORTNAME" >> "$ROOTFS"/etc/hosts
fi
mkdir -p "$ROOTFS"/root/.ssh
ssh-keygen -t rsa -N "" -q -f "$ROOTFS"/root/.ssh/id_rsa
ssh-keygen -y -q -f .ssh/id_rsa > "$ROOTFS"/root/.ssh/authorized_keys
# to jump between nodes without password:
ssh-keygen -y -q -f "$ROOTFS"/root/.ssh/id_rsa >> "$ROOTFS"/root/.ssh/authorized_keys
# configure and enable rest of essential services:
chroot "$ROOTFS" chkconfig earlysyslog on
chroot "$ROOTFS" chkconfig syslog on
chroot "$ROOTFS" chkconfig sshd on
# copy custom files...
echo "*** Extracting tarballs..."
for CUSTOM in $TARBALLS; do
    tar --extract \
        --file "$CUSTOM" \
        --overwrite \
        --preserve-permissions \
        --same-owner \
        --directory "$ROOTFS"
done

## ---------------------------------------------
## creating initrd...
echo "*** Create initrd..."
mount /dev "$ROOTFS"/dev -o bind
# we need mounted /dev to change root password
chroot "$ROOTFS" sh -c "echo '$ROOT_PASSWORD' | passwd --stdin"
mount /proc "$ROOTFS"/proc -o bind
chroot "$ROOTFS" mkinitrd -d "$LOOPDEV1" -f block -m ata_piix
echo "*** Create bootloader..."
chroot "$ROOTFS" lilo -v -C /etc/lilo-loop.conf
cp -Lvf "$ROOTFS"/boot/vmlinuz "$ROOTFS"/boot/initrd "$TMPDIR"/

## ---------------------------------------------
## clean image...
## ---------------------------------------------

## ---------------------------------------------
## umounting target...
echo "*** Unmounting image..."
sync
chroot "$ROOTFS" umount /proc
umount "$ROOTFS"/dev
umount "$ROOTFS"/sys || :
for F in $FAKES; do
    umount "$ROOTFS"/"$F"
done
umount "$ROOTFS"
kpartx -d "$LOOPDEV"
losetup --detach "$LOOPDEV"

## ---------------------------------------------
## cleaning temporary files...
echo "*** Removing temporary files..."
rmdir "$ROOTFS"
rm -rf -- "$TMPDIR"/fakefs/*
rmdir "$TMPDIR"/fakefs

## ---------------------------------------------
## success
echo "Done"

