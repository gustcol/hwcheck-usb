#!/usr/bin/env bash
# Create the expected-specs file for a machine, without rebuilding the image.
#
#   tools/hwcheck-profile.sh                       ask the questions, write ./hwcheck.conf
#   tools/hwcheck-profile.sh --to-usb              ...and copy it to the stick labeled HWREPORT
#   tools/hwcheck-profile.sh --cpu i7-12700K --cores 12 --threads 20 --ram 32 \
#       --gpu "RTX 3080" --vram 10 --disk 1 --out ~/hwcheck.conf      (no questions)
#   tools/hwcheck-profile.sh --builtin my-pc       write profiles/my-pc.conf for a rebuild
#   tools/hwcheck-profile.sh --check FILE          check an existing hwcheck.conf
#
# Options:
#   --name TEXT       title shown on the result screen
#   --cpu TEXT        part of the CPU name, e.g. "i9-10980XE" or "Ryzen 9 5950X"
#   --cores N         physical cores          --threads N   threads
#   --avx512 yes|no   whether the CPU must have AVX-512
#   --ram GB          installed RAM
#   --gpu TEXT        part of the NVIDIA GPU name, e.g. "RTX 6000"
#   --vram GB         GPU memory               --no-gpu      no NVIDIA GPU expected
#   --disk TB         total disk space, e.g. 2.5
#   --out FILE        where to write (default ./hwcheck.conf)
#   --to-usb          also copy the file to a mounted stick labeled HWREPORT
#
# Anything left empty is not checked. Put the file at the top level of any
# USB stick (FAT32, exFAT or NTFS) and plug it in together with the test stick:
# QUICK and FULL then use it instead of the built-in specs.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

name="" cpu="" cores="" threads="" avx512="" ram="" gpu="" vram="" disk=""
no_gpu=0 out=./hwcheck.conf to_usb=0 builtin="" check="" interactive=1

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

need() { [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 1; }; }

while [ $# -gt 0 ]; do
    case $1 in
    --name) need "$@"; name=$2; interactive=0; shift ;;
    --cpu) need "$@"; cpu=$2; interactive=0; shift ;;
    --cores) need "$@"; cores=$2; interactive=0; shift ;;
    --threads) need "$@"; threads=$2; interactive=0; shift ;;
    --avx512) need "$@"; avx512=$2; interactive=0; shift ;;
    --ram) need "$@"; ram=$2; interactive=0; shift ;;
    --gpu) need "$@"; gpu=$2; interactive=0; shift ;;
    --vram) need "$@"; vram=$2; interactive=0; shift ;;
    --no-gpu) no_gpu=1; interactive=0 ;;
    --disk) need "$@"; disk=$2; interactive=0; shift ;;
    --out) need "$@"; out=$2; shift ;;
    --to-usb) to_usb=1 ;;
    --builtin) need "$@"; builtin=$2; shift ;;
    --check) need "$@"; check=$2; shift ;;
    -h | --help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

is_int() { case ${1-} in '' | *[!0-9]*) return 1 ;; esac; }
is_num() { printf '%s' "${1-}" | grep -Eq '^[0-9]+([.,][0-9]+)?$'; }

# Validate a file with the same parser the stick uses. Only called for
# --check, which exits right after, so loading the stick's helpers is fine.
check_file() {
    local f=$1 w
    [ -r "$f" ] || { echo "can't read $f" >&2; exit 1; }
    set +e
    RUN_DIR=$(mktemp -d)
    export RUN_DIR
    # shellcheck source=src/lib/common.sh
    . "$ROOT/src/lib/common.sh"
    # shellcheck source=src/lib/profile.sh
    . "$ROOT/src/lib/profile.sh"
    profile_reset
    PROFILE_WARNINGS=()
    profile_apply_file "$f"
    rm -rf "$RUN_DIR"
    echo "The stick will expect:"
    echo "  Title:      $SPEC_NAME"
    echo "  CPU model:  $(unescape "${CPU_MODEL_REGEX:-not checked}")"
    echo "  CPU cores:  $CPU_CORES / threads $CPU_THREADS (0 = not checked)"
    echo "  CPU flags:  ${CPU_FLAGS_REQUIRED:-not checked}"
    if [ "$RAM_GB" -gt 0 ]; then echo "  RAM:        $RAM_GB GB"; else echo "  RAM:        not checked"; fi
    if [ "$GPU_REQUIRED" = 1 ]; then
        echo "  GPU:        $(unescape "${GPU_MODEL_REGEX:-any NVIDIA}"), at least $GPU_VRAM_MIB_MIN MiB"
    else
        echo "  GPU:        not required (tested if present)"
    fi
    if [ "$DISK_TOTAL_GB_MIN" -gt 0 ]; then
        echo "  Disks:      at least $DISK_TOTAL_GB_MIN GB in total"
    else
        echo "  Disks:      not checked"
    fi
    if [ "${#PROFILE_WARNINGS[@]}" -gt 0 ]; then
        echo "Problems:"
        for w in "${PROFILE_WARNINGS[@]}"; do echo "  - $w"; done
        return 1
    fi
    echo "No problems found."
}

