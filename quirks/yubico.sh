#!/bin/bash -ex

#
# Quirk to enforce login and sudo with a Yubikey
#

[[ -f "$sysroot"/etc/pam.d/sudo ]] && \
sed -i -e 's#auth\s*include\s*system-auth#auth     required pam_yubico.so mode=challenge-response\nauth     include  system-auth#g' \
    "$sysroot"/etc/pam.d/sudo

[[ -f "$sysroot"/etc/pam.d/gdm-password ]] && \
sed -i -e 's#auth\s*substack\s*password-auth#auth required pam_yubico.so mode=challenge-response\nauth        substack      password-auth#g' \
    "$sysroot"/etc/pam.d/gdm-password

:
