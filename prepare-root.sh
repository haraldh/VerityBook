#!/bin/bash -ex

export LANG=C

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

Creates a directory with a readonly root on squashfs, a dm_verity file and an EFI executable

  --help             Display this help
  --pkglist FILE     The packages to install read from FILE (default: pkglist.txt)
  --excludelist FILE The packages to install read from FILE (default: excludelist.txt)
  --releasever NUM   Used Fedora release version NUM (default: $VERSION_ID)
  --outname JSON     Creates \$JSON.json symlinked to that release (default: NAME-NUM-DATE)
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
        --long help \
        --long pkglist: \
        --long excludelist: \
        --long outname: \
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
        '--outname')
            OUTNAME="$2"
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
        '--help')
	        usage
	        exit 0
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

NAME=${NAME:-"FedoraBook"}
RELEASEVER=${RELEASEVER:-$VERSION_ID}
BASEOUTDIR=$(realpath ${BASEOUTDIR:-"$CURDIR"})
CRT=${CRT:-${NAME}.crt}
REPOSD=${REPOSD:-/etc/yum.repos.d}
STATEDIR=${STATEDIR:-"${BASEDIR}/${NAME}"}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date -u +'%s')}

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
    for i in "$sysroot"/{dev,sys,proc,run,var/lib/rpm,var/cache/dnf}; do
       [[ -d "$i" ]] && mountpoint -q "$i" && umount "$i"
    done
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    (( $ret != 0 )) && [[ "$OUTNAME" ]] && rm -rf --one-file-system -- "$OUTNAME"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

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
    DNF_COMMAND="check-update --refresh"
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

set +e
dnf -v \
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
    libfaketime \
    sbsigntools \
    squashfs-tools \
    policycoreutils-python-utils \
    xdelta \
    $PKGLIST

RET=$?
set -e

if [[ $CHECK_UPDATE ]]; then
    exit $RET
fi

(( $RET == 0 ))


chroot "$sysroot" /usr/bin/systemd-sysusers

for i in passwd shadow group gshadow subuid subgid; do
    [[ -e "$sysroot"/etc/${i}.rpmnew ]] || continue
    while read line || [[ $line ]]; do
        IFS=: read user _ <<<$line
        grep -E -q "^$user:" "$sysroot"/etc/${i} && continue
        echo "$line" >> "$sysroot"/etc/${i}
    done <"$sysroot"/etc/${i}.rpmnew
    rm -f "$sysroot"/etc/${i}- "$sysroot"/etc/${i}+
done

find "$sysroot" -name '*.rpmnew' -print0 | xargs -0 rm -fv

# We need to preserve old uid/gid
mkdir -p "${STATEDIR}"
for i in passwd shadow group gshadow subuid subgid; do
    cp "$sysroot"/etc/"$i" "${STATEDIR}"
    if [[ "$SUDO_USER" ]]; then
        chown "$SUDO_USER" "${STATEDIR}/$i"
    else
        chown "$USER" "${STATEDIR}/$i"
    fi
    chmod u+r "${STATEDIR}/$i"
done

if [[ -f "${BASEDIR}/${NAME}.te" ]] || [[ -f "${BASEDIR}/${NAME}.te" ]]; then
    for i in "${BASEDIR}/${NAME}.te" "${BASEDIR}/${NAME}.te"; do
        [[ -f "$i" ]] && cp "$i" "$sysroot"/var/tmp
    done
    chroot "$sysroot" bash -c "
        cd /var/tmp
        make -f  /usr/share/selinux/devel/Makefile
        semodule --noreload -i ${NAME}.pp
    "
fi

chroot "$sysroot" semanage fcontext --noreload -a -e /etc /cfg

cp "$BASEDIR/clonedisk.sh" "$sysroot"/usr/bin/${NAME,,}-clonedisk
cp "$BASEDIR/update.sh" "$sysroot"/usr/bin/${NAME,,}-update
cp "$BASEDIR/mkimage.sh" "$sysroot"/usr/bin/${NAME,,}-mkimage

mkdir -p "$sysroot"/etc/pki/${NAME}
openssl x509 -in "${BASEDIR}/${CRT}" -pubkey -noout > "$sysroot"/etc/pki/${NAME}/pubkey
cp "${BASEDIR}/${CRT}" "$sysroot"/etc/pki/${NAME}/crt

rpm --root "$sysroot" -qa | sort > "$sysroot"/usr/rpm-list.txt

cp -avr "${BASEDIR}"/{10verity,20fedorabook} "$sysroot"/usr/lib/dracut/modules.d/

