# shellcheck shell=bash
# Load tests for GPU, CPU and memory, with a live status line and sensor logging.

GPU_BURN=${GPU_BURN:-/usr/local/lib/hwcheck/gpu_burn}
GPU_BURN_KERNEL=${GPU_BURN_KERNEL:-/usr/local/lib/hwcheck/compare.fatbin}
GPU_BURN_MEM=${GPU_BURN_MEM:-90%}
BG_PIDS=()

# Highest CPU package temperature in C from coretemp/k10temp, or empty
cpu_pkg_temp() {
    local h best="" t lbl f
    for h in /sys/class/hwmon/hwmon*; do
        case $(cat "$h/name" 2>/dev/null) in coretemp | k10temp | zenpower) ;; *) continue ;; esac
        for f in "$h"/temp*_input; do
            [ -e "$f" ] || continue
            lbl=$(cat "${f%_input}_label" 2>/dev/null)
            case $lbl in "Package id"* | Tctl | Tdie | "") ;; *) continue ;; esac
            t=$(($(cat "$f") / 1000))
            if [ -z "$best" ] || [ "$t" -gt "$best" ]; then best=$t; fi
        done
    done
    printf '%s' "$best"
}

cpu_avg_mhz() {
    awk -F: '/^cpu MHz/ { s += $2; n++ } END { if (n) printf "%d", s / n }' /proc/cpuinfo
}

# Total thermal throttle events (package + all cores)
cpu_throttle_count() {
    local s=0 f
    f=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
    [ -r "$f" ] && s=$(cat "$f")
    for f in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
        [ -r "$f" ] && s=$((s + $(cat "$f")))
    done
    printf '%s' "$s"
}

# One CSV line per GPU: temp,power,sm_clock,util,pcie_width,hw_slow,hw_thermal,sw_thermal,power_brake
gpu_sample() {
    local p=$GPU_THROTTLE_PREFIX
    nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu,pcie.link.width.current,"$p.hw_slowdown,$p.hw_thermal_slowdown,$p.sw_thermal_slowdown,$p.hw_power_brake_slowdown" \
        --format=csv,noheader,nounits 2>/dev/null
}

reset_phase_stats() {
    PH_CPU_T=0 PH_GPU_T=0 PH_GPU_P=0 PH_GPU_CLK=0 PH_GPU_MINW=99 PH_GPU_THR="" PH_MHZ_SUM=0 PH_MHZ_N=0
    PH_THR0=$(cpu_throttle_count)
}

# watch_load LABEL DURATION PID... : live status line until all PIDs exit
watch_load() {
    local label=$1 dur=$2 start el ct mhz gs line gline csv alive pid
    shift 2
    csv=$LOG_DIR/monitor-$label.csv
    echo "elapsed,cpu_temp,cpu_mhz,gpu_temp,gpu_power,gpu_clock,gpu_util,pcie_width,hw_slow,hw_thermal,sw_thermal,power_brake" >"$csv"
    start=$SECONDS
    while :; do
        alive=0
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" = 1 ] || break
        el=$((SECONDS - start))
        ct=$(cpu_pkg_temp)
        mhz=$(cpu_avg_mhz)
        if [ -n "$ct" ] && [ "$ct" -gt "$PH_CPU_T" ]; then PH_CPU_T=$ct; fi
        if is_int "$mhz"; then PH_MHZ_SUM=$((PH_MHZ_SUM + mhz)) PH_MHZ_N=$((PH_MHZ_N + 1)); fi
        gline=""
        if gpu_available; then
            gs=$(gpu_sample)
            while IFS=, read -r t p c u w s1 s2 s3 s4; do
                t=$(trim "$t"); p=$(trim "$p"); c=$(trim "$c"); u=$(trim "$u"); w=$(trim "$w")
                echo "$el,$ct,$mhz,$t,$p,$c,$u,$w,$(trim "$s1"),$(trim "$s2"),$(trim "$s3"),$(trim "$s4")" >>"$csv"
                if is_int "$t" && [ "$t" -gt "$PH_GPU_T" ]; then PH_GPU_T=$t; fi
                fgt "$p" "$PH_GPU_P" && PH_GPU_P=$p
                if is_int "$c" && [ "$c" -gt "$PH_GPU_CLK" ]; then PH_GPU_CLK=$c; fi
                if is_int "$u" && is_int "$w" && [ "$u" -ge 90 ] && [ "$w" -lt "$PH_GPU_MINW" ]; then PH_GPU_MINW=$w; fi
                [[ $(trim "$s1") == Active ]] && PH_GPU_THR+=" hw-slowdown"
                [[ $(trim "$s2") == Active ]] && PH_GPU_THR+=" hw-thermal"
                [[ $(trim "$s3") == Active ]] && PH_GPU_THR+=" sw-thermal"
                [[ $(trim "$s4") == Active ]] && PH_GPU_THR+=" power-brake"
                gline+=" | GPU ${t}C ${p%.*}W ${c}MHz ${u}%"
            done <<<"$gs"
        else
            echo "$el,$ct,$mhz,,,,,,,,," >>"$csv"
        fi
        printf -v line '  %s %s / %s | CPU %sC %s MHz%s' "$label" "$(fmt_mmss "$el")" "$(fmt_mmss "$dur")" "${ct:-n/a}" "${mhz:-?}" "$gline"
        printf '\r\e[K%s' "${line:0:$((${COLUMNS:-120} - 1))}"
        sleep 2
    done
    printf '\r\e[K'
}

