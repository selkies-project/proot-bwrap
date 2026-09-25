#!/bin/bash
# Builds proot from the source install.sh uses, with the patches this
# repository still carries, and asks a program traced by it for its own name.
# Every released proot answers with its own loader's temp file, which the
# multi-call coreutils of Ubuntu 25.10 and later read to decide which tool
# they are. Both routes to that name are checked: prctl(PR_GET_AUXV), which a
# kernel 6.4 or newer answers, and /proc/self/auxv, which is where an older
# one is read instead.
#
# usage: proot-check.sh [--build DIR] [--proot PROOT]
#
# --proot checks a proot that is already built instead of building one.
set -u

build="${TMPDIR:-/tmp}/proot-check"
proot=""
while [ $# -gt 0 ]; do
    case "$1" in
        --build) build="$2"; shift 2 ;;
        --proot) proot="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
here="$(dirname "$(dirname "$(readlink -f "$0")")")"
proot_tag="$(sed -n 's/^proot_tag="\(.*\)"$/\1/p' "$here/install.sh")"
proot_sha256="$(sed -n 's/^proot_sha256="\(.*\)"$/\1/p' "$here/install.sh")"
fail=0

if [ -z "$proot" ]; then
    for tool in gcc make patch curl tar sha256sum; do
        command -v "$tool" > /dev/null || { echo "missing $tool" >&2; exit 2; }
    done
    rm -rf "$build"
    mkdir -p "$build"
    curl -o "$build/proot.tar.gz" -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
        "https://github.com/termux/proot/archive/refs/tags/${proot_tag}.tar.gz" || exit 2
    echo "${proot_sha256}  $build/proot.tar.gz" | sha256sum -c - || exit 2
    tar -xzf "$build/proot.tar.gz" -C "$build" || exit 2
    cd "$build/proot-${proot_tag#v}" || exit 2
    for file in "$here"/patches/*.patch; do
        [ -e "$file" ] || continue
        if patch -p1 -R --dry-run --silent < "$file" > /dev/null 2>&1; then
            echo "SKIP $(basename "$file"): already upstream"
        elif patch -p1 --silent < "$file"; then
            echo "PASS $(basename "$file"): applies"
        else
            echo "FAIL $(basename "$file"): does not apply"
            fail=$((fail + 1))
        fi
    done
    make -C src -j"$(nproc)" proot GIT=false > "$build/make.log" 2>&1 ||
        { echo "FAIL build: see $build/make.log"; tail -5 "$build/make.log"; exit 1; }
    echo "PASS build: $(stat -c %s src/proot) bytes"
    proot="$build/proot-${proot_tag#v}/src/proot"
fi

# Reads AT_EXECFN by one route only, so each is reported on its own.
read_execfn='
import ctypes, struct, sys
width = struct.calcsize("P")
form = "Q" if width == 8 else "I"
if sys.argv[1] == "prctl":
    buffer = ctypes.create_string_buffer(4096)
    size = ctypes.CDLL(None).prctl(0x41555856, buffer, len(buffer), 0, 0)
    if size <= 0:
        sys.exit("prctl(PR_GET_AUXV) is not answered by this kernel")
    vector = buffer.raw
else:
    with open("/proc/self/auxv", "rb") as handle:
        vector = handle.read()
for start in range(0, len(vector) - 2 * width + 1, 2 * width):
    key, value = struct.unpack(form * 2, vector[start:start + 2 * width])
    if key == 0:
        break
    if key == 31 and value:
        sys.stdout.write(ctypes.string_at(value).decode("utf-8", "replace"))
        break
'
python="$(command -v python3)"
for route in prctl file; do
    name="$("$proot" -r / "$python" -c "$read_execfn" "$route" 2>&1)"
    if [ "$name" = "$python" ]; then
        echo "PASS $route: the program's own name"
    else
        echo "FAIL $route: $name"
        fail=$((fail + 1))
    fi
done

# The applet a multi-call coreutils dispatches by that name, where there is one.
if [ -L /usr/bin/dirname ]; then
    got="$("$proot" -r / /usr/bin/dirname /a/b 2>&1)"
    if [ "$got" = "/a" ]; then
        echo "PASS coreutils: dirname"
    else
        echo "FAIL coreutils: $got"
        fail=$((fail + 1))
    fi
fi

if [ "$fail" = 0 ]; then
    echo "proot-check: all good"
else
    echo "proot-check: $fail failed"
fi
[ "$fail" = 0 ]