KVER=$(cd "$sysroot"/lib/modules/; ls -1d ??* | tail -1)

sed -ie 's#\(tpm2_[^ ]*\) #\1 -T device:${TPM2TOOLS_DEVICE_FILE[0]} #g' "$sysroot"/usr/bin/clevis-*-tpm2

#---------------
# rngd
ln -fsnr "$sysroot"/usr/lib/systemd/system/rngd.service "$sysroot"/usr/lib/systemd/system/basic.target.wants/rngd.service

if [[ $NO_SCRIPTS ]]; then
    chroot  "$sysroot" depmod -a $KVER
fi

# FIXME: make dracut modules
chroot  "$sysroot" \
	dracut -N --kver $KVER --force \
	--filesystems "squashfs vfat xfs" \
	-m "bash systemd systemd-initrd modsign crypt dm kernel-modules qemu rootfs-block" \
	-m "udev-rules dracut-systemd base fs-lib shutdown terminfo resume verity fedorabook" \
	--reproducible \
	/lib/modules/$KVER/initrd

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

#chroot "$sysroot" bash -c '
#    setfiles -v -F \
#        /etc/selinux/targeted/contexts/files/file_contexts /usr/bin/passwd /etc/shadow /etc/passwd
#    echo -n admin | passwd --stdin root
#    '

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
    && >/etc/shadow \
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
# cups
if [[ -d "$sysroot"/etc/cups ]]; then
    mv "$sysroot"/etc/cups "$sysroot"/usr/share/factory/cfg/cups
    ln -sfnr "$sysroot"/cfg/cups "$sysroot"/etc/cups
    cat >> "$sysroot"/usr/lib/tmpfiles.d/cups.conf <<EOF
C /cfg/cups - - - - -
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
    # FIXME: reproducible UUID
    sed -i -e 's#<uuid>.*</uuid>#<uuid>6d4d7be7-2190-4d94-be06-07d1b4f45295</uuid>#' \
        "$sysroot"/etc/libvirt/qemu/networks/default.xml
    mv "$sysroot"/etc/libvirt "$sysroot"/usr/share/factory/cfg/
    ln -fsnr "$sysroot"/cfg/libvirt "$sysroot"/etc/libvirt
    cat >> "$sysroot"/usr/lib/tmpfiles.d/libvirt.conf <<EOF
C /cfg/libvirt - - - - -
EOF
fi

#---------------
# usr/local
mkdir -p "$sysroot"/usr/share/factory/usr/
mv "$sysroot"/usr/local "$sysroot"/usr/share/factory/usr/local
mkdir -p "$sysroot"/usr/local
cat >> "$sysroot"/usr/lib/tmpfiles.d/usrlocal.conf <<EOF
C /usr/local/bin - - - - -
C /usr/local/etc - - - - -
C /usr/local/games - - - - -
C /usr/local/include - - - - -
C /usr/local/lib - - - - -
C /usr/local/lib64 - - - - -
C /usr/local/libexec - - - - -
C /usr/local/sbin - - - - -
C /usr/local/share - - - - -
C /usr/local/src - - - - -
EOF

#---------------
# brlapi
# FIXME: reproducible
echo 80e770bbff7c881ab84284f58384b0a7 > "$sysroot"/etc/brlapi.key

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
# hwdb
chroot "$sysroot" /usr/bin/systemd-hwdb update

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
# iscsi
rm -fr "$sysroot"/etc/iscsi

