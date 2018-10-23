#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

Creates a directory with a readonly root on squashfs, a dm_verity file and an EFI executable

  --help             Display this help
  --pkglist FILE     The packages to install read from FILE (default: pkglist.txt)
  --excludelist FILE The packages to install read from FILE (default: excludelist.txt)
  --releasever NUM   Used Fedora release version NUM (default: $VERSION_ID)
  --outdir DIR       Creates DIR and puts all files in there (default: NAME-NUM-DATE)
  --baseoutdir DIR   Parent directory of --outdir
  --name NAME        The NAME of the product (default: FedoraBook)
  --logo FILE        Uses the .bmp FILE to display as a splash screen (default: logo.bmp)
  --quirks LIST      Source the list of quirks from the quikrs directory
  --gpgkey FILE      Use FILE as the signing gpg key
  --reposd DIR       Use DIR as the dnf repository directory
  --noupdate         Do not install from Fedora Updates
  --noscripts        Do not rpm scripts
  --statedir DIR     Use DIR to preserve state across builds like uid/gid
  --check-update     Only check for updates
EOF
}

CURDIR=$(pwd)

PROGNAME=${0##*/}
BASEDIR=${0%/*}
WITH_UPDATES=1

TEMP=$(
    getopt -o '' \
        --long pkglist: \
        --long excludelist: \
        --long outdir: \
        --long baseoutdir: \
        --long name: \
        --long releasever: \
        --long logo: \
        --long quirks: \
        --long crt: \
        --long reposd: \
        --long statedir: \
        --long noupdates \
        --long noscripts \
        --long check-update \
        -- "$@"
    )

if (( $? != 0 )); then
    usage >&2
    exit 1
fi

eval set -- "$TEMP"
unset TEMP
. /etc/os-release
unset NAME
declare -a QUIRKS

while true; do
    case "$1" in
        '--pkglist')
            if [[ -f $2 ]]; then
                PKGLIST=$(<$2)
            else
                PKGLIST="$2"
            fi
            shift 2; continue
            ;;
        '--excludelist')
            if [[ -f $2 ]]; then
                EXCLUDELIST=$(<$2)
            else
                EXCLUDELIST="$2"
            fi
            shift 2; continue
            ;;
        '--outdir')
            OUTDIR="$2"
            shift 2; continue
            ;;
        '--baseoutdir')
            BASEOUTDIR="$2"
            shift 2; continue
            ;;
        '--name')
            NAME="$2"
            shift 2; continue
            ;;
        '--releasever')
            RELEASEVER="$2"
            shift 2; continue
            ;;
        '--logo')
            LOGO="$2"
            shift 2; continue
            ;;
        '--quirks')
            QUIRKS+=( $2 )
            shift 2; continue
            ;;
        '--crt')
            CRT="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--reposd')
            REPOSD="$2"
            shift 2; continue
            ;;
        '--statedir')
            STATEDIR="$2"
            shift 2; continue
            ;;
        '--noupdates')
            unset WITH_UPDATES
            shift 1; continue
            ;;
        '--noscripts')
            NO_SCRIPTS=1
            shift 1; continue
            ;;
        '--check-update')
            CHECK_UPDATE=1
            shift 1; continue
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo 'Internal error!' >&2
            exit 1
            ;;
    esac
done

[[ $EXCLUDELIST ]] || [[ -f excludelist.txt ]] && EXCLUDELIST=$(<excludelist.txt)
NAME=${NAME:-"FedoraBook"}
RELEASEVER=${RELEASEVER:-$VERSION_ID}
VERSION_ID="${RELEASEVER}.$(date -u +'%Y%m%d%H%M%S')"
BASEOUTDIR=${BASEOUTDIR:-"$CURDIR"}
OUTDIR=${OUTDIR:+"${BASEOUTDIR}/${OUTDIR}"}
OUTDIR=${OUTDIR:-"${BASEOUTDIR}/${NAME}-${VERSION_ID}"}
CRT=${CRT:-${NAME}.crt}
REPOSD=${REPOSD:-/etc/yum.repos.d}
STATEDIR=${STATEDIR:-"${BASEDIR}/${NAME}"}

readonly OLD_SELINUX=$(getenforce)

[[ $TMPDIR ]] || TMPDIR=/var/tmp
readonly TMPDIR="$(realpath -e "$TMPDIR")"
[ -d "$TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: Invalid tmpdir '$tmpdir'." >&2
    exit 1
}

readonly MY_TMPDIR="$(mktemp -p "$TMPDIR/" -d -t ${PROGNAME}.XXXXXX)"
[ -d "$MY_TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: mktemp -p '$TMPDIR/' -d -t ${PROGNAME}.XXXXXX failed." >&2
    exit 1
}

# clean up after ourselves no matter how we die.
trap '
    ret=$?;
    for i in "$sysroot"/{dev,sys/fs/selinux,sys,proc,run,var/lib/rpm,var/cache/dnf}; do
       [[ -d "$i" ]] && mountpoint -q "$i" && umount "$i"
    done
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    (( $ret != 0 )) && [[ "$OUTDIR" ]] && rm -rf --one-file-system -- "$OUTDIR"
    setenforce $OLD_SELINUX
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

setenforce 0

if ! [[ -f "${BASEDIR}"/linuxx64.efi.stub ]]; then
    cp /lib/systemd/boot/efi/linuxx64.efi.stub "${BASEDIR}"/linuxx64.efi.stub
fi

readonly sysroot="${MY_TMPDIR}/sysroot"

# We need to preserve old uid/gid
mkdir -p "$sysroot"/etc
for i in passwd shadow group gshadow subuid subgid; do
    [[ -e "${STATEDIR}/$i" ]] || continue
    cp -a "${STATEDIR}/$i" "$sysroot"/etc/"$i"
done

chown -R +0.+0 "$sysroot"
for i in "$sysroot"/etc/{shadow,gshadow}; do
    [[ -e "$i" ]] || continue
    chmod 0000 "$i"
done

mkdir -p "$sysroot"/{dev,proc,sys,run}
mount -o bind /proc "$sysroot/proc"
mount -o bind /run "$sysroot/run"
mount -o bind /sys "$sysroot/sys"
mount -t devtmpfs devtmpfs "$sysroot/dev"

mkdir -p "$sysroot"/var/cache/dnf
mkdir -p "$STATEDIR"/dnf
mount -o bind "$STATEDIR"/dnf "$sysroot"/var/cache/dnf

if [[ $CHECK_UPDATE ]]; then
    mkdir -p "$STATEDIR"/rpm
    mkdir -p "$sysroot"/var/lib/rpm
    mount -o bind "$STATEDIR"/rpm "$sysroot"/var/lib/rpm
    DNF_COMMAND="check-update"
else
    DNF_COMMAND="install -y"
fi

if [[ $NO_SCRIPTS ]]; then
    mkdir "$sysroot"/usr
    mkdir "$sysroot"/usr/bin
    mkdir "$sysroot"/usr/sbin
    mkdir "$sysroot"/usr/lib
    mkdir "$sysroot"/usr/lib/debug
    mkdir "$sysroot"/usr/lib/debug/usr/
    mkdir "$sysroot"/usr/lib/debug/usr/bin
    mkdir "$sysroot"/usr/lib/debug/usr/sbin
    mkdir "$sysroot"/usr/lib/debug/usr/lib
    mkdir "$sysroot"/usr/lib/debug/usr/lib64
    mkdir "$sysroot"/usr/lib64
    ln -s usr/bin "$sysroot"/bin
    ln -s usr/sbin "$sysroot"/sbin
    ln -s usr/lib "$sysroot"/lib
    ln -s usr/bin "$sysroot"/usr/lib/debug/bin
    ln -s usr/lib "$sysroot"/usr/lib/debug/lib
    ln -s usr/lib64 "$sysroot"/usr/lib/debug/lib64
    ln -s ../.dwz "$sysroot"/usr/lib/debug/usr/.dwz
    ln -s usr/sbin "$sysroot"/usr/lib/debug/sbin
    ln -s usr/lib64 "$sysroot"/lib64
    mkdir "$sysroot"/run || :
    mkdir "$sysroot"/var || :
    ln -s ../run "$sysroot"/var/run
    ln -s ../run/lock "$sysroot"/var/lock
fi

dnf -v --nogpgcheck \
    --installroot "$sysroot"/ \
    --releasever "$RELEASEVER" \
    --exclude="$EXCLUDELIST" \
    --setopt=keepcache=True \
    --setopt=reposdir="$REPOSD" \
    ${NO_SCRIPTS:+ --setopt=tsflags=noscripts} \
    ${DNF_COMMAND} \
    dracut \
    passwd \
    rootfiles \
    systemd \
    systemd-udev \
    kernel \
    bash \
    sudo \
    strace \
    xfsprogs \
    pciutils \
    microcode_ctl \
    nss-altfiles \
    nss_db \
    keyutils \
    make \
    less \
    polkit \
    util-linux \
    rng-tools \
    openssl \
    cryptsetup \
    clevis \
    clevis-luks \
    clevis-systemd \
    jose \
    tpm2-tools \
    coreutils \
    libpwquality \
    tpm2-tss \
    ncurses-base \
    tar \
    gzip \
    p11-kit \
    efibootmgr \
    jq \
    gnupg2 \
    veritysetup \
    policycoreutils \
    selinux-policy-targeted \
    selinux-policy-devel \
    libselinux-utils \
    audit \
    dosfstools \
    $PKGLIST

RET=$?

if [[ $CHECK_UPDATE ]]; then
    exit $RET
fi

for i in passwd shadow group gshadow subuid subgid; do
    [[ -e "$sysroot"/etc/${i}.rpmnew ]] || continue
    while read line || [[ $line ]]; do
        IFS=: read user _ <<<$line
        grep -E -q "^$user:" "$sysroot"/etc/${i} && continue
        echo "$line" >> "$sysroot"/etc/${i}
    done <"$sysroot"/etc/${i}.rpmnew
done

find "$sysroot" -name '*.rpmnew' -print0 | xargs -0 rm -fv

# We need to preserve old uid/gid
mkdir -p "${STATEDIR}"
for i in passwd shadow group gshadow subuid subgid; do
    cp "$sysroot"/etc/"$i" "${STATEDIR}"
    chown "$USER" "${STATEDIR}/$i"
    chmod u+r "${STATEDIR}/$i"
done

# ------------------------------------------------------------------------------
# selinux
#sed -i -e 's#^SELINUX=.*#SELINUX=permissive#g' "$sysroot"/etc/selinux/config
mount -t selinuxfs none "$sysroot/sys/fs/selinux"
chroot "$sysroot" semanage fcontext --noreload -a -e /etc /cfg
cp "$CURDIR"/FedoraBook.te "$CURDIR"/FedoraBook.fc "$sysroot"/var/tmp
chroot "$sysroot" bash -c '
    cd /var/tmp
    make -f  /usr/share/selinux/devel/Makefile
    semodule --noreload -i FedoraBook.pp
'
umount "$sysroot/sys/fs/selinux"

cp "$CURDIR/clonedisk.sh" "$sysroot"/usr/bin/fedorabook-clonedisk
cp "$CURDIR/update.sh" "$sysroot"/usr/bin/fedorabook-update
cp "$CURDIR/mkimage.sh" "$sysroot"/usr/bin/fedorabook-mkimage

mkdir -p "$sysroot"/etc/pki/${NAME}
openssl x509 -in "${CURDIR}/${CRT}" -pubkey -noout > "$sysroot"/etc/pki/${NAME}/pubkey
cp "${CURDIR}/${CRT}" "$sysroot"/etc/pki/${NAME}/crt

rpm --root "$sysroot" -qa | sort > "$sysroot"/usr/rpm-list.txt

cp "${BASEDIR}"/pre-pivot.sh "$sysroot"/pre-pivot.sh
cp -avr "${BASEDIR}"/10verity "$sysroot"/usr/lib/dracut/modules.d/
chmod 0755 "$sysroot"/pre-pivot.sh

KVER=$(cd "$sysroot"/lib/modules/; ls -1d ??* | tail -1)

sed -ie 's#\(tpm2_[^ ]*\) #\1 -T device:${TPM2TOOLS_DEVICE_FILE[0]} #g' "$sysroot"/usr/bin/clevis-*-tpm2

#---------------
# rngd
ln -fsnr "$sysroot"/usr/lib/systemd/system/rngd.service "$sysroot"/usr/lib/systemd/system/basic.target.wants/rngd.service

if [[ $NO_SCRIPTS ]]; then
    chroot  "$sysroot" depmod -a $KVER
fi

chroot  "$sysroot" \
	dracut -N --kver $KVER --force \
	--filesystems "squashfs vfat xfs" \
	--add-drivers "=drivers/char/tpm" \
	-m "bash systemd systemd-initrd modsign crypt dm kernel-modules qemu rootfs-block" \
	-m "udev-rules dracut-systemd base fs-lib shutdown terminfo resume verity" \
	--install "clonedisk wipefs sfdisk dd mkfs.xfs mkswap chroot mountpoint mkdir stat openssl" \
	--install "clevis clevis-luks-bind jose clevis-encrypt-tpm2 clevis-decrypt clevis-luks-unlock clevis-decrypt-tpm2"  \
	--install "cryptsetup tail sort pwmake mktemp swapon" \
	--install "tpm2_pcrextend tpm2_createprimary tpm2_pcrlist tpm2_createpolicy" \
	--install "tpm2_create tpm2_load tpm2_unseal tpm2_takeownership chcon sleep" \
	--include /pre-pivot.sh /lib/dracut/hooks/pre-pivot/80-pre-pivot.sh \
	--install /usr/lib/systemd/system/clevis-luks-askpass.path \
	--install /usr/lib/systemd/system/clevis-luks-askpass.service \
	--install /usr/libexec/clevis-luks-askpass \
	--include /usr/share/cracklib/ /usr/share/cracklib/ \
	--install /usr/lib64/libtss2-esys.so.0 \
	--install /usr/lib64/libtss2-tcti-device.so.0 \
	--install /sbin/rngd \
	--install /usr/lib/systemd/system/basic.target.wants/rngd.service \
	--reproducible \
	/boot/initrd

#chroot  "$sysroot" bash -i

rm "$sysroot"/pre-pivot.sh

umount "$sysroot"/var/cache/dnf

mkdir -p "$sysroot"/usr/share/factory/{var,cfg}

#---------------
# tpm2-tss
if [[ -f "$sysroot"/usr/lib/udev/rules.d/60-tpm-udev.rules ]]; then
    echo 'tss:x:59:59:tpm user:/dev/null:/sbin/nologin' >> "$sysroot"/etc/passwd
    echo 'tss:!!:15587::::::' >> "$sysroot"/etc/shadow
    echo 'tss:x:59:' >> "$sysroot"/etc/group
    echo 'tss:!::' >> "$sysroot"/etc/gshadow
fi

#---------------
# quirks
for q in "${QUIRKS[@]}"; do
    . "${BASEDIR}"/quirks/"$q".sh
done

#---------------
# nss / passwd /shadow etc..

#chroot "$sysroot" bash -c 'echo -n admin | passwd --stdin root'

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

chroot "$sysroot" bash -c '
    make -C \
        /var/db \
        /usr/db/passwd.db \
        /usr/db/shadow.db \
        /usr/db/gshadow.db \
        /usr/db/group.db \
    && mv /etc/{passwd,shadow,group,gshadow} /lib \
    && >/etc/passwd \
    && > /etc/shadow \
    && >/etc/group \
    && >/etc/gshadow
'

mv "$sysroot"/etc/group.adm "$sysroot"/etc/group
mv "$sysroot"/etc/gshadow.adm "$sysroot"/etc/gshadow
chmod --reference="$sysroot"/lib/shadow "$sysroot"/etc/shadow
chmod --reference="$sysroot"/lib/passwd "$sysroot"/etc/passwd

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

#---------------
# timesync
ln -fsnr "$sysroot"/usr/lib/systemd/system/systemd-timesyncd.service "$sysroot"/usr/lib/systemd/system/sysinit.target.wants/systemd-timesyncd.service

#---------------
# ssh
if [[ -d "$sysroot"/etc/ssh ]]; then
    mv "$sysroot"/etc/ssh "$sysroot"/usr/share/factory/cfg/ssh
    ln -sfnr "$sysroot"/cfg/ssh "$sysroot"/etc/ssh
    cat >> "$sysroot"/usr/lib/tmpfiles.d/ssh.conf <<EOF
C /cfg/ssh - - - - -
EOF
fi

#---------------
# NetworkManager
if [[ -d "$sysroot"/etc/NetworkManager ]]; then
    mv "$sysroot"/etc/NetworkManager "$sysroot"/usr/share/factory/cfg/
    ln -fsnr "$sysroot"/cfg/NetworkManager "$sysroot"/etc/NetworkManager
    cat >> "$sysroot"/usr/lib/tmpfiles.d/NetworkManager.conf <<EOF
d /var/lib/NetworkManager 0755 root root - -
C /cfg/NetworkManager - - - - -
d /run/NetworkManager 0755 root root - -
EOF
    rm -fr "$sysroot"/etc/sysconfig/network-scripts
    rm -fr "$sysroot"/usr/lib64/NetworkManager/*/libnm-settings-plugin-ifcfg-rh.so
fi

#---------------
# libvirt
if [[ -d "$sysroot"/etc/libvirt ]]; then
    mv "$sysroot"/etc/libvirt "$sysroot"/usr/share/factory/cfg/
    ln -fsnr "$sysroot"/cfg/libvirt "$sysroot"/etc/libvirt
    cat >> "$sysroot"/usr/lib/tmpfiles.d/libvirt.conf <<EOF
C /cfg/libvirt - - - - -
EOF
fi

#---------------
# resolv.conf
ln -fsrn "$sysroot"/run/NetworkManager/resolv.conf "$sysroot"/etc/resolv.conf
echo 'f /run/NetworkManager/resolv.conf 0755 root root - ' >> "$sysroot"/usr/lib/tmpfiles.d/resolv.conf


#---------------
# vconsole.conf
ln -fsnr "$sysroot"/cfg/vconsole.conf "$sysroot"/etc/vconsole.conf
echo -e 'FONT=latarcyrheb-sun16\nKEYMAP=us' > "$sysroot"/usr/share/factory/cfg/vconsole.conf

#---------------
# locale.conf
ln -fsnr "$sysroot"/cfg/locale.conf "$sysroot"/etc/locale.conf
echo 'LANG=en_US.UTF-8' > "$sysroot"/usr/share/factory/cfg/locale.conf

#---------------
# localtime
ln -s /usr/share/zoneinfo/GMT "$sysroot"/usr/share/factory/cfg/localtime
ln -fsnr "$sysroot"/cfg/localtime "$sysroot"/etc/localtime

#---------------
# machine-id
rm -f "$sysroot"/etc/machine-id
ln -fsnr "$sysroot"/cfg/machine-id "$sysroot"/etc/machine-id

#---------------
# adjtime
mv "$sysroot"/etc/adjtime "$sysroot"/usr/share/factory/cfg/adjtime
ln -fsnr "$sysroot"/cfg/adjtime "$sysroot"/etc/adjtime

sed -i -e 's#/etc/locale.conf#/cfg/locale.conf#g;s#/etc/vconsole.conf#/cfg/vconsole.conf#g;s#/etc/X11/xorg.conf.d#/cfg/X11/xorg.conf.d#g' \
 "$sysroot"/usr/lib/systemd/systemd-localed

sed -i -e 's#/etc/adjtime#/cfg/adjtime#g;s#/etc/localtime#/cfg/localtime#g;s#/etc/machine-id#/cfg/machine-id#g' \
    "$sysroot"/usr/lib/systemd/systemd-timedated \
    "$sysroot"/usr/lib/systemd/libsystemd-shared*.so \
    "$sysroot"/usr/lib/systemd/systemd \
    "$sysroot"/usr/bin/systemd-machine-id-setup \
    "$sysroot"/usr/bin/systemd-firstboot \
    "$sysroot"/usr/lib/systemd/system/systemd-machine-id-commit.service \
    "$sysroot"/lib*/libc.so.*

sed -i -e 's#ReadWritePaths=/etc#ReadWritePaths=/cfg#g' \
    "$sysroot"/lib/systemd/system/systemd-localed.service \
    "$sysroot"/lib/systemd/system/systemd-timedated.service \
    "$sysroot"/lib/systemd/system/systemd-hostnamed.service

#cat > "$sysroot"/lib/systemd/system-generators/machine-id <<EOF
##!/bin/bash -x
#/sbin/restorecon -m -F -v /cfg /var /home /cfg/machine-id /var/run /var/lock
#exit 0
#EOF
#chmod a+x "$sysroot"/lib/systemd/system-generators/machine-id

cat >> "$sysroot"/usr/lib/tmpfiles.d/00-basics.conf <<EOF
C /cfg/vconsole.conf - - - - -
C /cfg/locale.conf - - - - -
C /cfg/localtime - - - - -
C /cfg/adjtime - - - - -
z /home - - - - -
z /cfg - - - - -
z /cfg/machine-id 0444 - - - -
z /var - - - - -
EOF

#---------------
# X11
if [[ -d "$sysroot"/etc/X11/xorg.conf.d ]]; then
    mkdir -p "$sysroot"/usr/share/factory/cfg/X11/xorg.conf.d
    ln -fsnr "$sysroot"/cfg/X11/xorg.conf.d/00-keyboard.conf "$sysroot"/etc/X11/xorg.conf.d/00-keyboard.conf
    cat >> "$sysroot"/usr/lib/tmpfiles.d/X11.conf <<EOF
C /cfg/X11/xorg.conf.d - - - - -
EOF
fi

#---------------
# autofs
if [[ -f "$sysroot"/etc/autofs.conf ]]; then
    mkdir -p "$sysroot"/net
    systemctl --root "$sysroot" enable autofs
fi

#---------------
# udev dri/card0
cp "${BASEDIR}"/systemd-udev-settle-dri.service "$sysroot"/usr/lib/systemd/system/
ln -fsnr "$sysroot"/usr/lib/systemd/system/systemd-udev-settle-dri.service \
   "$sysroot"/usr/lib/systemd/system/multi-user.target.wants/systemd-udev-settle-dri.service

#---------------
# Flathub
if [[ -d "$sysroot"/usr/share/flatpak ]]; then
    mkdir -p "$sysroot"/usr/share/factory/var/lib/
    curl https://flathub.org/repo/flathub.flatpakrepo -o "$sysroot"/usr/share/flatpak/flathub.flatpakrepo
    chroot "$sysroot" /usr/bin/flatpak remote-add --if-not-exists flathub /usr/share/flatpak/flathub.flatpakrepo
fi

#---------------
# inotify
mkdir -p "$sysroot"/etc/sysctl.d
cat > "$sysroot"/etc/sysctl.d/inotify.conf <<EOF
fs.inotify.max_user_watches = $((8192*10))
EOF

#---------------
# gnome-initial-setup
if [[ -f "$sysroot"/usr/share/gnome-initial-setup/vendor.conf ]]; then
    > "$sysroot"/usr/share/gnome-initial-setup/vendor.conf
fi

#---------------
# LVM
rm -f "$sysroot"/etc/systemd/system/sysinit.target.wants/lvm*
rm -f "$sysroot"/etc/systemd/system/*.wants/multipathd*

#---------------
# DNF
rm -f "$sysroot"/etc/systemd/system/multi-user.target.wants/dnf-makecache.timer

#---------------
# network-online.target
rm -fr "$sysroot"/etc/systemd/system/network-online.target.wants

#---------------
# rsyslog link
rm -fr "$sysroot"/etc/systemd/system/syslog.service

#---------------
# nested kvm
if [[ -f "$sysroot"/etc/modprobe.d/kvm.conf ]]; then
    sed -i -e 's/#options/options/g' "$sysroot"/etc/modprobe.d/kvm.conf
fi

if [[ -f /etc/fwupd/uefi.conf ]]; then
    sed -i -e 's#RequireShimForSecureBoot=.*#RequireShimForSecureBoot=false#g' \
        "$sysroot"/etc/fwupd/uefi.conf
fi

#---------------
# CA
chroot "$sysroot" update-ca-trust

#---------------
# var
rm -fr "$sysroot"/var/lib/selinux
rm -fr "$sysroot"//usr/lib/fontconfig/cache
rm -fr "$sysroot"/var/lib/rpm
rm -fr "$sysroot"/var/lib/sepolgen
rm -fr "$sysroot"/var/lib/dnf
rm -fr "$sysroot"/var/lib/flatpak/repo/tmp
rm -fr "$sysroot"/var/log/dnf*
rm -fr "$sysroot"/var/cache/*/*
rm -fr "$sysroot"/var/tmp/*
mv "$sysroot"/lib/tmpfiles.d/var.conf "$sysroot"/lib/tmpfiles.d-var.conf
chroot "$sysroot" bash -c '
    for i in $(find -H /var -xdev -type d); do
        grep " $i " -r -q /lib/tmpfiles.d && \
        ! grep " $i " -q /lib/tmpfiles.d-var.conf \
        && rm -vfr --one-file-system "$i"
    done
    :
'
cp -avxr "$sysroot"/var/* "$sysroot"/usr/share/factory/var/
rm -f "$sysroot"/usr/share/factory/var/{run,lock}

chroot "$sysroot" bash -c '
    for i in $(find -H /var -xdev -maxdepth 2 -mindepth 1 -type d); do
        echo "C $i - - - - -"
    done >> /usr/lib/tmpfiles.d/var-quirk.conf
    :
'
echo 'C /var/mail - - - - -' >>  "$sysroot"/usr/lib/tmpfiles.d/var-quirk.conf

mv "$sysroot"/lib/tmpfiles.d-var.conf "$sysroot"/lib/tmpfiles.d/var.conf

if [[ -f "$sysroot"/etc/os-release ]]; then
    sed -i -e "s#VERSION_ID=.*#VERSION_ID=$VERSION_ID#" "$sysroot"/etc/os-release
    sed -i -e "s#NAME=.*#NAME=$NAME#" "$sysroot"/etc/os-release
fi

mv -v "$sysroot"/boot/initrd "$MY_TMPDIR"/initrd

cp "$sysroot"/lib/modules/*/vmlinuz "$MY_TMPDIR"/linux

if [[ -d "$sysroot"/boot/efi/EFI/fedora ]]; then
    mkdir -p "$MY_TMPDIR"/efi/EFI
    mv "$sysroot"/boot/efi/EFI/fedora "$MY_TMPDIR"/efi/EFI
fi

rm -fr "$sysroot"/{boot,root}
ln -sfnr "$sysroot"/var/roothome "$sysroot"/root
rm -fr "$sysroot"/var
rm -fr "$sysroot"/home
rm -f "$sysroot"/etc/yum.repos.d/*
mkdir -p "$sysroot"/{var,home,cfg,net,efi}

# ------------------------------------------------------------------------------
# SELinux relabel all the files
mount -t selinuxfs none "$sysroot/sys/fs/selinux"
chroot "$sysroot" restorecon -m -v -F -R /usr /etc
chroot "$sysroot" restorecon -m -v -F /cfg /efi /home /var /net /root
umount "$sysroot/sys/fs/selinux"

# ------------------------------------------------------------------------------
# umount everything
for i in "$sysroot"/{dev,sys/fs/selinux,sys,proc,run}; do
    [[ -d "$i" ]] && mountpoint -q "$i" && umount "$i"
done

# ------------------------------------------------------------------------------
# sysroot
mksquashfs "$MY_TMPDIR"/sysroot "$MY_TMPDIR"/root.squashfs.img

# ------------------------------------------------------------------------------
# verity
ROOT_HASH=$(veritysetup format "$MY_TMPDIR"/root.squashfs.img "$MY_TMPDIR"/root.verity.img |& tail -1 | { read a b c; echo $c; } )

echo "$ROOT_HASH" > "$MY_TMPDIR"/root-hash.txt

ROOT_UUID=${ROOT_HASH:32:8}-${ROOT_HASH:40:4}-${ROOT_HASH:44:4}-${ROOT_HASH:48:4}-${ROOT_HASH:52:12}
ROOT_SIZE=$(stat --printf '%s' "$MY_TMPDIR"/root.squashfs.img)
HASH_SIZE=$(stat --printf '%s' "$MY_TMPDIR"/root.verity.img)
cat "$MY_TMPDIR"/root.verity.img >> "$MY_TMPDIR"/root.squashfs.img
mv "$MY_TMPDIR"/root.squashfs.img "$MY_TMPDIR"/root.img
IMAGE_SIZE=$(stat --printf '%s' "$MY_TMPDIR"/root.img)

# ------------------------------------------------------------------------------
# make bootx64.efi
echo -n "lockdown=1 quiet rd.shell=0 video=efifb:nobgrt "\
 "verity.imagesize=$IMAGE_SIZE verity.roothash=$ROOT_HASH verity.root=PARTUUID=$ROOT_UUID " \
 "verity.hashoffset=$ROOT_SIZE raid=noautodetect root=/dev/mapper/root" > "$MY_TMPDIR"/options.txt

echo -n "${NAME}-${VERSION_ID}" > "$MY_TMPDIR"/release.txt
objcopy \
    --add-section .release="$MY_TMPDIR"/release.txt --change-section-vma .release=0x20000 \
    --add-section .cmdline="$MY_TMPDIR"/options.txt --change-section-vma .cmdline=0x30000 \
    ${LOGO:+--add-section .splash="$LOGO" --change-section-vma .splash=0x40000} \
    --add-section .linux="$MY_TMPDIR"/linux --change-section-vma .linux=0x2000000 \
    --add-section .initrd="$MY_TMPDIR"/initrd --change-section-vma .initrd=0x3000000 \
    "${BASEDIR}"/linuxx64.efi.stub "$MY_TMPDIR"/bootx64.efi


mkdir -p "$OUTDIR"
mv "$MY_TMPDIR"/root-hash.txt \
   "$MY_TMPDIR"/bootx64.efi \
   "$MY_TMPDIR"/root.img \
   "$MY_TMPDIR"/release.txt \
   "$MY_TMPDIR"/options.txt \
   "$MY_TMPDIR"/linux \
   "$MY_TMPDIR"/initrd \
   "$OUTDIR"

[[ -d "$MY_TMPDIR"/efi ]] && mv "$MY_TMPDIR"/efi "$OUTDIR"/efi

for i in LockDown.efi Shell.efi startup.nsh; do
    [[ -e "${BASEDIR}"/$i ]] || continue
    cp "$i" "$OUTDIR"/efi
done

chown -R "$USER" "$OUTDIR"

cat > "${BASEOUTDIR}/${NAME}-latest.json" <<EOF
{
        "roothash": "$ROOT_HASH",
        "rootsize": "$ROOT_SIZE",
        "name"    : "${NAME}",
        "version" : "${VERSION_ID}"
}
EOF

chown "$USER" "${BASEOUTDIR}/${NAME}-latest.json"
setenforce $OLD_SELINUX
