chroot "$sysroot" bash -c 'useradd -G wheel admin' 

sed -i -e 's#^\(passwd:.*\) files#\1 files db altfile#g;s#^\(shadow:.*\) files#\1 files altfiles db#g;s#^\(group:.*\) files#\1 files altfiles db#g' \
    "$sysroot"/etc/nsswitch.conf
mkdir -p "$sysroot"/usr/db
sed -i -e 's#/var/db#/usr/db#g' "$sysroot"/lib64/libnss_db-2*.so "$sysroot"/var/db/Makefile

egrep -e '^(adm|wheel):.*' "$sysroot"/etc/group > "$sysroot"/etc/group.admin
egrep -e '^(adm|wheel):.*' "$sysroot"/etc/gshadow > "$sysroot"/etc/gshadow.admin

sed -i -e 's#:/root:#:/var/root:#g' "$sysroot"/etc/passwd

sed -i -e '/^wheel:.*/d;/^adm:.*/d' "$sysroot"/etc/group "$sysroot"/etc/gshadow
sed -i -e '/^admin:.*/d' "$sysroot"/etc/passwd "$sysroot"/etc/shadow "$sysroot"/etc/group "$sysroot"/etc/gshadow

chroot "$sysroot" bash -c 'make -C /var/db /usr/db/passwd.db /usr/db/shadow.db /usr/db/gshadow.db /usr/db/group.db && mv /etc/{passwd,shadow,group,gshadow} /lib && >/etc/passwd && > /etc/shadow && >/etc/group && >/etc/gshadow'

mv "$sysroot"/etc/group.admin "$sysroot"/etc/group
mv "$sysroot"/etc/gshadow.admin "$sysroot"/etc/gshadow
chmod 0000 "$sysroot"/etc/gshadow

chroot "$sysroot" bash -c 'useradd admin; usermod -a -G wheel admin; echo -n admin | passwd --stdin admin'
chroot "$sysroot" bash -c 'passwd -e admin'

mkdir -p "$sysroot"/usr/share/factory/var
mv "$sysroot"/etc/passwd "$sysroot"/etc/sub{u,g}id "$sysroot"/etc/shadow "$sysroot"/etc/group "$sysroot"/etc/gshadow "$sysroot"/usr/share/factory/var

rm -f "$sysroot"/etc/shadow- "$sysroot"/etc/gshadow-

sed -i -e 's!^# directory = /etc!directory = /var!g' "$sysroot"/etc/libuser.conf

for i in passwd shadow group gshadow .pwd.lock subuid subgid; do 
    ln -sfnr "$sysroot"/var/"$i" "$sysroot"/etc/"$i"
done

sed -i -e 's#/etc/passwd#/var/passwd#g;s#/etc/npasswd#/var/npasswd#g' "$sysroot"/usr/lib64/security/pam_unix.so
sed -i -e 's#/etc/shadow#/var/shadow#g;s#/etc/nshadow#/var/nshadow#g' "$sysroot"/usr/lib64/security/pam_unix.so
sed -i -e 's#/etc/.pwdXXXXXX#/var/.pwdXXXXXX#g' "$sysroot"/usr/lib64/security/pam_unix.so
sed -i -e 's#/etc/passwd#/var/passwd#g;s#/etc/shadow#/var/shadow#g;s#/etc/gshadow#/var/gshadow#g;s#/etc/group#/var/group#g;s#/etc/subuid#/var/subuid#g;s#/etc/subgid#/var/subgid#g' "$sysroot"/usr/sbin/user{add,mod,del} "$sysroot"/usr/sbin/group{add,mod,del}
sed -i -e 's#/etc/.pwd.lock#/var/.pwd.lock#g' \
    "$sysroot"/lib*/libc.so.* \
    "$sysroot"/usr/lib*/librpmostree-1.so.1 \
    "$sysroot"/usr/lib/systemd/libsystemd-shared*.so


mkdir -p "$sysroot"/usr/share/factory/home
cp -avxr "$sysroot"/etc/skel "$sysroot"/usr/share/factory/home/admin
chown -R +1000.+1000 "$sysroot"/usr/share/factory/home/admin

mkdir -p "$sysroot"/usr/share/factory/var/root
cp -avxr "$sysroot"/etc/skel "$sysroot"/usr/share/factory/var/root
chown -R +0.+0 "$sysroot"/usr/share/factory/var/root

cat > "$sysroot"/usr/lib/tmpfiles.d/home.conf <<EOF
C /home/admin - - - - -
C /var/root - - - - -
C /var/passwd - - - - -
C /var/shadow - - - - -
C /var/group - - - - -
C /var/gshadow - - - - -
C /var/subuid - - - - -
C /var/subgid - - - - -
C /var/etc - - - - -
EOF
