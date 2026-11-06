# shellcheck shell=bash disable=SC2034
# Inventory: compare what is installed against the expected profile.

GPU_COUNT=0
GPU_THROTTLE_PREFIX=clocks_throttle_reasons

secure_boot_state() {
    local f
    f=$(find /sys/firmware/efi/efivars -maxdepth 1 -name "SecureBoot-*" 2>/dev/null | head -1)
    if [ ! -d /sys/firmware/efi ]; then
        echo "legacy BIOS boot"
    elif [ -z "$f" ]; then
        echo "UEFI, Secure Boot unknown"
    elif [ "$(od -An -t u1 -j4 -N1 "$f" | tr -d ' ')" = 1 ]; then
        echo "UEFI, Secure Boot ON"
    else
        echo "UEFI, Secure Boot off"
    fi
}

check_board() {
    local sys board bios
    sys="$(dmidecode -s system-manufacturer 2>/dev/null) $(dmidecode -s system-product-name 2>/dev/null)"
    board="$(dmidecode -s baseboard-manufacturer 2>/dev/null) $(dmidecode -s baseboard-product-name 2>/dev/null)"
    bios="$(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))"
    result System Vendor INFO "$(trim "$sys")"
    result System Motherboard INFO "$(trim "$board")"
    result System BIOS INFO "$(trim "$bios")"
    result System Firmware INFO "$(secure_boot_state)"
}

# prints "SOCKETS CORES THREADS" from `lscpu -p=SOCKET,CORE,CPU` on stdin
count_cpu_topology() {
    awk -F, '
        /^#/ { next }
        { t++
          if (!($1 in s)) { s[$1] = 1; ns++ }
          if (!(($1 "," $2) in c)) { c[$1 "," $2] = 1; nc++ } }
        END { printf "%d %d %d\n", ns, nc, t }'
}

check_cpu() {
    local model sockets cores threads flags f missing="" mhz
    model=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
    if [ -z "${CPU_MODEL_REGEX-}" ] || [ "$CPU_MODEL_REGEX" = . ]; then
        result CPU Model INFO "$model"
    elif [[ $model =~ $CPU_MODEL_REGEX ]]; then
        result CPU Model PASS "$model"
    else
        result CPU Model FAIL "found '$model', expected '$CPU_MODEL_REGEX'"
    fi

    read -r sockets cores threads < <(lscpu -p=SOCKET,CORE,CPU | count_cpu_topology)
    if [ "${CPU_CORES:-0}" -gt 0 ] && [ "$cores" -ne "$CPU_CORES" ]; then
        result CPU Cores FAIL "$cores physical cores, expected $CPU_CORES"
    else
        result CPU Cores PASS "$cores physical cores ($sockets socket)"
    fi
    if [ "${CPU_THREADS:-0}" -gt 0 ] && [ "$threads" -ne "$CPU_THREADS" ]; then
        result CPU Threads FAIL "$threads threads, expected $CPU_THREADS"
    else
        result CPU Threads PASS "$threads threads, $(nproc) online"
    fi

    flags=$(grep -m1 '^flags' /proc/cpuinfo)
    for f in ${CPU_FLAGS_REQUIRED-}; do
        grep -qw -- "$f" <<<"$flags" || missing+=" $f"
    done
    if [ -n "$missing" ]; then
        result CPU Features FAIL "missing:$missing"
    elif [ -n "${CPU_FLAGS_REQUIRED-}" ]; then
        result CPU Features PASS "$CPU_FLAGS_REQUIRED"
    fi

    mhz=$(lscpu | sed -n 's/^CPU max MHz:[[:space:]]*//p' | cut -d. -f1)
    [ -n "$mhz" ] && result CPU "Max clock" INFO "$mhz MHz"
    result CPU Microcode INFO "$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
}