# Report temperatures and throttling seen during the phase that just ended
phase_thermals() {
    local comp=$1 thr avg
    avg=0
    [ "$PH_MHZ_N" -gt 0 ] && avg=$((PH_MHZ_SUM / PH_MHZ_N))
    if [ "$comp" = CPU ] || [ "$comp" = System ]; then
        thr=$(($(cpu_throttle_count) - PH_THR0))
        if [ "$PH_CPU_T" -gt 0 ]; then
            if [ "$PH_CPU_T" -ge "${CPU_TEMP_WARN_C:-95}" ] || [ "$thr" -gt 0 ]; then
                result "$comp" "Cooling (CPU)" WARN "max ${PH_CPU_T}C, $thr thermal throttle events, avg ${avg} MHz"
            else
                result "$comp" "Cooling (CPU)" PASS "max ${PH_CPU_T}C, no thermal throttling, avg ${avg} MHz"
            fi
        else
            result "$comp" "Cooling (CPU)" INFO "no CPU temperature sensor, avg ${avg} MHz"
        fi
    fi
    if { [ "$comp" = GPU ] || [ "$comp" = System ]; } && gpu_available; then
        thr=$(tr ' ' '\n' <<<"$PH_GPU_THR" | sort -u | grep . | paste -sd, -)
        if [ "$PH_GPU_T" -ge "${GPU_TEMP_WARN_C:-88}" ] || [ -n "$thr" ]; then
            result "$comp" "Cooling (GPU)" WARN "max ${PH_GPU_T}C, ${PH_GPU_P%.*}W, ${PH_GPU_CLK} MHz${thr:+, throttled: $thr}"
        else
            result "$comp" "Cooling (GPU)" PASS "max ${PH_GPU_T}C, peak ${PH_GPU_P%.*}W, ${PH_GPU_CLK} MHz, no throttling"
        fi
        if [ "$comp" = GPU ] && [ "$PH_GPU_MINW" -lt 99 ]; then
            if [ "$PH_GPU_MINW" -lt "${GPU_PCIE_WIDTH_MIN:-16}" ]; then
                result GPU "PCIe link" WARN "ran at x$PH_GPU_MINW under load (expected x${GPU_PCIE_WIDTH_MIN:-16})"
            else
                result GPU "PCIe link" PASS "x$PH_GPU_MINW under load"
            fi
        fi
    fi
}

# gpu_burn_eval LOGFILE EXPECTED_GPUS -> PASS|FAIL<TAB>detail
gpu_burn_eval() {
    local log=$1 want=$2 ok faulty gflops
    ok=$(grep -cE 'GPU [0-9]+: OK' "$log")
    faulty=$(grep -cE 'GPU [0-9]+: FAULTY' "$log")
    gflops=$(tr '\r' '\n' <"$log" | grep -oE '\([0-9]+ Gflop/s\)' | tail -1 | tr -dc '0-9')
    if [ "$faulty" -gt 0 ]; then
        printf 'FAIL\t%s GPU(s) produced calculation errors\n' "$faulty"
    elif [ "$ok" -ge "$want" ] && [ "$want" -gt 0 ]; then
        printf 'PASS\tno calculation errors, ~%s Gflop/s\n' "${gflops:-?}"
    else
        printf 'FAIL\tgpu-burn did not finish (see logs)\n'
    fi
}

