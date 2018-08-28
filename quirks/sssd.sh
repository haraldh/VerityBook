#---------------
# admin user
cat > "$sysroot"/etc/sssd/sssd.conf <<EOF
[sssd]
domains=local
config_file_version=2
services=nss,pam
[domain/local]
id_provider=local
EOF
chmod 0600 "$sysroot"/etc/sssd/sssd.conf

chroot "$sysroot"

chroot "$sysroot" bash -c 'authselect select sssd with-sudo with-fingerprint with-mkhomedir -f ; sssd -i & sleep 2; sss_useradd admin ; echo -n admin | passwd --stdin admin; echo -n root | passwd --stdin root; usermod -a -G wheel admin; kill %1; wait; :'

systemctl --root="$sysroot" enable sssd.service oddjobd.service
mkdir -p "$sysroot"/usr/share/factory/var/lib
mv "$sysroot"/var/lib/sss "$sysroot"/usr/share/factory/var/lib/

cat >> "$sysroot"/usr/lib/tmpfiles.d/sssd.conf <<EOF
C /var/lib/sss -    -    -    - -
d /var/log/sssd 0750 root root - -
EOF
