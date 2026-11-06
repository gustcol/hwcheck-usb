# shellcheck shell=bash
# Disks: inventory, write protection, SMART health and read-only benchmarks.
# Nothing in here writes to the machine's disks. Every internal disk is
# switched to read-only in the kernel before any test touches it.

# Each entry: NAME<TAB>SIZE_BYTES<TAB>KIND<TAB>MODEL<TAB>SERIAL
TEST_DISKS=()

parent_disk() {
    local name=${1#/dev/} sys
    sys=/sys/class/block/$name
    if [ -e "$sys/partition" ]; then
        basename "$(dirname "$(readlink -f "$sys")")"
    else
        printf '%s\n' "$name"
    fi
}

live_medium_disk() {
    local src
    src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null | head -1)
    [ -n "$src" ] && parent_disk "$src"
    return 0
}

# Turn `lsblk -J -d -b -o NAME,SIZE,TYPE,TRAN,ROTA,MODEL,SERIAL` (stdin) into
# TEST_DISKS lines, skipping USB devices, virtual devices and the boot medium.
filter_disks() {
    local skip=${1-}
    jq -r --arg skip "$skip" '
        .blockdevices[]
        | select(.type == "disk")
        | select((.tran // "") != "usb")
        | select(.name | test("^(loop|ram|zram|sr|md|dm-)|^mmcblk[0-9]+(boot|rpmb)") | not)
        | select(.name != $skip)
        | select((.size // 0) > 0)
        | [ .name, (.size | tostring),
            (if (.name | startswith("nvme")) then "NVMe"
             elif ((.rota | tostring) == "true" or (.rota | tostring) == "1") then "HDD"
             else "SSD" end),
            ((.model // "unknown") | gsub("\\s+$"; "")), (.serial // "unknown") ]
        | @tsv'
}

discover_disks() {
    local line
    TEST_DISKS=()
    while IFS= read -r line; do
        [ -n "$line" ] && TEST_DISKS+=("$line")
    done < <(lsblk -J -d -b -o NAME,SIZE,TYPE,TRAN,ROTA,MODEL,SERIAL | filter_disks "$(live_medium_disk)")
}

# protect_disks [quiet]: lock every test disk and partition read-only. Called
# again before each disk phase, because an NVMe controller reset can clear
# the flag. With "quiet" only a failure is reported.
protect_disks() {
    local quiet=${1-} entry name dev p bad=0 n=0
    for entry in "${TEST_DISKS[@]}"; do
        name=${entry%%$'\t'*}
        for dev in "/dev/$name" $(lsblk -lnpo NAME "/dev/$name" | tail -n +2); do
            blockdev --setro "$dev" 2>/dev/null
            p=$(blockdev --getro "$dev" 2>/dev/null)
            [ "$p" = 1 ] || bad=$((bad + 1))
        done
        n=$((n + 1))
    done
    [ "$n" -eq 0 ] && return 0
    if [ "$bad" -eq 0 ] && [ -n "$quiet" ]; then
        return 0
    elif [ "$bad" -eq 0 ]; then
        result Disk "Write protection" PASS "all $n internal disks locked read-only by the kernel"
    else
        result Disk "Write protection" WARN "$bad device(s) could not be locked read-only (tests only read anyway)"
    fi
}

check_disks_inventory() {
    local entry name size kind model serial total=0 min
    if [ "${#TEST_DISKS[@]}" -eq 0 ] && [ "${DISK_TOTAL_GB_MIN:-0}" -eq 0 ]; then
        result Disk Detected INFO "no internal disks found"
        return
    elif [ "${#TEST_DISKS[@]}" -eq 0 ]; then
        result Disk Detected FAIL "no internal disks found"
        return
    fi
    for entry in "${TEST_DISKS[@]}"; do
        IFS=$'\t' read -r name size kind model serial <<<"$entry"
        total=$((total + size))
        result Disk "$name" INFO "$(human_bytes "$size") $kind $model (S/N $serial)"
    done
    if [ "${DISK_TOTAL_GB_MIN:-0}" -eq 0 ]; then
        result Disk Capacity INFO "${#TEST_DISKS[@]} disk(s), $(human_bytes "$total") total"
        return
    fi
    min=$(awk -v g="${DISK_TOTAL_GB_MIN:-0}" 'BEGIN { printf "%.0f", g * 1e9 }')
    if awk -v t="$total" -v m="$min" 'BEGIN { exit !(t >= m) }'; then
        result Disk Capacity PASS "${#TEST_DISKS[@]} disk(s), $(human_bytes "$total") total"
    else
        result Disk Capacity FAIL "${#TEST_DISKS[@]} disk(s), $(human_bytes "$total") total, expected at least ${DISK_TOTAL_GB_MIN} GB"
    fi
}

# smart_eval FILE (smartctl -j output) -> "STATUS<TAB>DETAIL"
smart_eval() {
    local f=$1 passed poh temp cw me pu sp spt realloc pending offline uncorr status detail
    passed=$(jq -r 'if .smart_status.passed == null then "na" else (.smart_status.passed | tostring) end' "$f" 2>/dev/null)
    if [ -z "$passed" ] || [ "$passed" = na ]; then
        printf 'WARN\tSMART not available on this device\n'
        return
    fi
    poh=$(jq -r '.power_on_time.hours // "?"' "$f")
    temp=$(jq -r '.temperature.current // "?"' "$f")
    if jq -e '.nvme_smart_health_information_log' "$f" >/dev/null 2>&1; then
        read -r cw me pu sp spt < <(jq -r '.nvme_smart_health_information_log
            | [.critical_warning, .media_errors, .percentage_used, .available_spare, .available_spare_threshold]
            | map(tostring) | join(" ")' "$f")
        detail="health $([ "$passed" = true ] && echo OK || echo FAILED), ${poh}h powered on, ${pu}% wear, spare ${sp}%, media errors $me, ${temp}C"
        # critical_warning bit 1 (value 2) is "over temperature": a warning,
        # the other bits (spare, reliability, read-only, backup) are failures.
        if [ "$passed" != true ] || [ $((cw & ~2)) -ne 0 ]; then
            status=FAIL
        elif [ $((cw & 2)) -ne 0 ] || [ "$me" != 0 ] || [ "$pu" -ge 90 ] || [ "$sp" -le "$spt" ]; then
            status=WARN
        else
            status=PASS
        fi
    else
        # Some SSDs pack extra data into the upper raw bytes; the count is the low 16 bits.
        attr() { jq -r --argjson id "$1" '([.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value][0] // 0) % 65536' "$f"; }
        realloc=$(attr 5)
        uncorr=$(attr 187)
        pending=$(attr 197)
        offline=$(attr 198)
        detail="health $([ "$passed" = true ] && echo OK || echo FAILED), ${poh}h powered on, reallocated $realloc, pending $pending, uncorrectable $offline, ${temp}C"
        if [ "$passed" != true ] || [ "$pending" != 0 ]; then
            status=FAIL
        elif [ "$realloc" != 0 ] || [ "$uncorr" != 0 ] || [ "$offline" != 0 ]; then
            status=WARN
        else
            status=PASS
        fi
    fi
    printf '%s\t%s\n' "$status" "$detail"
}

check_disk_health() {
    local entry name status detail out
    for entry in "${TEST_DISKS[@]}"; do
        name=${entry%%$'\t'*}
        out=$LOG_DIR/smart-$name.json
        timeout 90 smartctl -x -j "/dev/$name" >"$out" 2>/dev/null
        timeout 90 smartctl -x "/dev/$name" >"$LOG_DIR/smart-$name.txt" 2>&1
        IFS=$'\t' read -r status detail < <(smart_eval "$out")
        result Disk "$name SMART" "$status" "$detail"
        # Short self-test runs inside the drive firmware, it never touches data.
        timeout 60 smartctl -t short "/dev/$name" >>"$LOG_DIR/smart-$name.txt" 2>&1 || true
    done
    return 0
}

# selftest_eval FILE (smartctl -l selftest -j) -> PASS|FAIL|RUNNING|NONE
selftest_eval() {
    jq -r '
        if .nvme_self_test_log then
            if (.nvme_self_test_log.current_self_test_operation.value // 0) != 0 then "RUNNING"
            elif (.nvme_self_test_log.table // []) | length == 0 then "NONE"
            elif .nvme_self_test_log.table[0].self_test_result.value == 0 then "PASS"
            else "FAIL" end
        elif .ata_smart_self_test_log then
            if ((.ata_smart_data.self_test.status.value // 0) >= 240) then "RUNNING"
            elif (.ata_smart_self_test_log.standard.table // []) | length == 0 then "NONE"
            elif .ata_smart_self_test_log.standard.table[0].status.passed == true then "PASS"
            else "FAIL" end
        else "NONE" end' "$1" 2>/dev/null || echo NONE
}

finish_disk_selftests() {
    local entry name out st
    for entry in "${TEST_DISKS[@]}"; do
        name=${entry%%$'\t'*}
        out=$LOG_DIR/selftest-$name.json
        timeout 60 smartctl -l selftest -j "/dev/$name" >"$out" 2>/dev/null
        st=$(selftest_eval "$out")
        case $st in
        PASS) result Disk "$name self-test" PASS "drive short self-test completed without error" ;;
        FAIL) result Disk "$name self-test" FAIL "drive short self-test reported an error" ;;
        RUNNING) result Disk "$name self-test" INFO "self-test still running, not counted" ;;
        *) result Disk "$name self-test" SKIP "drive does not support self-tests" ;;
        esac
    done
    return 0
}

# fio_eval FILE -> "ERR BW_BYTES IOPS"
fio_eval() {
    jq -r '.jobs[0] | "\(.error) \(.read.bw_bytes | floor) \(.read.iops | floor)"' "$1" 2>/dev/null || echo "1 0 0"
}

run_disk_read() {
    local dur=$1 entry name size kind model serial err bw rerr riops mbs min rdur
    rdur=$((dur < 15 ? dur : 15))
    for entry in "${TEST_DISKS[@]}"; do
        IFS=$'\t' read -r name size kind model serial <<<"$entry"
        printf '  %s... reading /dev/%s for %ss%s\n' "$C_DIM" "$name" "$((dur + rdur))" "$C_0"
        timeout $((dur + 120)) fio --name=seqread --filename="/dev/$name" --readonly --rw=read --bs=1M --direct=1 \
            --ioengine=libaio --iodepth=32 --runtime="$dur" --time_based \
            --output-format=json --output="$LOG_DIR/fio-seq-$name.json" >/dev/null 2>&1
        timeout $((rdur + 120)) fio --name=randread --filename="/dev/$name" --readonly --rw=randread --bs=4k --direct=1 \
            --ioengine=libaio --iodepth=32 --numjobs=4 --group_reporting --runtime="$rdur" --time_based \
            --output-format=json --output="$LOG_DIR/fio-rand-$name.json" >/dev/null 2>&1
        read -r err bw _ < <(fio_eval "$LOG_DIR/fio-seq-$name.json")
        read -r rerr _ riops < <(fio_eval "$LOG_DIR/fio-rand-$name.json")
        mbs=$((bw / 1000000))
        case $kind in NVMe) min=800 ;; SSD) min=250 ;; *) min=60 ;; esac
        if [ "$err" != 0 ] || [ "$rerr" != 0 ] || [ "$bw" -eq 0 ]; then
            result Disk "$name read test" FAIL "read errors during the test (see logs/fio-*-$name.json)"
        elif [ "$mbs" -lt "$min" ]; then
            result Disk "$name read test" WARN "slow: $mbs MB/s sequential, $riops IOPS random 4K (expected > $min MB/s for $kind)"
        else
            result Disk "$name read test" PASS "$mbs MB/s sequential, $riops IOPS random 4K"
        fi
    done
    return 0
}