unescape() { printf '%s' "$1" | sed 's/\\\(.\)/\1/g'; }

if [ -n "$check" ]; then
    check_file "$check"
    exit $?
fi

if [ -n "$builtin" ]; then
    case $builtin in *[!a-z0-9-]* | "") echo "--builtin NAME: lowercase letters, digits and dashes only" >&2; exit 1 ;; esac
    case $builtin in target | auto | ask | usb) echo "'$builtin' is reserved, pick another name" >&2; exit 1 ;; esac
    [ -e "$ROOT/profiles/$builtin.conf" ] && { echo "profiles/$builtin.conf already exists, not overwriting" >&2; exit 1; }
fi

# ask VAR "question" "example": Enter leaves it empty (not checked)
ask() {
    local ans
    printf '%s\n  (e.g. %s, Enter to skip): ' "$2" "$3"
    IFS= read -r ans || ans=""
    printf -v "$1" '%s' "$ans"
}

ask_valid() {
    local var=$1 q=$2 ex=$3 kind=$4 v
    while :; do
        ask v "$q" "$ex"
        v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ -z "$v" ]; then break; fi
        case $kind in
        int) is_int "$v" && break ;;
        num) is_num "$v" && break ;;
        yn) case $v in [yYnN]*) break ;; esac ;;
        *) break ;;
        esac
        echo "  That doesn't look right, try again."
    done
    printf -v "$var" '%s' "$v"
}

if [ "$interactive" = 1 ]; then
    echo "Answer with what the machine is advertised with. Press Enter to skip a check."
    echo
    ask_valid cpu "CPU model (part of the name)" "i9-10980XE" text
    ask_valid cores "CPU physical cores" "18" int
    ask_valid threads "CPU threads" "36" int
    ask_valid avx512 "Must the CPU have AVX-512? (y/n)" "y for Intel X299/Xeon" yn
    ask_valid ram "Installed RAM in GB" "128" int
    ask_valid gpu "NVIDIA GPU model (part of the name, or 'none')" "Quadro RTX 6000" text
    if [ "$gpu" = none ]; then
        gpu="" no_gpu=1
    elif [ -n "$gpu" ]; then
        ask_valid vram "GPU memory in GB" "24" int
    fi
    ask_valid disk "Total disk space in TB" "2.5" num
    ask_valid name "Title for the result screen" "Workstation for sale" text
    echo
fi

