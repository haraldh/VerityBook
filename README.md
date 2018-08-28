# FedoraBook

WIP

## Create

```bash
$ sudo ./prepare-root.sh \
  --pkglist pkglist.txt \
  --excludelist excludelist.txt \
  --logo logo.bmp --name FEDORABOOK \
  --outdir <IMGDIR>
```

## QEMU disk image
```bash
$ sudo ./mkimage.sh <IMGDIR>  image.raw 
```

## USB stick
```bash
$ sudo ./mkimage.sh <IMGDIR>  /dev/disk/by-path/pci-…-usb…
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
