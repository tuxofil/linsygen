# Linux system generator

_linsygen_ is a shell script which creates an image file of
a Linux system from scratch. The image can be used later to
run a virtual machine or can be written to a real HDD drive.

There is a few variations of the same script - for each Linux
distro because there is some essential differences between them
(package manager, config locations etc.).

The generation takes near a minute to generate a brand new HDD
image of a Linux system, but the time spent can be much more
when your Internet connection is slow because the most of time
is spent by the package manager to fetch the packages from the
network and install them into the image.

## Supported Linux distros

* Debian;
* OpenSuse;
* CentOS.

## Common algorithm:

* create a file for the image;
* connect the file as a block device to the host system;
* create a partition table at the block device;
* create a primary partition at the block device;
* create an ext3 filesystem on the partition;
* mount the filesystem;
* install all packages listed in a configuration file to
 the mounted filesystem;
* make a primary Linux system configuration (fstab, network etc.);
* install a SSH public key into the filesystem's
 _/root/.ssh/authorized_keys_;
* configure and install a boot loader into the block device;
* unmount the filesystem;
* disconnect the block device.

**Network configuration note:** the target system will try to
configure the network interface with DHCP.

## How to generate

To create an image of the Debian system, cd into a _debian_ subdir,
check contents of a _wheezy.conf_ configuration file.

The configuration file is self-documented. You can define:

* release name (so, you can create squeeze system from a wheezy system);
* DEB-repository mirror to use;
* a target disk size;
* password for the root user;
* a hostname for the target;
* list a DEB packages to install into the target;
* list of tarballs to extract into the target's root FS.

When configuration is ready, type:

```sh
$ sudo ./generate.sh wheezy.conf
```

The script execution needs superuser privileges because of playing
with devices, mounting/unmounting etc.

If everything is OK, you will see _Done_ in the stdout and the script
will finish with 0 exit code.

A results of the generation you'll find in a _tmp_ subdir:

* image.raw - HDD image file in raw format;
* initrd - initial RAM disk;
* vmlinuz - linux kernel.

Note that the _initrd_ and the _vmlinuz_ files are essential only in
rare cases. For the simplest case the _image.raw_ file is all you need.

You'll find SSH identity key in a _.ssh/id_rsa_ file. The identity can
be used to access the generated system via SSH into a root user.

## How to use with QEMU

As optional step you can convert the image into QEMU-known qcow2 format
which consumes less disk space than raw HDD image:

```sh
$ qemu-img convert -O qcow2 tmp/image.raw tmp/image.qcow2
```

QEMU understands both image formats.

To start a QEMU virtual machine, type:

```sh
$ kvm -hda tmp/image.raw
```

or

```sh
$ kvm -hda tmp/image.qcow2
```