# Parse `dmidecode -t 17` (stdin) into lines: SIZE_MB|LOCATOR|SPEED|CONFIGURED|MAKER|PART
parse_dimms() {
    awk '
        function flush() {
            if (inblk && size > 0) printf "%d|%s|%s|%s|%s|%s\n", size, loc, spd, cspd, man, part
            inblk = 0; size = 0; loc = spd = cspd = man = part = ""
        }
        /^Memory Device/ { flush(); inblk = 1; next }
        /^[^ \t]/ { flush(); next }
        !inblk { next }
        { line = $0; sub(/^[ \t]+/, "", line) }
        line ~ /^Size: [0-9]+ (MB|GB|TB)/ {
            split(line, a, " ")
            size = a[2] * (a[3] == "TB" ? 1048576 : (a[3] == "GB" ? 1024 : 1))
        }
        line ~ /^Locator:/ { loc = substr(line, 10) }
        line ~ /^Speed:/ { spd = substr(line, 8) }
        line ~ /^Configured (Memory|Clock) Speed:/ { sub(/^Configured (Memory|Clock) Speed: /, "", line); cspd = line }
        line ~ /^Manufacturer:/ { man = substr(line, 15) }
        line ~ /^Part Number:/ { part = substr(line, 14); gsub(/ +$/, "", part) }
        END { flush() }'
}

check_ram() {
    local dimms total_mb=0 n=0 size loc spd cspd man part memtotal_kb memtotal_gib min_gib parts
    dimms=$(dmidecode -t 17 2>/dev/null | parse_dimms)
    while IFS='|' read -r size loc spd cspd man part; do
        [ -n "$size" ] || continue
        total_mb=$((total_mb + size))
        n=$((n + 1))
        result RAM "Module $loc" INFO "$((size / 1024)) GB $man $part, $spd (running $cspd)"
    done <<<"$dimms"

    memtotal_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    memtotal_gib=$(awk -v k="$memtotal_kb" 'BEGIN { printf "%.1f", k / 1048576 }')
    min_gib=$(awk -v g="$RAM_GB" 'BEGIN { printf "%.1f", g * 0.93 }')

    if [ "${RAM_GB:-0}" -eq 0 ]; then
        result RAM Installed INFO "$((total_mb / 1024)) GB in $n modules, $memtotal_gib GiB visible to the OS"
    elif [ "$total_mb" -gt 0 ]; then
        if [ "$total_mb" -eq $((RAM_GB * 1024)) ]; then
            result RAM Installed PASS "$((total_mb / 1024)) GB in $n modules"
        else
            result RAM Installed FAIL "$((total_mb / 1024)) GB in $n modules, expected $RAM_GB GB"
        fi
    fi
    if [ "${RAM_GB:-0}" -eq 0 ]; then
        :
    elif fgt "$min_gib" "$memtotal_gib"; then
        result RAM Usable FAIL "$memtotal_gib GiB visible to the OS, expected about $RAM_GB GB"
    else
        result RAM Usable PASS "$memtotal_gib GiB visible to the OS"
    fi
    parts=$(cut -d'|' -f6 <<<"$dimms" | sort -u | grep -c .)
    [ "$parts" -gt 1 ] && result RAM Matching INFO "$parts different part numbers installed"
}

gpu_available() {
    [ "$GPU_COUNT" -gt 0 ]
}

