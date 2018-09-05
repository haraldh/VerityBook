# FedoraBook

Let's put all the fancy features together, we developed in the last years:

- Combined kernel+initramfs EFI binaries
- Secure Boot
- clevis with TPM2
- LUKS2
- dm-verity + squashfs root
- Flatpak
- flickerless boot

and build a Chromebook like Fedorabook, where you can install all software via Flatpak.

This is WIP. Please test and report issues or comments on https://pagure.io/Fedorabook/issues

## Goals
- secure boot to the login screen
- immutable /usr and maybe /etc
- ensured integrity to the login screen
- encrypted volatile data
- A/B boot switching for updates
- Flatpak
- basic desktop
- optional: bind encrypted data partition to TPM2
- optional: frequent reencryption of the data partition

## Non-Goals
- can't secure against someone writing anything to disk
- can't secure against someone scraping secret keys from the kernel

## TODO
- merge mkimage.sh and clonedisk
- change partition UUIDs for /data
   * UUID for TPM LUKS
   * UUID for LUKS
   * UUID for unencrypted xfs
- update mechanism
- add proper EFI boot manager entries for A and B
- extend efi stub for recovery boot in the old image
- signing tools
- firmware update
- selinux?

## Known Failures
- gnome-software: can't update firmware repo

## Create

```bash
$ sudo ./prepare-root.sh \
  --releasever 29 \
  --pkglist pkglist.txt \
  --excludelist excludelist.txt \
  --logo logo.bmp --name FEDORABOOK \
  --outdir <IMGDIR>
```

## QEMU disk image
```bash
$ sudo ./mkimage.sh <IMGDIR> image.raw 
```

## USB stick
```bash
$ sudo ./mkimage.sh <IMGDIR> /dev/disk/by-path/pci-…-usb…
```

## Install from USB stick

- Enter BIOS
   - turn on UEFI boot
   - turn on TPM2
- Enter BIOS boot menu
- Select USB stick
- Login (user: admin, pw: admin)
- Start gnome-terminal
- sudo
- ```clonedisk <usb stick device> <harddisk device>```
- reboot
- remove stick

## Post Boot

### Persistent journal
```bash
$ sudo mkdir /var/log/journal
```

