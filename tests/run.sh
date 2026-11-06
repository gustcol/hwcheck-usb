#!/usr/bin/env bash
# Unit tests for the parsers in src/lib. Runs on any machine with bash 4+ and jq.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FX=$HERE/fixtures
LIB=$HERE/../src/lib
RUN_DIR=$(mktemp -d)
export RUN_DIR
trap 'rm -rf "$RUN_DIR"' EXIT

# shellcheck source=src/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=src/lib/inventory.sh
. "$LIB/inventory.sh"
# shellcheck source=src/lib/disks.sh
. "$LIB/disks.sh"
# shellcheck source=src/lib/stress.sh
. "$LIB/stress.sh"
# shellcheck source=src/lib/report.sh
. "$LIB/report.sh"
init_dirs

pass=0
fail=0
eq() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$name" "$want" "$got"
    fi
}

# kernel command line
CMDLINE_FILE=$FX/cmdline.txt
eq "cmdline mode" full "$(cmdline_get hwcheck.mode quick)"
eq "cmdline profile" vm-test "$(cmdline_get hwcheck.profile target)"
eq "cmdline default" 0 "$(cmdline_get hwcheck.serial 0)"

# formatting
eq "human_bytes 2TB" "2.00 TB" "$(human_bytes 2000398934016)"
eq "human_bytes small" "512 B" "$(human_bytes 512)"
eq "fmt_mmss" "04:05" "$(fmt_mmss 245)"
eq "trim" "a b" "$(trim "  a b  ")"

# CPU topology: 1 socket, 18 cores, 36 threads
eq "cpu topology" "1 18 36" "$(count_cpu_topology <"$FX/lscpu-10980xe.txt")"

# DIMMs: 4 x 32 GB installed, empty slot ignored, MB units handled
dimms=$(parse_dimms <"$FX/dmidecode-t17.txt")
eq "dimm count" 4 "$(grep -c . <<<"$dimms")"
eq "dimm total MB" 131072 "$(cut -d'|' -f1 <<<"$dimms" | paste -sd+ - | bc)"
eq "dimm first" "32768|DIMM_A1|3200 MT/s|2933 MT/s|Corsair|CMK64GX4M2E3200C16" "$(head -1 <<<"$dimms")"

# disk discovery: skip USB, rom, zram and the boot medium
disks=$(filter_disks sdc <"$FX/lsblk.json")
eq "disk names" "nvme0n1 sda" "$(cut -f1 <<<"$disks" | paste -sd' ' -)"
eq "disk kinds" "NVMe SSD" "$(cut -f3 <<<"$disks" | paste -sd' ' -)"
eq "disk model trimmed" "Samsung SSD 970 EVO Plus 2TB" "$(head -1 <<<"$disks" | cut -f4)"
eq "hdd detected" "HDD" "$(filter_disks "" <"$FX/lsblk.json" | awk -F'\t' '$1=="sdc"{print $3}')"

# SMART
eq "smart nvme ok" PASS "$(smart_eval "$FX/smart-nvme-ok.json" | cut -f1)"
eq "smart nvme media errors" WARN "$(smart_eval "$FX/smart-nvme-bad.json" | cut -f1)"
eq "smart nvme temp warning" WARN "$(jq '.nvme_smart_health_information_log.critical_warning = 2' "$FX/smart-nvme-ok.json" >"$RUN_DIR/t.json"; smart_eval "$RUN_DIR/t.json" | cut -f1)"
eq "smart nvme spare warning" FAIL "$(jq '.nvme_smart_health_information_log.critical_warning = 1' "$FX/smart-nvme-ok.json" >"$RUN_DIR/t.json"; smart_eval "$RUN_DIR/t.json" | cut -f1)"
eq "smart ata packed raw" PASS "$(jq '.ata_smart_attributes.table = [{"id":197,"raw":{"value":4294967296}}]' "$FX/smart-ata-realloc.json" >"$RUN_DIR/t.json"; smart_eval "$RUN_DIR/t.json" | cut -f1)"
eq "smart nvme worn" WARN "$(smart_eval "$FX/smart-nvme-worn.json" | cut -f1)"
eq "smart ata realloc" WARN "$(smart_eval "$FX/smart-ata-realloc.json" | cut -f1)"
eq "smart ata pending" FAIL "$(smart_eval "$FX/smart-ata-pending.json" | cut -f1)"
eq "smart unavailable" WARN "$(smart_eval "$FX/smart-none.json" | cut -f1)"
eq "self-test nvme pass" PASS "$(selftest_eval "$FX/selftest-nvme-pass.json")"
eq "self-test nvme running" RUNNING "$(selftest_eval "$FX/selftest-nvme-running.json")"
eq "self-test ata fail" FAIL "$(selftest_eval "$FX/selftest-ata-fail.json")"
eq "self-test none" NONE "$(selftest_eval "$FX/smart-none.json")"

