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

This is WIP. Please test and report issues, comments or missing components on https://pagure.io/Fedorabook/issues

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
- ensure /data to be on same disk as root
- add "load=<efipath>" to kernel command line via efi stub
- update mechanism
- add proper EFI boot manager entries for A and B
- extend efi stub for recovery boot in the old image
- signing tools
- add admin LUKS key via [public key](https://blog.g3rt.nl/luks-smartcard-or-token.html)
- sssd
- support more clevis pins and mixed pins
- firmware update
- selinux?

## Complete / What works already?
- boot from single efi binary
- dm_verity + squashfs immutable, integrity checked root
- passwd + shadow + group + gshadow decoupled from system in /var
- bind LUKS2 with tpm2 to machine
- /home and /var on single data partition

## Known Failures
- no kernel command line on DELL ( you need a newer systemd https://github.com/systemd/systemd/pull/10001 )
  cp linuxx64.efi.stub to this git repo dir from a compiled upstream systemd
- gnome-software: can't update firmware repo
- systemd: failed to umount /var

## Create

```bash
$ sudo ./prepare-root.sh \
  --releasever 29 \
  --pkglist pkglist.txt \
  --excludelist excludelist.txt \
  --logo logo.bmp --name FEDORABOOK \
  --outdir <IMGDIR>
```

or download a prebuilt [image](https://harald.fedorapeople.org/downloads/fedorabook.tgz),
unpack and use this as ```<IMGDIR>```.


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
   * turn on UEFI boot
   * turn on TPM2
- Enter BIOS boot menu
- Select USB stick
- Login (user: admin, pw: admin)
- Start gnome-terminal
- sudo
- ```clonedisk <usb stick device> <harddisk device>```
- reboot
- remove stick

The first boot takes longer as the system tries to bind the LUKS to the TPM2 on the machine. It also populates /var with the missing directories.

You can always clear the data partition via:
```
# wipefs --all --force /dev/<disk partition 7>
```
and then either make a xfs
```
# mkfs.xfs -L data /dev/<disk partition 7>
```
or luks
```
# echo -n "zero key" | cryptsetup luksFormat --type luks2 /dev/<disk partition 7> /dev/stdin
```

On the media created with mkimage.sh, this is partition number *4*.

## Post Boot

### Persistent journal
```bash
$ sudo mkdir /var/log/journal
```

