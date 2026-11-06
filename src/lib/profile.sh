# shellcheck shell=bash disable=SC2034
# Expected-hardware profiles from outside the image: a hwcheck.conf file on a
# USB stick, or values typed in at boot ("ask" mode).
#
# A hwcheck.conf is never executed. Each line is KEY=VALUE, only the keys
# below are accepted, and each value is checked before it is used. Anything
# a file leaves out is not checked.

PROFILE_FILE_NAME=hwcheck.conf
PROFILE_SOURCE=""
PROFILE_WARNINGS=()

# Plain-text keys are matched as literal text. *_REGEX keys are for experts.
PROFILE_INT_KEYS="CPU_CORES CPU_THREADS CPU_TEMP_WARN_C RAM_GB GPU_REQUIRED GPU_VRAM_MIB_MIN GPU_VRAM_GB GPU_TEMP_WARN_C GPU_PCIE_WIDTH_MIN DISK_TOTAL_GB_MIN"
PROFILE_TEXT_KEYS="SPEC_NAME CPU_MODEL GPU_MODEL CPU_MODEL_REGEX GPU_MODEL_REGEX CPU_FLAGS_REQUIRED DISK_TOTAL_TB"

# Escape a string so it matches literally inside [[ =~ ]]
re_escape() {
    # shellcheck disable=SC2001
    sed 's/[][\.*^$?+(){}|/]/\\&/g' <<<"$1"
}

# A regex bash can compile? ([[ =~ ]] returns 2 for a bad one)
re_valid() {
    local rc
    [ -z "$1" ] && return 0
    { [[ "" =~ $1 ]]; } 2>/dev/null
    rc=$?
    [ "$rc" -ne 2 ]
}

# Settings for "nothing is checked"; files and ask mode start from here.
profile_reset() {
    SPEC_NAME="Any hardware (no spec check)"
    CPU_MODEL_REGEX=""
    CPU_CORES=0
    CPU_THREADS=0
    CPU_FLAGS_REQUIRED=""
    CPU_TEMP_WARN_C=95
    RAM_GB=0
    GPU_REQUIRED=0
    GPU_MODEL_REGEX=""
    GPU_VRAM_MIB_MIN=0
    GPU_TEMP_WARN_C=88
    GPU_PCIE_WIDTH_MIN=16
    DISK_TOTAL_GB_MIN=0
}

profile_warn() {
    PROFILE_WARNINGS+=("$1")
}

# A GPU sold as "24 GB" reports about 24564 MiB; allow a little less.
vram_gb_to_mib() {
    awk -v g="$1" 'BEGIN { printf "%d", g * 1024 * 0.94 }'
}

# "2.5" TB -> minimum GB, allowing for formatting and rounding (96%)
disk_tb_to_gb() {
    awk -v t="$1" 'BEGIN { printf "%d", t * 1000 * 0.96 }'
}

# profile_set KEY VALUE LINE_NO: validate one setting and apply it
profile_set() {
    local key=$1 val=$2 n=$3
    if [[ ! $key =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        profile_warn "line $n: '$key' is not a setting name (ignored)"
        return
    fi
    if [[ " $PROFILE_INT_KEYS " == *" $key "* ]]; then
        if ! is_int "$val"; then
            profile_warn "line $n: $key must be a whole number, got '$val' (ignored)"
            return
        fi
        val=$((10#$val))
    elif [[ " $PROFILE_TEXT_KEYS " == *" $key "* ]]; then
        if [ "${#val}" -gt 120 ] || [[ $val == *[[:cntrl:]]* ]]; then
            profile_warn "line $n: $key is too long or has odd characters (ignored)"
            return
        fi
    else
        profile_warn "line $n: unknown setting '$key' (ignored)"
        return
    fi
    case $key in
    CPU_MODEL) CPU_MODEL_REGEX=$(re_escape "$val") ;;
    GPU_MODEL) GPU_MODEL_REGEX=$(re_escape "$val") ;;
    CPU_MODEL_REGEX | GPU_MODEL_REGEX)
        if ! re_valid "$val"; then
            profile_warn "line $n: $key is not a valid pattern (ignored)"
            return
        fi
        printf -v "$key" '%s' "$val"
        ;;
    CPU_FLAGS_REQUIRED)
        if [[ ! $val =~ ^[a-z0-9_\ ]*$ ]]; then
            profile_warn "line $n: CPU_FLAGS_REQUIRED takes lowercase flag names like 'avx2 avx512f' (ignored)"
            return
        fi
        CPU_FLAGS_REQUIRED=$val
        ;;
    GPU_REQUIRED)
        if [ "$val" -gt 1 ]; then
            profile_warn "line $n: GPU_REQUIRED must be 0 or 1 (ignored)"
            return
        fi
        GPU_REQUIRED=$val
        ;;
    GPU_VRAM_GB) GPU_VRAM_MIB_MIN=$(vram_gb_to_mib "$val") ;;
    DISK_TOTAL_TB)
        if [[ ! $val =~ ^[0-9]+([.,][0-9]+)?$ ]]; then
            profile_warn "line $n: DISK_TOTAL_TB must be a number like 2.5 (ignored)"
            return
        fi
        DISK_TOTAL_GB_MIN=$(disk_tb_to_gb "${val/,/.}")
        ;;
    *) printf -v "$key" '%s' "$val" ;;
    esac
}

