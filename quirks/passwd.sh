chroot "$sysroot" bash -c 'useradd admin; usermod -a -G wheel admin; echo -n admin | passwd --stdin admin'
#chroot "$sysroot" bash -c 'passwd -e admin'

mkdir -p "$sysroot"/usr/share/factory/var
mv "$sysroot"/etc/passwd "$sysroot"/etc/sub{u,g}id "$sysroot"/etc/shadow "$sysroot"/etc/group "$sysroot"/etc/gshadow "$sysroot"/usr/share/factory/var

sed -i -e 's!^# directory = /etc!directory = /var!g' "$sysroot"/etc/libuser.conf

for i in passwd shadow group gshadow .pwd.lock subuid subgid; do 
    ln -sfnr "$sysroot"/var/"$i" "$sysroot"/etc/"$i" 
done

sed -i -e 's#/etc/passwd#/var/passwd#g;s#/etc/npasswd#/var/npasswd#g' "$sysroot"/usr/lib64/security/pam_unix.so
sed -i -e 's#/etc/shadow#/var/shadow#g;s#/etc/nshadow#/var/nshadow#g' "$sysroot"/usr/lib64/security/pam_unix.so
sed -i -e 's#/etc/.pwdXXXXXX#/var/.pwdXXXXXX#g' "$sysroot"/usr/lib64/security/pam_unix.so
sed -i -e 's#/etc/passwd#/var/passwd#g;s#/etc/shadow#/var/shadow#g;s#/etc/gshadow#/var/gshadow#g;s#/etc/group#/var/group#g;s#/etc/subuid#/var/subuid#g;s#/etc/subgid#/var/subgid#g' "$sysroot"/usr/sbin/user{add,mod,del} "$sysroot"/usr/sbin/group{add,mod,del}

mkdir -p "$sysroot"/usr/share/factory/home
cp -avxr "$sysroot"/etc/skel "$sysroot"/usr/share/factory/home/admin
chown -R +1000.+1000 "$sysroot"/usr/share/factory/home/admin

cat > "$sysroot"/usr/lib/tmpfiles.d/home.conf <<EOF
C /home/admin - - - - -
C /var/passwd - - - - -
C /var/shadow - - - - -
C /var/group - - - - -
C /var/gshadow - - - - -
C /var/subuid - - - - -
C /var/subgid - - - - -
C /var/etc - - - - -
EOF