start_gpu_burn() {
    local dur=$1 log=$2
    (cd /tmp && exec "$GPU_BURN" -c "$GPU_BURN_KERNEL" -m "$GPU_BURN_MEM" "$dur") >"$log" 2>&1 &
    BG_PIDS+=($!)
    GPU_PID=$!
}

start_cpu_burn() {
    local dur=$1 log=$2
    stress-ng --cpu 0 --cpu-method matrixprod --verify --timeout "${dur}s" --metrics-brief >"$log" 2>&1 &
    BG_PIDS+=($!)
    CPU_PID=$!
}

# stress_ng_ok EXIT_CODE LOGFILE: clean exit, run completed, no failed workers
stress_ng_ok() {
    [ "$1" -eq 0 ] &&
        grep -q 'successful run completed' "$2" &&
        ! grep -qE 'failed: [1-9]|verification fail|miscompute' "$2"
}

check_gpu_alive() {
    if ! timeout 20 nvidia-smi -L >/dev/null 2>&1; then
        result GPU "After load" FAIL "GPU stopped responding after the stress test"
        return 1
    fi
}

run_gpu_stress() {
    local dur=$1 log=$LOG_DIR/gpu-burn.log status detail
    if ! gpu_available; then
        result GPU "Stress test" SKIP "no working NVIDIA GPU"
        return
    fi
    reset_phase_stats
    start_gpu_burn "$dur" "$log"
    watch_load "GPU" "$dur" "$GPU_PID"
    wait "$GPU_PID"
    IFS=$'\t' read -r status detail < <(gpu_burn_eval "$log" "$GPU_COUNT")
    result GPU "Stress test" "$status" "$detail ($(fmt_mmss "$dur"), VRAM $GPU_BURN_MEM)"
    phase_thermals GPU
    check_gpu_alive
}

run_cpu_stress() {
    local dur=$1 log=$LOG_DIR/stress-ng-cpu.log rc
    reset_phase_stats
    start_cpu_burn "$dur" "$log"
    watch_load "CPU" "$dur" "$CPU_PID"
    wait "$CPU_PID"
    rc=$?
    if stress_ng_ok "$rc" "$log"; then
        result CPU "Stress test" PASS "$(nproc) threads, all results verified ($(fmt_mmss "$dur"))"
    else
        result CPU "Stress test" FAIL "stress-ng exit $rc, computation errors (see logs/stress-ng-cpu.log)"
    fi
    phase_thermals CPU
}

run_ram_stress() {
    local dur=$1 log=$LOG_DIR/stressapptest.log mb rc pid
    mb=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 * 0.88 }' /proc/meminfo)
    reset_phase_stats
    stressapptest -s "$dur" -M "$mb" -m "$(nproc)" -W >"$log" 2>&1 &
    pid=$!
    BG_PIDS+=("$pid")
    watch_load "RAM" "$dur" "$pid"
    wait "$pid"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'Status: PASS' "$log"; then
        result RAM "Stress test" PASS "$((mb / 1024)) GB tested with $(nproc) threads, no errors ($(fmt_mmss "$dur"))"
    else
        result RAM "Stress test" FAIL "memory errors detected (see logs/stressapptest.log)"
    fi
}

run_combined() {
    local dur=$1 glog=$LOG_DIR/gpu-burn-combined.log clog=$LOG_DIR/stress-ng-combined.log rc status detail
    if ! gpu_available; then
        result System "Full load (CPU+GPU)" SKIP "needs a working GPU"
        return
    fi
    reset_phase_stats
    start_gpu_burn "$dur" "$glog"
    start_cpu_burn "$dur" "$clog"
    watch_load "CPU+GPU" "$dur" "$GPU_PID" "$CPU_PID"
    wait "$CPU_PID"
    rc=$?
    wait "$GPU_PID"
    IFS=$'\t' read -r status detail < <(gpu_burn_eval "$glog" "$GPU_COUNT")
    if stress_ng_ok "$rc" "$clog" && [ "$status" = PASS ]; then
        result System "Full load (CPU+GPU)" PASS "stable for $(fmt_mmss "$dur") at peak GPU ${PH_GPU_P%.*}W + all CPU cores (power supply OK)"
    else
        result System "Full load (CPU+GPU)" FAIL "errors under combined load (cpu exit $rc, gpu: $detail)"
    fi
    phase_thermals System
}

stop_background() {
    local pid
    for pid in "${BG_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    wait 2>/dev/null
}
