#!/bin/sh

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Installs Steam and proot-bwrap into a Debian-based image or system.
#
# Steam's launcher package comes from Valve's repository, which the package
# itself registers, together with the 32-bit host libraries the 32-bit client
# and games need and the libraries Steam's metapackages only recommend but
# games reach for (Vulkan, EGL, video acceleration, and XKB of both
# architectures). fakechroot is installed for the hosts that deny ptrace, and
# proot -- what runs a program fakechroot cannot be preloaded into -- is built
# here, since the packaged one is from 2018 and one that leaves its own loader
# named in AT_EXECFN breaks every applet of the multi-call coreutils recent
# Ubuntu ships. steamdeps, the client's dependency check, would drive apt
# through pkexec at every start; the system carries what it checks for, so it
# is diverted to a stub that answers that everything is there. proot-bwrap is
# installed beside this script's copy, or downloaded from the repository when
# run alone, and Steam's own launcher is diverted so that every way of
# starting Steam -- the menu entry, a steam:// link, a shell -- names it.
# Without that, Steam's requirements check finds no working bubblewrap and
# refuses to start with "Steam now requires user namespaces to be enabled".
#
# Run as root, or under fakeroot in a rootless image build.

set -eu

prefix="${PREFIX:-/usr/local}"
ref="${PROOT_BWRAP_REF:-main}"
here="$(dirname "$(readlink -f "$0")")"
# The PRoot release built below and its archive's digest: an archive that does
# not match fails the install instead of being built.
proot_tag="v5.1.107.95"
proot_sha256="f76716a9531c25be6f0bf7eb21003f0ebec3f832085a7fc233c3f475e75e4bf5"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export DEBIAN_FRONTEND=noninteractive

apt_install() {
    apt-get install --no-install-recommends -y "$@"
}

command -v curl > /dev/null 2>&1 || { apt-get update && apt_install curl ca-certificates; }

if ! dpkg --print-foreign-architectures | grep -qx i386; then
    dpkg --add-architecture i386
fi

curl -o "${work}/steam-launcher.deb" -fsSL --retry 5 --retry-all-errors --retry-delay 3 --retry-connrefused --retry-max-time 180 \
    "https://repo.steampowered.com/steam/archive/stable/steam_latest.deb"
apt-get update
apt_install "${work}/steam-launcher.deb"
apt-get update
apt_install \
    steam-libs-amd64 \
    steam-libs-i386 \
    libfakechroot \
    libfakechroot:i386 \
    libvulkan1 \
    libvulkan1:i386 \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    libegl1:i386 \
    libgles2:i386 \
    libglx-mesa0:i386 \
    libva2:i386 \
    libva-drm2:i386 \
    libva-x11-2:i386 \
    libxkbcommon-x11-0:i386 \
    libfontconfig1:i386 \
    libxss1:i386 \
    libasound2-plugins:i386 \
    python3

# The fixes proot still lacks are offered upstream; a patch that is already
# there applies in reverse and is skipped.
patches="proot-freestanding-loader proot-own-auxv"
tools=""
for package in gcc libc6-dev make patch libtalloc-dev; do
    dpkg-query -s "${package}:$(dpkg --print-architecture)" > /dev/null 2>&1 ||
        tools="${tools} ${package}"
done
# shellcheck disable=SC2086  # the package list is meant to split
apt_install libtalloc2 ${tools}

curl -o "${work}/proot.tar.gz" -fsSL --retry 5 --retry-all-errors --retry-delay 3 --retry-connrefused --retry-max-time 180 \
    "https://github.com/termux/proot/archive/refs/tags/${proot_tag}.tar.gz"
echo "${proot_sha256}  ${work}/proot.tar.gz" | sha256sum -c -
tar -xzf "${work}/proot.tar.gz" -C "${work}"
srcdir="${work}/proot-${proot_tag#v}"

for name in ${patches}; do
    if [ -f "${here}/patches/${name}.patch" ]; then
        cp "${here}/patches/${name}.patch" "${work}/${name}.patch"
    else
        curl -o "${work}/${name}.patch" -fsSL --retry 5 --retry-delay 3 --retry-connrefused --retry-max-time 180 \
            "https://raw.githubusercontent.com/selkies-project/proot-bwrap/${ref}/patches/${name}.patch"
    fi
    ( cd "${srcdir}" &&
        if ! patch -p1 -R --dry-run --silent < "${work}/${name}.patch" > /dev/null 2>&1; then
            patch -p1 --silent < "${work}/${name}.patch"
        fi )
done

# Best-effort: where proot cannot be built, proot-bwrap runs every container
# under the fakechroot installed above rather than the install failing here.
if make -C "${srcdir}/src" -j"$(nproc)" proot GIT=false; then
    install -m 755 "${srcdir}/src/proot" "${prefix}/bin/proot"
else
    echo "warning: proot did not build, so containers run under fakechroot" >&2
fi
rm -rf "${srcdir}"
# shellcheck disable=SC2086  # likewise
[ -z "${tools}" ] || { apt-get purge -y ${tools} && apt-get autoremove -y --purge; }

if [ ! -e /usr/bin/steamdeps.distrib ]; then
    dpkg-divert --rename --divert /usr/bin/steamdeps.distrib /usr/bin/steamdeps
fi
printf '#!/bin/sh\nexit 0\n' > /usr/bin/steamdeps
chmod 755 /usr/bin/steamdeps

mkdir -p "${prefix}/bin"
if [ -f "${here}/proot-bwrap" ]; then
    install -m 755 "${here}/proot-bwrap" "${prefix}/bin/proot-bwrap"
else
    curl -o "${prefix}/bin/proot-bwrap" -fsSL --retry 5 --retry-delay 3 --retry-connrefused --retry-max-time 180 \
        "https://raw.githubusercontent.com/selkies-project/proot-bwrap/${ref}/proot-bwrap"
    chmod 755 "${prefix}/bin/proot-bwrap"
fi

# The launcher is a symbolic link to the client's own script; diverting it
# leaves the package free to update that script, and an already-set BWRAP wins
# so that a session can still choose another one. The client takes its package
# name from the name it was started as and refuses to run under any other, and
# a shell script cannot be given a different one -- the kernel hands the
# interpreter the script's own path -- so the replacement starts it through a
# link that is still called `steam`.
ln -sfn bin_steam.sh /usr/lib/steam/steam
if [ ! -e /usr/bin/steam.distrib ]; then
    dpkg-divert --rename --divert /usr/bin/steam.distrib /usr/bin/steam
fi
cat > /usr/bin/steam <<EOF
#!/bin/sh
# Start Steam with a bubblewrap that works without user namespaces.
BWRAP="\${BWRAP:-${prefix}/bin/proot-bwrap}"
export BWRAP
exec /usr/lib/steam/steam "\$@"
EOF
chmod 755 /usr/bin/steam

apt-get clean
rm -rf /var/lib/apt/lists/*
echo "proot-bwrap installed at ${prefix}/bin/proot-bwrap and wired into /usr/bin/steam"
