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
- firmware update
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

## Known Failures
- no kernel command line on DELL ( you need a newer systemd https://github.com/systemd/systemd/pull/10001 )
  cp linuxx64.efi.stub to this git repo dir from a compiled upstream systemd
- gnome-software: can't update firmware repo
- systemd: failed to umount /var

## Create

### Export your GPG Key

```bash
$ gpg2 --export --export-options export-minimal <KEYNAME> > FedoraBook.gpg
```

### Prepare the Image

```bash
$ sudo ./prepare-root.sh \
  --pkglist pkglist.txt \
  --excludelist excludelist.txt \
  --name FedoraBook \
  --logo logo.bmp \
  --reposd <REPOSDIR> \
  --releasever 29
```

This will create the following files and directories:
- ```FedoraBook``` - keep this directory around for updates (includes needed passwd/group history)
- ```FedoraBook-29.<datetime>``` - the resulting <IMGDIR>
- ```FedoraBook-latest.json``` - a metadata file for the update server

or download a prebuilt [image](https://harald.fedorapeople.org/downloads/fedorabook.tgz),
unpack and use this as ```<IMGDIR>```.

## Sign the release

Get [efitools](https://github.com/haraldh/efitools.git). Compile and create your keys.
Copy ```LockDown.efi``` ```DB.key``` ```DB.crt``` from efitools to the fedorabook directory.

Optionally copy ```Shell.efi``` (might be ```/usr/share/edk2/ovmf/Shell.efi```) to the fedorabook directory.


```bash
$ sudo ./mkrelease.sh FedoraBook-latest.json
```

then upload to your update server:
```bash
$ TARBALL="$(jq -r '.name' FedoraBook-latest.json)-$(jq -r '.version' FedoraBook-latest.json)".tgz
$ scp "$TARBALL" FedoraBook-latest.json <DESTINATION> 
```


## QEMU disk image
```bash
$ sudo ./mkimage.sh <IMGDIR> image.raw 
```

or with the json file:
```bash
$ sudo ./mkimage.sh FedoraBook-latest.json image.raw 
```

## USB stick
```bash
$ sudo ./mkimage.sh <IMGDIR> /dev/disk/by-path/pci-…-usb…
```

or with the json file:
```bash
$ sudo ./mkimage.sh FedoraBook-latest.json /dev/disk/by-path/pci-…-usb…
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

```$ sudo clonedisk <options> <usb stick device> <harddisk device>```

### Post

- reboot
- remove stick

The first boot takes longer as the system tries to bind the LUKS to the TPM2 on the machine.
It also populates ```/var``` with the missing directories.

You can always clear the data partition via:
```
# wipefs --all --force /dev/<disk partition 5>
```
and then either make a xfs
```
# mkfs.xfs -L data /dev/<disk partition 5>
```
or LUKS
```
# echo -n "zero key" | cryptsetup luksFormat --type luks2 /dev/<disk partition 4> /dev/stdin
# echo -n "zero key" | cryptsetup luksFormat --type luks2 /dev/<disk partition 5> /dev/stdin
```

On the media created with mkimage.sh, this is partition number *3*.

## Post Boot

### Persistent journal
```bash
$ sudo mkdir /var/log/journal
```

### LUKS
Set a new LUKS password, if you installed with ```--crypt``` or ```--crypttpm2```.
The initial password is ```zero key```.

## Updating

```bash
# systemd-inhibit update <UPDATE-URL>
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
- Secure Boot into signed FedoraBook release