#---------------
# FIXME: reproducible sgml catalogs
for i in "$sysroot"/etc/sgml/catalog "$sysroot"/etc/sgml/*.cat; do
    sort "$i" > "${i}.sorted" && mv "${i}.sorted" "$i"
done

#---------------
# FIXME: reproducible font uuids
for i in "$sysroot"/usr/share/fonts/*; do
    [[ -d $i ]] || continue
    cat "$i"/* \
        | sha256sum \
        | { read h _ ; echo ${h:32:8}-${h:40:4}-${h:44:4}-${h:48:4}-${h:52:12}; } \
        > "$i"/.uuid
done
if [[ "$sysroot"/usr/share/fonts/*/.uuid != "$sysroot"/usr/share/fonts/\*/.uuid ]]; then
    cat "$sysroot"/usr/share/fonts/*/.uuid \
        | sha256sum \
        | { read h _ ; echo ${h:32:8}-${h:40:4}-${h:44:4}-${h:48:4}-${h:52:12}; } \
        > "$sysroot"/usr/share/fonts/.uuid
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

#---------------
# tweak fwupd to not need the shim
if [[ -f "$sysroot"/etc/fwupd/uefi.conf ]]; then
    sed -i -e 's#RequireShimForSecureBoot=.*#RequireShimForSecureBoot=false#g' \
        "$sysroot"/etc/fwupd/uefi.conf
fi

#---------------
# Disable dbxtool
if [[ -f "$sysroot"/usr/lib/systemd/system/dbxtool.service ]]; then
    systemctl --root="$sysroot" disable dbxtool
fi

#---------------
# Tweak auditd.service
if [[ -f "$sysroot"/usr/lib/systemd/system/auditd.service ]]; then
    sed -i -e 's%^ExecStartPost=-/sbin/augenrules%#ExecStartPost=-/sbin/augenrules%' \
        -e 's%^#ExecStartPost=-/sbin/auditctl%ExecStartPost=-/sbin/auditctl%' \
        "$sysroot"/usr/lib/systemd/system/auditd.service
    chroot "$sysroot" augenrules
fi

#---------------
# remove the shim
for i in /boot/efi/EFI/BOOT/BOOTX64.EFI \
    /boot/efi/EFI/BOOT/fbx64.efi \
    /boot/efi/EFI/fedora/BOOTX64.CSV \
    /boot/efi/EFI/fedora/mmx64.efi \
    /boot/efi/EFI/fedora/shimx64-fedora.efi \
    /boot/efi/EFI/fedora/shimx64.efi \
    /boot/efi/EFI/fedora/shim.efi \
    ; do
    rm -f "$sysroot/$i"
done

#---------------
# CA
# FIXME: reproducible java keystores
chroot "$sysroot" bash -x -c '
    export FAKETIME="$(date -u +"%Y-%m-%d %H:%M:%S" --date @${SOURCE_DATE_EPOCH})"
    export LD_PRELOAD=/usr/lib64/faketime/libfaketime.so.1
    update-ca-trust
'

#--------------------------------------
# remove packages only needed for build
dnf -v \
    --installroot "$sysroot"/ \
    --releasever "$RELEASEVER" \
    --setopt=keepcache=True \
    --setopt=reposdir="$REPOSD" \
    --exclude="dnf $PKGLIST" \
    remove -y \
    libfaketime \
    selinux-policy-devel

#---------------
# cleanup var
rm -fr "$sysroot"/var/lib/selinux
rm -fr "$sysroot"//usr/lib/fontconfig/cache
[[ -d "$STATEDIR"/rpm ]] && rm -fr "$STATEDIR"/rpm
mv "$sysroot"/var/lib/rpm "$STATEDIR"/
rm -fr "$sysroot"/var/lib/sepolgen
rm -fr "$sysroot"/var/lib/dnf
rm -fr "$sysroot"/var/lib/flatpak/repo/tmp
rm -fr "$sysroot"/var/log/dnf*
rm -fr "$sysroot"/var/log/hawkey*
rm -fr "$sysroot"/var/cache/*/*
rm -fr "$sysroot"/var/tmp/*

#----------------
# create tmpfiles
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

#---------------
# EFI
if [[ -d "$sysroot"/boot/efi/EFI/fedora ]]; then
    mkdir -p "$sysroot"/efi/EFI
    mv "$sysroot"/boot/efi/EFI/fedora "$sysroot"/efi/EFI
fi
mkdir -p "$sysroot"/efi/EFI/${NAME}
for i in LockDown.efi Shell.efi startup.nsh; do
    [[ -e "${BASEDIR}"/$i ]] || continue
    cp "${BASEDIR}"/$i "$sysroot"/efi/EFI/${NAME}/
done

find "$sysroot"/efi -xdev -newermt "@${SOURCE_DATE_EPOCH}" -print0 \
    | xargs --verbose -0 touch -h --date "@${SOURCE_DATE_EPOCH}"

mv "$sysroot"/efi "$sysroot"/usr/efi

#---------------
# cleanup
rm -fr "$sysroot"/{boot,root}
ln -sfnr "$sysroot"/var/roothome "$sysroot"/root
rm -fr "$sysroot"/var
rm -fr "$sysroot"/home
rm -f "$sysroot"/etc/yum.repos.d/*
mkdir -p "$sysroot"/{var,home,cfg,net,efi}

# ------------------------------------------------------------------------------
# SELinux relabel all the files

#sed -i -e 's#SELINUX=enforcing#SELINUX=permissive#g' "$sysroot"/etc/selinux/config

chroot "$sysroot" setfiles -v -F \
    /etc/selinux/targeted/contexts/files/file_contexts /

# ------------------------------------------------------------------------------
# umount everything
for i in "$sysroot"/{dev,sys,proc,run}; do
    [[ -d "$i" ]] && mountpoint -q "$i" && umount "$i"
done

# ------------------------------------------------------------------------------
# squashfs
# FIXME: for reproducible squashfs builds honoring $SOURCE_DATE_EPOCH use
# https://github.com/squashfskit/squashfskit
if [[ -x "${BASEDIR}/squashfskit/squashfs-tools/mksquashfs" ]]; then
    MKSQUASHFS="${BASEDIR}/squashfskit/squashfs-tools/mksquashfs"
#    cp "$MKSQUASHFS" "$sysroot"/usr/sbin/mksquashfs
else
    MKSQUASHFS=mksquashfs
fi

VERSION_ID="${RELEASEVER}.$(date -u +'%Y%m%d%H%M%S' --date @$SOURCE_DATE_EPOCH)"
OUTNAME=${OUTNAME:-"${NAME}-${VERSION_ID}"}
OUTNAME="${BASEOUTDIR}/${OUTNAME}"

if [[ -f "$sysroot"/etc/os-release ]]; then
    sed -i -e "s#VERSION_ID=.*#VERSION_ID=$VERSION_ID#" "$sysroot"/etc/os-release
    sed -i -e "s#NAME=.*#NAME=$NAME#" "$sysroot"/etc/os-release
fi

"$MKSQUASHFS" "$MY_TMPDIR"/sysroot "$MY_TMPDIR"/root.squashfs.img

# ------------------------------------------------------------------------------
# verity
ROOT_HASH=$(veritysetup \
    --salt=6665646f7261626f6f6b$(printf '%lx' ${SOURCE_DATE_EPOCH}) \
    --uuid=222722e4-58de-415b-9723-bb5dabe36034 \
    format "$MY_TMPDIR"/root.squashfs.img "$MY_TMPDIR"/root.verity.img \
    |& tail -1 | { read _ _ hash _; echo $hash; } )

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

if ! [[ $EFISTUB ]]; then
    if [[ -e "${BASEDIR}"/linuxx64.efi.stub ]]; then
        EFISTUB="${BASEDIR}"/linuxx64.efi.stub
    elif [[ -e "$sysroot"/usr/lib/systemd/boot/efi/linuxx64.efi.stub ]]; then
        EFISTUB="$sysroot"/usr/lib/systemd/boot/efi/linuxx64.efi.stub
    elif [[ -e /lib/systemd/boot/efi/linuxx64.efi.stub ]]; then
        EFISTUB=/lib/systemd/boot/efi/linuxx64.efi.stub
    else
        echo "No EFI stub found" >&2
        exit 1
    fi
fi

mkdir -p "$sysroot"/usr/efi/EFI/${NAME}
objcopy \
    --add-section .release="$MY_TMPDIR"/release.txt --change-section-vma .release=0x20000 \
    --add-section .cmdline="$MY_TMPDIR"/options.txt --change-section-vma .cmdline=0x30000 \
    ${LOGO:+--add-section .splash="$LOGO" --change-section-vma .splash=0x40000} \
    --add-section .linux="$sysroot"/lib/modules/$KVER/vmlinuz --change-section-vma .linux=0x2000000 \
    --add-section .initrd="$sysroot"/lib/modules/$KVER/initrd --change-section-vma .initrd=0x3000000 \
    "${EFISTUB}" "$sysroot"/usr/efi/EFI/${NAME}/bootx64-$ROOT_HASH.efi

tar cf - -C "$sysroot"/usr efi | pigz -c > "${BASEOUTDIR}/${NAME}-${ROOT_HASH}-efi.tgz"
mv "$MY_TMPDIR"/root.img "${BASEOUTDIR}/${NAME}-${ROOT_HASH}.img"

cat > "${OUTNAME}.json" <<EOF
{
        "roothash": "${ROOT_HASH}",
        "imagesize": "${IMAGE_SIZE}",
        "name"    : "${NAME}",
        "version" : "${VERSION_ID}"
}
EOF

ln -sfnr "${OUTNAME}.json" "${BASEOUTDIR}/${NAME}-latest.json"

chown "${SUDO_USER:-$USER}" \
    "${OUTNAME}.json" \
    "${BASEOUTDIR}/${NAME}-${ROOT_HASH}.img" \
    "${BASEOUTDIR}/${NAME}-${ROOT_HASH}-efi.tgz" \
    "${BASEOUTDIR}/${NAME}-latest.json"
