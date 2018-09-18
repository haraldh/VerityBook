#!/usr/bin/bash -ex

# rpcbind only accepts "files altfiles"
# altfiles has no shadow/gshadow support, therefore we need db

sed -i -e 's#^\(passwd:.*\) files#\1 files altfiles db#g;s#^\(shadow:.*\) files#\1 files altfiles db#g;s#^\(group:.*\) files#\1 files altfiles db#g' \
    "$sysroot"/etc/nsswitch.conf

mkdir -p "$sysroot"/usr/db
sed -i -e 's#/var/db#/usr/db#g' "$sysroot"/lib*/libnss_db-2*.so "$sysroot"/var/db/Makefile

egrep -e '^(adm|wheel):.*' "$sysroot"/etc/group > "$sysroot"/etc/group.adm
egrep -e '^(adm|wheel):.*' "$sysroot"/etc/gshadow > "$sysroot"/etc/gshadow.adm
chmod --reference="$sysroot"/etc/group "$sysroot"/etc/group.adm
chmod --reference="$sysroot"/etc/gshadow "$sysroot"/etc/gshadow.adm

sed -i -e 's#:/root:#:/var/roothome:#g' "$sysroot"/etc/passwd

sed -i -e '/^wheel:.*/d;/^adm:.*/d' "$sysroot"/etc/group "$sysroot"/etc/gshadow

chroot "$sysroot" bash -c 'make -C /var/db /usr/db/passwd.db /usr/db/shadow.db /usr/db/gshadow.db /usr/db/group.db && mv /etc/{passwd,shadow,group,gshadow} /lib && >/etc/passwd && > /etc/shadow && >/etc/group && >/etc/gshadow'

mv "$sysroot"/etc/group.adm "$sysroot"/etc/group
mv "$sysroot"/etc/gshadow.adm "$sysroot"/etc/gshadow
chmod --reference="$sysroot"/lib/shadow "$sysroot"/etc/shadow
chmod --reference="$sysroot"/lib/passwd "$sysroot"/etc/passwd

chroot "$sysroot" restorecon /etc/group /etc/gshadow

mkdir -p "$sysroot"/usr/share/factory/cfg
mv "$sysroot"/etc/passwd \
    "$sysroot"/etc/sub{u,g}id \
    "$sysroot"/etc/shadow \
    "$sysroot"/etc/group \
    "$sysroot"/etc/gshadow \
    "$sysroot"/usr/share/factory/cfg/

rm -f "$sysroot"/etc/shadow- "$sysroot"/etc/gshadow-

sed -i -e 's!^# directory = /etc!directory = /var!g' "$sysroot"/etc/libuser.conf

for i in passwd shadow group gshadow .pwd.lock subuid subgid; do
    ln -sfnr "$sysroot"/cfg/"$i" "$sysroot"/etc/"$i"
done

sed -i -e 's#/etc/passwd#/cfg/passwd#g;s#/etc/npasswd#/cfg/npasswd#g' \
    "$sysroot"/usr/lib*/security/pam_unix.so

sed -i -e 's#/etc/shadow#/cfg/shadow#g;s#/etc/nshadow#/cfg/nshadow#g' \
    "$sysroot"/usr/lib*/security/pam_unix.so

sed -i -e 's#/etc/.pwdXXXXXX#/cfg/.pwdXXXXXX#g' \
    "$sysroot"/usr/lib*/security/pam_unix.so

sed -i -e 's#/etc/passwd#/cfg/passwd#g;s#/etc/shadow#/cfg/shadow#g;s#/etc/gshadow#/cfg/gshadow#g;s#/etc/group#/cfg/group#g;s#/etc/subuid#/cfg/subuid#g;s#/etc/subgid#/cfg/subgid#g' \
    "$sysroot"/usr/sbin/user{add,mod,del} \
    "$sysroot"/usr/sbin/group{add,mod,del} \
    "$sysroot"/usr/bin/newgidmap \
    "$sysroot"/usr/bin/newuidmap \
    "$sysroot"/usr/sbin/newusers

sed -i -e 's#/etc/.pwd.lock#/cfg/.pwd.lock#g' \
    "$sysroot"/lib*/libc.so.* \
    "$sysroot"/usr/lib/systemd/libsystemd-shared*.so

[[ -e "$sysroot"/usr/lib*/librpmostree-1.so.1 ]] \
    && sed -i -e 's#/etc/.pwd.lock#/cfg/.pwd.lock#g' \
    "$sysroot"/usr/lib*/librpmostree-1.so.1

mkdir -p "$sysroot"/usr/share/factory/var/roothome
chown +0.+0 "$sysroot"/usr/share/factory/var/roothome

cat > "$sysroot"/usr/lib/tmpfiles.d/home.conf <<EOF
C /var/roothome - - - - -
C /cfg/passwd - - - - -
C /cfg/shadow - - - - -
C /cfg/group - - - - -
C /cfg/gshadow - - - - -
C /cfg/subuid - - - - -
C /cfg/subgid - - - - -
EOF