for pair in "cores:$cores" "threads:$threads" "ram:$ram" "vram:$vram"; do
    v=${pair#*:}
    [ -z "$v" ] || is_int "$v" || { echo "--${pair%%:*} must be a whole number, got '$v'" >&2; exit 1; }
done
# Strip leading zeros ("08" would be read as octal later)
[ -n "$cores" ] && cores=$((10#$cores))
[ -n "$threads" ] && threads=$((10#$threads))
[ -n "$ram" ] && ram=$((10#$ram))
[ -n "$vram" ] && vram=$((10#$vram))
[ -z "$disk" ] || is_num "$disk" || { echo "--disk must be a number like 2.5, got '$disk'" >&2; exit 1; }
case $avx512 in "" | [yYnN]*) ;; *) echo "--avx512 takes yes or no" >&2; exit 1 ;; esac
for t in "$name" "$cpu" "$gpu"; do
    case $t in *[[:cntrl:]]*) echo "names can't contain control characters" >&2; exit 1 ;; esac
done

if [ -z "$name" ]; then
    add() { [ -n "$1" ] && name="${name:+$name / }$1"; return 0; }
    add "$gpu${vram:+ ${vram}GB}"
    c=$cpu
    [ -n "$cores" ] && c="${c:+$c }${cores}C/${threads:-?}T"
    add "$c"
    add "${ram:+${ram}GB RAM}"
    add "${disk:+${disk}TB storage}"
    [ -n "$name" ] || name="Custom specs"
fi

flags=""
case $avx512 in [yY]*) flags="avx2 avx512f" ;; [nN]*) flags="avx2" ;; esac

write_conf() {
    {
        echo "# Expected hardware for hwcheck. Put this file at the top level of a"
        echo "# USB stick and plug it in with the test stick. Empty values are not checked."
        echo "SPEC_NAME=$name"
        echo "CPU_MODEL=$cpu"
        echo "CPU_CORES=$cores"
        echo "CPU_THREADS=$threads"
        echo "CPU_FLAGS_REQUIRED=$flags"
        echo "RAM_GB=$ram"
        if [ "$no_gpu" = 1 ]; then
            echo "GPU_REQUIRED=0"
        else
            echo "GPU_MODEL=$gpu"
            echo "GPU_VRAM_GB=$vram"
        fi
        echo "DISK_TOTAL_TB=$disk"
    } | grep -vE '^[A-Z_]+=$'
}

# Literal text -> pattern for a built-in profile
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$?+(){}|/]/\\&/g'; }

if [ -n "$builtin" ]; then
    f=$ROOT/profiles/$builtin.conf
    vram_mib=0
    [ -n "$vram" ] && vram_mib=$(awk -v g="$vram" 'BEGIN { printf "%d", g * 1024 * 0.94 }')
    disk_gb=0
    [ -n "$disk" ] && disk_gb=$(awk -v t="${disk/,/.}" 'BEGIN { printf "%d", t * 1000 * 0.96 }')
    gpu_req=0
    [ "$no_gpu" = 0 ] && { [ -n "$gpu" ] || [ -n "$vram" ]; } && gpu_req=1
    {
        echo "# shellcheck shell=bash disable=SC2034"
        echo "# Built-in profile, boot it with hwcheck.profile=$builtin. Values set to 0 are not checked."
        printf 'SPEC_NAME=%q\n\n' "$name"
        printf 'CPU_MODEL_REGEX=%q\n' "$(re_escape "$cpu")"
        echo "CPU_CORES=${cores:-0}"
        echo "CPU_THREADS=${threads:-0}"
        printf 'CPU_FLAGS_REQUIRED=%q\n' "$flags"
        echo "CPU_TEMP_WARN_C=95"
        echo
        echo "RAM_GB=${ram:-0}"
        echo
        echo "GPU_REQUIRED=$gpu_req"
        printf 'GPU_MODEL_REGEX=%q\n' "$(re_escape "$gpu")"
        echo "GPU_VRAM_MIB_MIN=$vram_mib"
        echo "GPU_TEMP_WARN_C=88"
        echo "GPU_PCIE_WIDTH_MIN=16"
        echo
        echo "DISK_TOTAL_GB_MIN=$disk_gb"
    } >"$f"
    echo "Wrote $f"
    echo "Add a boot menu entry with hwcheck.profile=$builtin if you want one, then run ./build.sh."
    exit 0
fi

write_conf >"$out"
echo "Wrote $out:"
sed 's/^/    /' "$out"
echo
"$BASH" "$0" --check "$out" >/dev/null || { echo "The file has problems:"; "$BASH" "$0" --check "$out" || true; exit 1; }

if [ "$to_usb" = 1 ]; then
    dest=""
    case $(uname -s) in
    Darwin) [ -d /Volumes/HWREPORT ] && dest=/Volumes/HWREPORT ;;
    *) dest=$(lsblk -lno LABEL,MOUNTPOINT 2>/dev/null | awk '$1 == "HWREPORT" && $2 != "" { print $2; exit }') ;;
    esac
    if [ -z "$dest" ]; then
        echo "No mounted stick labeled HWREPORT found. Copy $out to the top level of any"
        echo "USB stick (FAT32, exFAT or NTFS) by hand; the name must stay hwcheck.conf."
        exit 1
    fi
    cp "$out" "$dest/hwcheck.conf"
    sync
    echo "Copied to $dest/hwcheck.conf. Eject the stick before unplugging it."
else
    echo "Copy it to the top level of any USB stick (FAT32, exFAT or NTFS), keep the"
    echo "name hwcheck.conf, and plug that stick in together with the test stick."
fi
