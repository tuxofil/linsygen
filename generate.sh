#!/bin/sh -x

# disk image size (in megabytes)
DISKSIZE=1024
ROOT_PASSWORD=root

# Contents of this tarballs will be extracted to image
# root directory preserving file ownership and permissions.
TARBALLS=""

# some utils (zypper) needs an absolute paths only
TMPDIR=`pwd`/tmp
ROOTFS="$TMPDIR"/rootfs
IMG="$TMPDIR"/image.raw

# list of directories, binded from outside of disk image
# (this can reduce overall disk image size, when
# some file are not needed at target system runtime).
FAKES="/tmp /var/cache/zypp /etc/zypp /usr/lib/perl5"

set -e

## ---------------------------------------------
## cleaning...
if [ -d "$ROOTFS" ]; then
    for F in $FAKES; do
        umount "$ROOTFS"/"$F" || :
    done
    umount "$ROOTFS"/dev || :
    umount "$ROOTFS"/proc || :
    chroot "$ROOTFS" umount -a || :
    umount -f "$ROOTFS" || :
    rmdir "$ROOTFS"
fi
if [ -f $IMG ]; then
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
mkdir -p "$TMPDIR"
BYTES=`expr $DISKSIZE '*' 1024 '*' 1024`
dd if=/dev/zero of="$IMG" bs=1 count=1 seek=$BYTES conv=notrunc
LOOPDEV=`losetup --find`
losetup "$LOOPDEV" "$IMG"
parted --script "$LOOPDEV" mklabel msdos
parted --script "$LOOPDEV" mkpart primary ext2 0 $DISKSIZE
kpartx -a "$LOOPDEV"
LOOPDEV1=/dev/mapper/`basename "$LOOPDEV"`p1
mkfs.ext3 "$LOOPDEV1"
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
for URL in `cat repo.list`; do
    zypper \
        --root "$ROOTFS" \
        --non-interactive \
        addrepo \
        --refresh \
        "$URL" "$URL"
done

## ---------------------------------------------
## installing packages...
zypper \
    --root "$ROOTFS" \
    --gpg-auto-import-keys \
    --no-gpg-checks \
    --non-interactive \
    install \
    --name \
    --download-in-advance \
    --auto-agree-with-licenses \
    --no-recommends \
    -- \
    aaa_base sysvinit util-linux lilo kernel-default-base perl openssh \
    less vim pciutils iputils \
    syslog-ng netcfg \
    `cat package.list`

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
mount /dev "$ROOTFS"/dev -o bind
# we need mounted /dev to change root password
chroot "$ROOTFS" sh -c "echo '$ROOT_PASSWORD' | passwd --stdin"
chroot "$ROOTFS" mount /proc
chroot "$ROOTFS" mkinitrd -d "$LOOPDEV1" -f block
chroot "$ROOTFS" lilo -v -C /etc/lilo-loop.conf
cp -Lvf "$ROOTFS"/boot/vmlinuz "$ROOTFS"/boot/initrd "$TMPDIR"/

## ---------------------------------------------
## clean image...
## ---------------------------------------------
zypper \
    --root "$ROOTFS" \
    --non-interactive \
    remove \
    --name \
    --clean-deps \
    -- \
    perl

## ---------------------------------------------
## umounting target...
chroot "$ROOTFS" umount /proc
umount "$ROOTFS"/dev
for F in $FAKES; do
    umount "$ROOTFS"/"$F"
done
umount "$ROOTFS"
kpartx -d "$LOOPDEV"
losetup --detach "$LOOPDEV"

## ---------------------------------------------
## cleaning temporary files...
rmdir "$ROOTFS"
rm -rf -- "$TMPDIR"/fakefs/*
rmdir "$TMPDIR"/fakefs

## ---------------------------------------------
## success
echo "Done"