# fio
eq "fio parse" "0 3251000000 3100" "$(fio_eval "$FX/fio-ok.json")"
eq "fio missing" "1 0 0" "$(fio_eval "$FX/does-not-exist.json")"

# gpu-burn
eq "gpu-burn ok" PASS "$(gpu_burn_eval "$FX/gpuburn-ok.log" 1 | cut -f1)"
eq "gpu-burn gflops" "no calculation errors, ~14702 Gflop/s" "$(gpu_burn_eval "$FX/gpuburn-ok.log" 1 | cut -f2)"
eq "gpu-burn faulty" FAIL "$(gpu_burn_eval "$FX/gpuburn-faulty.log" 1 | cut -f1)"
eq "gpu-burn died" FAIL "$(gpu_burn_eval "$FX/gpuburn-died.log" 1 | cut -f1)"
eq "gpu-burn real A6000 log" PASS "$(gpu_burn_eval "$FX/gpuburn-real-a6000.log" 1 | cut -f1)"
eq "gpu-burn too few" FAIL "$(gpu_burn_eval "$FX/gpuburn-ok.log" 2 | cut -f1)"

# stress-ng
stress_ng_ok 0 "$FX/stressng-ok.log" && r=ok || r=bad
eq "stress-ng ok" ok "$r"
stress_ng_ok 0 "$FX/stressng-fail.log" && r=ok || r=bad
eq "stress-ng failed workers" bad "$r"
stress_ng_ok 2 "$FX/stressng-ok.log" && r=ok || r=bad
eq "stress-ng exit code" bad "$r"

# kernel log
eq "klog clean (sr0 ignored)" "" "$(klog_eval "$FX/dmesg-clean.txt")"
eq "klog errors" "CPU/RAM 1|GPU 1|Disk 1|PCIe 1" "$(klog_eval "$FX/dmesg-errors.txt" | tr '\t' ' ' | paste -sd'|' -)"

# kernel log split by timestamp, USB stick I/O errors ignored
printf '[    5.000000] boot line\n[  100.500000] mce: [Hardware Error]: CPU 0\n' >"$RUN_DIR/dm.txt"
klog_split "$RUN_DIR/dm.txt" 50 "$RUN_DIR/b.txt" "$RUN_DIR/d.txt"
eq "klog split before" 1 "$(wc -l <"$RUN_DIR/b.txt" | tr -d ' ')"
eq "klog split during" "CPU/RAM 1" "$(klog_eval "$RUN_DIR/d.txt" | tr '\t' ' ')"
printf 'blk_update_request: I/O error, dev sdb, sector 9\n' >"$RUN_DIR/u.txt"
KLOG_IGNORE='sr[0-9]|loop[0-9]|\bsdb[0-9]*\b'
eq "klog usb ignored" "" "$(klog_eval "$RUN_DIR/u.txt")"
printf 'blk_update_request: I/O error, dev sdbx, sector 9\n' >"$RUN_DIR/u.txt"
eq "klog other disk counted" "Disk 1" "$(klog_eval "$RUN_DIR/u.txt" | tr '\t' ' ')"

# results and verdict
result CPU Model PASS "x" >/dev/null
result Disk sda WARN "y" >/dev/null
eq "overall warn" WARN "$(overall_status)"
eq "component pass" PASS "$(component_status CPU)"
result GPU Driver FAIL "z" >/dev/null
eq "overall fail" FAIL "$(overall_status)"
eq "component missing" INFO "$(component_status Network)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