check_gpu() {
    local pci idx name mem bus drv vbios serial genmax widthmax ecc_unc pending
    local matched=0 vram_ok=1
    pci=$(lspci -nn -d 10de: 2>/dev/null | grep -Ei 'VGA|3D|Display')
    if [ -z "$pci" ]; then
        if [ "${GPU_REQUIRED:-1}" = 1 ]; then
            result GPU Detected FAIL "no NVIDIA GPU on the PCI bus"
        else
            result GPU Detected SKIP "no NVIDIA GPU (not required by this profile)"
        fi
        return
    fi
    while read -r line; do
        result GPU "PCI device" INFO "${line#* }"
    done <<<"$pci"

    # The module can still be loading right after boot: retry for ~40 s
    local try
    modprobe nvidia 2>/dev/null || true
    for try in $(seq 1 20); do
        timeout 15 nvidia-smi -L >"$LOG_DIR/nvidia-smi-L.txt" 2>&1 && break
        sleep 2
    done
    if ! timeout 15 nvidia-smi -L >"$LOG_DIR/nvidia-smi-L.txt" 2>&1; then
        dmesg | grep -iE 'nvidia|nvrm' >"$LOG_DIR/dmesg-nvidia.txt" 2>/dev/null
        local hint="see logs/dmesg-nvidia.txt"
        [[ $(secure_boot_state) == *"Secure Boot ON"* ]] && hint="Secure Boot is ON, disable it in the BIOS and reboot"
        result GPU Driver FAIL "NVIDIA driver did not load ($hint)"
        return
    fi
    nvidia-smi -pm 1 >/dev/null 2>&1 || true
    timeout 30 nvidia-smi -q >"$LOG_DIR/nvidia-smi-q.txt" 2>&1 || true
    log "nvidia-smi ready after $try attempt(s)"
    if nvidia-smi --help-query-gpu 2>/dev/null | grep -q 'clocks_event_reasons.hw_slowdown'; then
        GPU_THROTTLE_PREFIX=clocks_event_reasons
    fi

    while IFS=, read -r idx name mem bus drv vbios serial genmax widthmax; do
        name=$(trim "$name"); mem=$(trim "$mem"); bus=$(trim "$bus"); drv=$(trim "$drv")
        vbios=$(trim "$vbios"); serial=$(trim "$serial"); genmax=$(trim "$genmax"); widthmax=$(trim "$widthmax")
        GPU_COUNT=$((GPU_COUNT + 1))
        [ -n "${GPU_MODEL_REGEX-}" ] && [[ $name =~ $GPU_MODEL_REGEX ]] && matched=1
        is_int "$mem" && [ "$mem" -lt "${GPU_VRAM_MIB_MIN:-0}" ] && vram_ok=0
        result GPU "GPU $idx" INFO "$name, $mem MiB, bus $bus, VBIOS $vbios, S/N $serial"
        result GPU "GPU $idx PCIe" INFO "slot supports Gen$genmax x$widthmax"
    done < <(nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id,driver_version,vbios_version,serial,pcie.link.gen.max,pcie.link.width.max --format=csv,noheader,nounits)

    result GPU Driver PASS "NVIDIA $drv loaded, $GPU_COUNT GPU(s)"
    if [ -z "${GPU_MODEL_REGEX-}" ] || [ "$GPU_MODEL_REGEX" = . ]; then
        result GPU Model INFO "$name"
    elif [ "$matched" = 1 ]; then
        result GPU Model PASS "$name"
    else
        result GPU Model FAIL "found '$name', expected '$GPU_MODEL_REGEX'"
    fi
    if [ "$vram_ok" = 1 ]; then
        result GPU VRAM PASS "$mem MiB"
    else
        result GPU VRAM FAIL "$mem MiB, expected at least ${GPU_VRAM_MIB_MIN} MiB"
    fi

    ecc_unc=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.aggregate.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    ecc_unc=$(trim "$ecc_unc")
    if is_int "$ecc_unc"; then
        if [ "$ecc_unc" -gt 0 ]; then
            result GPU "VRAM ECC history" FAIL "$ecc_unc uncorrectable ECC errors recorded"
        else
            result GPU "VRAM ECC history" PASS "no uncorrectable ECC errors recorded"
        fi
    fi
    pending=$(trim "$(nvidia-smi --query-gpu=retired_pages.pending --format=csv,noheader 2>/dev/null | head -1)")
    [ "$pending" = Yes ] && result GPU "Retired pages" WARN "pages pending retirement (VRAM wear)"
    return 0
}

check_network() {
    local d n=0 name mac drv speed carrier
    for d in /sys/class/net/*; do
        [ -e "$d/device" ] || continue
        name=${d##*/}
        n=$((n + 1))
        ip link set "$name" up 2>/dev/null || true
    done
    [ "$n" -gt 0 ] && sleep 4
    for d in /sys/class/net/*; do
        [ -e "$d/device" ] || continue
        name=${d##*/}
        mac=$(cat "$d/address")
        drv=$(basename "$(readlink -f "$d/device/driver")" 2>/dev/null)
        carrier=$(cat "$d/carrier" 2>/dev/null || echo 0)
        speed=$(cat "$d/speed" 2>/dev/null || echo -1)
        if [ "$carrier" = 1 ] && [ "${speed:--1}" -gt 0 ]; then
            result Network "$name" INFO "$drv $mac, link up at $speed Mb/s"
        else
            result Network "$name" INFO "$drv $mac, no cable / link down"
        fi
    done
    [ "$n" -eq 0 ] && result Network Adapters WARN "no wired or wireless adapter found"
    return 0
}