# profile_apply_file FILE: read KEY=VALUE lines into the current profile.
# Tolerates Windows line endings, quotes, spaces around "=" and comments.
profile_apply_file() {
    local file=$1 line key val n=0 gpu_req_set=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -gt 500 ]; then
            profile_warn "file has more than 500 lines, the rest was ignored"
            break
        fi
        line=${line%$'\r'}
        [ "$n" = 1 ] && line=${line#$'\xef\xbb\xbf'}
        line=$(trim "$line")
        [ -z "$line" ] && continue
        [[ $line == \#* ]] && continue
        if [[ $line != *=* ]]; then
            profile_warn "line $n: expected KEY=VALUE, got '$line' (ignored)"
            continue
        fi
        key=$(trim "${line%%=*}")
        val=$(trim "${line#*=}")
        key=$(tr '[:lower:]' '[:upper:]' <<<"$key")
        if [[ $val == \"*\" ]] || [[ $val == \'*\' ]]; then
            val=${val:1:${#val}-2}
        fi
        [ "$key" = GPU_REQUIRED ] && gpu_req_set=1
        profile_set "$key" "$val" "$n"
    done <"$file"
    # A GPU model or size in the file means a GPU is expected
    if [ "$gpu_req_set" = 0 ] && { [ -n "$GPU_MODEL_REGEX" ] || [ "${GPU_VRAM_MIB_MIN:-0}" -gt 0 ]; }; then
        GPU_REQUIRED=1
    fi
    return 0
}

# profile_in_dir DIR -> path of hwcheck.conf (or hwcheck.conf.txt, which is
# what Windows makes when extensions are hidden) at the top of DIR. Files over
# 64 KB are not specs files and are skipped.
profile_in_dir() {
    local f
    for f in "$PROFILE_FILE_NAME" "$PROFILE_FILE_NAME.txt"; do
        f=$(find "$1" -maxdepth 1 -iname "$f" -type f -size -64k 2>/dev/null | head -1)
        [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# find_usb_profile -> copies the first hwcheck.conf found at the root of a USB
# partition to $RUN_DIR and prints "COPY<TAB>DEVICE". Partitions are mounted
# read-only and unmounted again.
find_usb_profile() {
    local mnt=$RUN_DIR/cfgmnt dev fstype f found=""
    mkdir -p "$mnt"
    while read -r dev fstype; do
        case $fstype in vfat | exfat | ntfs | ntfs3) ;; *) continue ;; esac
        # Already mounted (for example by hwcheck-save): read it in place
        local where
        where=$(findmnt -nro TARGET --source "$dev" 2>/dev/null | head -1)
        if [ -n "$where" ]; then
            f=$(profile_in_dir "$where")
            [ -n "$f" ] && cp "$f" "$RUN_DIR/usb-profile.conf" && found=$dev
        elif mount -o ro,nodev,nosuid,noexec "$dev" "$mnt" 2>/dev/null; then
            f=$(profile_in_dir "$mnt")
            [ -n "$f" ] && cp "$f" "$RUN_DIR/usb-profile.conf" && found=$dev
            umount "$mnt" 2>/dev/null
        fi
        [ -n "$found" ] && break
    done < <(usb_partitions)
    rmdir "$mnt" 2>/dev/null
    [ -n "$found" ] || return 1
    printf '%s\t%s\n' "$RUN_DIR/usb-profile.conf" "$found"
}

# usb_partitions -> "DEVICE FSTYPE" for every filesystem on a USB disk
usb_partitions() {
    lsblk -J -p -o NAME,FSTYPE,TRAN,TYPE 2>/dev/null | jq -r '
        .blockdevices[] | select(.tran == "usb")
        | (., (.children // [])[]) | select(.fstype != null)
        | "\(.name) \(.fstype)"'
}

# gpu_name_hint -> the NVIDIA GPU name as nvidia-smi reports it (what the
# GPU check compares against). Falls back to a cleaned-up lspci name.
gpu_name_hint() {
    local n
    lspci -d 10de: 2>/dev/null | grep -qEi 'VGA|3D|Display' || return 0
    modprobe nvidia 2>/dev/null || true
    n=$(timeout 15 nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    n=$(trim "${n#NVIDIA }")
    if [ -z "$n" ]; then
        # pci.ids names look like "TU102GL [Quadro RTX 6000/8000]"
        n=$(lspci -d 10de: 2>/dev/null | grep -Ei 'VGA|3D|Display' | head -1 | sed -n 's/.*\[\(.*\)\].*/\1/p')
        n=${n%%/*}
        n=${n% Mobile}
        n=${n% Max-Q}
    fi
    printf '%s\n' "$n"
}

# ask VAR PROMPT DEFAULT: read one answer, Enter keeps the default
ask() {
    local __var=$1 prompt=$2 def=$3 ans
    printf '  %s [%s]: ' "$prompt" "${def:-not checked}"
    IFS= read -r ans </dev/tty || ans=""
    ans=$(trim "$ans")
    [ -z "$ans" ] && ans=$def
    [ "$ans" = "-" ] && ans=""
    printf -v "$__var" '%s' "$ans"
}

# ask_int VAR PROMPT DEFAULT: like ask, but repeats until it gets a number
ask_int() {
    local __var=$1 prompt=$2 def=$3 v
    while :; do
        ask v "$prompt" "$def"
        if [ -z "$v" ] || is_int "$v"; then
            printf -v "$__var" '%s' "${v:-0}"
            return
        fi
        printf '  %sPlease type a whole number, Enter for the suggestion, or - to skip.%s\n' "$C_YEL" "$C_0"
    done
}

# ask_profile: show what was detected and let the operator type the expected
# values (usually from the sales listing). Enter accepts the suggestion,
# "-" means "don't check this".
ask_profile() {
    local cpu cores threads ram_gb gpu vram_gb disk_gb avx512 yn tb
    cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
    read -r _ cores threads < <(lscpu -p=SOCKET,CORE,CPU | count_cpu_topology)
    ram_gb=$(dmidecode -t 17 2>/dev/null | parse_dimms | awk -F'|' '{ s += $1 } END { printf "%d", s / 1024 }')
    [ "${ram_gb:-0}" -gt 0 ] || ram_gb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
    gpu=$(gpu_name_hint)
    disk_gb=0
    local entry size
    for entry in "${TEST_DISKS[@]}"; do
        IFS=$'\t' read -r _ size _ <<<"$entry"
        disk_gb=$((disk_gb + size / 1000000000))
    done
    tb=$(awk -v g="$disk_gb" 'BEGIN { printf "%.2f", g / 1000 }')
    local tb_default=$tb
    grep -qw avx512f /proc/cpuinfo && avx512=y || avx512=n

    profile_reset
    clear 2>/dev/null || true
    printf '\n%sType the specs the machine is sold with.%s\n' "$C_B" "$C_0"
    printf '  Each line suggests what this machine reports. Press Enter to accept it,\n'
    printf '  type the advertised value instead, or type - to skip that check.\n\n'

    ask CPU_MODEL_TXT "CPU model (part of the name, e.g. i9-10980XE)" "$cpu"
    [ -n "$CPU_MODEL_TXT" ] && CPU_MODEL_REGEX=$(re_escape "$CPU_MODEL_TXT")
    ask_int CPU_CORES "CPU physical cores" "$cores"
    ask_int CPU_THREADS "CPU threads" "$threads"
    ask yn "Must the CPU have AVX-512? (y/n)" "$avx512"
    case $yn in [yY]*) CPU_FLAGS_REQUIRED="avx2 avx512f" ;; [nN]*) CPU_FLAGS_REQUIRED="avx2" ;; *) CPU_FLAGS_REQUIRED="" ;; esac
    ask_int RAM_GB "Installed RAM in GB" "$ram_gb"
    if [ -n "$gpu" ]; then
        ask GPU_MODEL_TXT "NVIDIA GPU model (part of the name)" "$gpu"
        if [ -n "$GPU_MODEL_TXT" ]; then
            GPU_REQUIRED=1
            GPU_MODEL_REGEX=$(re_escape "$GPU_MODEL_TXT")
            ask_int vram_gb "GPU memory in GB (e.g. 24)" ""
            [ "$vram_gb" -gt 0 ] && GPU_VRAM_MIB_MIN=$(vram_gb_to_mib "$vram_gb")
        fi
    else
        ask yn "No NVIDIA GPU found. Should there be one? (y/n)" "n"
        case $yn in [yY]*) GPU_REQUIRED=1 ;; esac
    fi
    ask tb "Total disk space in TB (e.g. 2.5)" "$tb"
    if [ "$tb" = "$tb_default" ] && [ "$disk_gb" -gt 0 ]; then
        # Accepted the suggestion: allow for rounding of what was measured
        DISK_TOTAL_GB_MIN=$((disk_gb * 96 / 100))
    elif [[ $tb =~ ^[0-9]+([.,][0-9]+)?$ ]] && fgt "${tb/,/.}" 0; then
        DISK_TOTAL_GB_MIN=$(disk_tb_to_gb "${tb/,/.}")
    fi

    local parts=() p
    if [ -n "${GPU_MODEL_TXT-}" ]; then
        p=$GPU_MODEL_TXT
        [ "${vram_gb:-0}" -gt 0 ] && p+=" ${vram_gb}GB"
        parts+=("$p")
    fi
    p=${CPU_MODEL_TXT-}
    [ "$CPU_CORES" -gt 0 ] && p+=" ${CPU_CORES}C/${CPU_THREADS}T"
    p=$(trim "$p")
    [ -n "$p" ] && parts+=("$p")
    [ "$RAM_GB" -gt 0 ] && parts+=("${RAM_GB}GB RAM")
    [ "$DISK_TOTAL_GB_MIN" -gt 0 ] && parts+=("${tb}TB storage")
    SPEC_NAME="Typed in at boot"
    if [ "${#parts[@]}" -gt 0 ]; then
        SPEC_NAME+=": ${parts[0]}"
        for p in "${parts[@]:1}"; do SPEC_NAME+=" / $p"; done
    fi
    printf '\n  Using: %s\n  Starting the tests in 5 seconds...\n' "$SPEC_NAME"
    sleep 5
}

# profile_write FILE: save the current profile as a hwcheck.conf
profile_write() {
    {
        echo "# hwcheck expected hardware (written $(date '+%F %T'))"
        printf 'SPEC_NAME=%s\n' "$SPEC_NAME"
        printf 'CPU_MODEL_REGEX=%s\n' "$CPU_MODEL_REGEX"
        printf 'CPU_CORES=%s\nCPU_THREADS=%s\n' "$CPU_CORES" "$CPU_THREADS"
        printf 'CPU_FLAGS_REQUIRED=%s\n' "$CPU_FLAGS_REQUIRED"
        printf 'RAM_GB=%s\n' "$RAM_GB"
        printf 'GPU_REQUIRED=%s\n' "$GPU_REQUIRED"
        printf 'GPU_MODEL_REGEX=%s\n' "$GPU_MODEL_REGEX"
        printf 'GPU_VRAM_MIB_MIN=%s\n' "$GPU_VRAM_MIB_MIN"
        printf 'DISK_TOTAL_GB_MIN=%s\n' "$DISK_TOTAL_GB_MIN"
    } >"$1"
}
