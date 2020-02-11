#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

installkernel() {
    instmods =drivers/char/tpm
}

install() {
    inst_multiple \
        wipefs sfdisk dd mkfs.xfs mkswap chroot mountpoint mkdir stat openssl \
	    clevis clevis-luks-bind jose clevis-encrypt-tpm2 clevis-decrypt \
	    clevis-luks-unlock clevis-decrypt-tpm2 \
	    cryptsetup tail sort pwmake mktemp swapon \
	    tpm2_pcrextend tpm2_createprimary tpm2_pcrlist tpm2_createpolicy \
	    tpm2_create tpm2_load tpm2_unseal tpm2_takeownership sleep setfiles \
	    /usr/lib/systemd/system/clevis-luks-askpass.path \
	    /usr/lib/systemd/system/clevis-luks-askpass.service \
	    /usr/libexec/clevis-luks-askpass \
	    /usr/lib64/libtss2-esys.so.0 \
	    /usr/lib64/libtss2-tcti-device.so.0 \
        ${NULL}

	inst_dir /usr/share/cracklib
    inst_hook pre-pivot 80 "$moddir/pre-pivot.sh"
}
