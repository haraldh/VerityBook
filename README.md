# VerityBook

Let's put all the fancy features together, we developed in the last years:

- Combined kernel+initramfs EFI binaries
- Secure Boot
- clevis with TPM2
- LUKS2
- dm-verity + squashfs root
- Flatpak
- flickerless boot

and build a Chromebook like Fedorabook, where you can install all software via Flatpak.

This is WIP. Please test and report issues, comments or missing components on https://github.com/haraldh/VerityBook/issues

## Goals
- secure boot to the login screen
- immutable base OS
- ensured integrity to the login screen
- encrypted volatile data
- A/B boot switching for updates
- Flatpak
- basic desktop
- optional: bind encrypted data partition to TPM2
- optional: frequent reencryption of the data partition

## Non-Goals
- can't secure against a remote attacker writing anything to disk
- can't secure against a remote attacker scraping secret keys from the kernel

## FAQ
### Isn't encrypting everything enough?
If a remote attacker modifies your binaries in /usr/bin, you cannot be sure of a secure boot 
to the login screen anymore.

### Why readonly /etc?
A remote attacker modifying /etc can completely change your boot sequence and you cannot be sure of a 
secure boot to the login screen anymore.

All configurable files have been whitelisted and moved to /cfg.

## TODO
- merge mkimage.sh and clonedisk
- move all quirks from prepare-root.sh to quirks directory
- source all quirks depending on package installation on command line options
- change partition UUIDs for /data
   * UUID for TPM LUKS
   * UUID for LUKS
   * UUID for unencrypted xfs
- ensure /data to be on same disk as root
- add "load=<efipath>" to kernel command line via efi stub
- add admin LUKS key via [public key](https://blog.g3rt.nl/luks-smartcard-or-token.html)
- sssd
- support more clevis pins and mixed pins
- option to always clean data disk on boot

## Complete / What works already?
- boot from single efi binary
- dm_verity + squashfs immutable, integrity checked root
- passwd + shadow + group + gshadow decoupled from system in /var
- bind LUKS2 with tpm2 to machine
- swap on LUKS2 with tpm2 (no password for resume from disk??)
- /home /cfg and /var on single data partition
- Secure Boot
- selinux
- firmware update (works, but needs a secure boot signed fwup*.efi)

## Known Failures
- systemd: failed to umount /var
- needs a ´´´restorecond -FmvR /cfg /var /home´´´ after first boot, because systemd-tmpfiles does not seem
  to restore all context
- vga switcheroo is not accessible for lockdown=1, because the kernel does not allow access to /sys/kernel/debug

## Create

### Prepare the Image

For reproducible squashfs builds use https://github.com/squashfskit/squashfskit. Clone it in the 
main VerityBook directory and build it.

```console
$ mkdir dist
$ sudo ./prepare-root.sh \
  --pkglist pkglist.txt \
  --excludelist excludelist.txt \
  --name VerityBook \
  --logo logo.bmp \
  --reposd <REPOSDIR> \
  --releasever 31
  --baseoutdir $(realpath dist)
```

This will create the following files and directories:
- `VerityBook` - keep this directory around for updates
  (includes needed passwd/group history and rpmdb)
- `dist/VerityBook-<HASH>.img` - the root image
- `dist/VerityBook-31.<datetime>.json` - metadata of the image 
- `dist/VerityBook-latest.json` - a symlink to the latest version

## Sign the release

Get [efitools](https://github.com/haraldh/efitools.git). Compile and create your keys.
Copy ```LockDown.efi``` ```DB.key``` ```DB.crt``` from efitools to the veritybook directory.

Rename ```DB.key``` ```DB.crt``` to ```VerityBook.key``` and ```VerityBook.crt```

Optionally copy ```Shell.efi``` (might be ```/usr/share/edk2/ovmf/Shell.efi```) to the veritybook directory.

```console
$ sudo ./mkrelease.sh dist/VerityBook-latest.json
```

This will create the following files and directories:
- `dist/VerityBook-<HASH>-efi.tgz` - signed efi binaries
- `dist/VerityBook-31.<datetime>.json.sig` - signature of the metadata

if you want to make deltas:
```console
$ sudo ./mkdelta.sh ${CHECKPOINT:+--checkpoint} dist/VerityBook-latest.json 
```
If `CHECKPOINT` is set, it will remove old images.

then upload to your update server:
```console
$ rsync -Pavorz dist/ <DESTINATION>/
```

## QEMU disk image
```console
$ sudo ./mkimage.sh <IMGDIR> image.raw
```

or with the json file:
```console
$ sudo ./mkimage.sh VerityBook-latest.json image.raw
```

## USB stick
```console
$ sudo ./mkimage.sh <IMGDIR> /dev/disk/by-path/pci-…-usb…
```

or with the json file:
```console
$ sudo ./mkimage.sh VerityBook-latest.json /dev/disk/by-path/pci-…-usb…
```

## Install from USB stick

**Warning**: This will wipe the entire target disk

### Preparation

- Enter BIOS
   * turn on UEFI boot
   * turn on TPM2
   * set a BIOS admin password
- Enter BIOS boot menu
- Select USB stick
- Login (user: admin, pw: admin)
- Start gnome-terminal

### Installation

If you can encrypt your disk via the BIOS, do so.

If you cannot:

- use the option ```--crypttpm2```, if you have a TPM2 chip
- use the option ```--crypt``` otherwise

```console
$ sudo veritybook-clonedisk <options> <usb stick device> <harddisk device>
```

### Post

- reboot
- remove stick

The first boot takes longer as the system tries to bind the LUKS to the TPM2 on the machine.
It also populates ```/var``` with the missing directories.

You can always clear the data partition via:
```console
# wipefs --all --force /dev/<disk partition 5>
```
and then either make a xfs
```console
# mkfs.xfs -L data /dev/<disk partition 5>
```
or LUKS
```console
# echo -n "zero key" | cryptsetup luksFormat --type luks2 /dev/<disk partition 4> /dev/stdin
# echo -n "zero key" | cryptsetup luksFormat --type luks2 /dev/<disk partition 5> /dev/stdin
```

On the media created with mkimage.sh, this is partition number *3*.

## Post Boot

### Persistent journal
```console
$ sudo mkdir /var/log/journal
```

### LUKS
Set a new LUKS password, if you installed with ```--crypt``` or ```--crypttpm2```.
The initial password is ```zero key```.

## Updating

```console
# systemd-inhibit veritybook-update <UPDATE-URL>
```

## Secure Boot

**Warning**: This will wipe all the secure boot keys.
Make sure the BIOS contains an option to restore the default keys. 

- Enter BIOS
   * turn on Secure Boot
   * turn on Setup Mode
- Boot from stick with Shell.efi and LockDown.efi
- Execute LockDown.efi
- reset
- Secure Boot into signed VerityBook release
