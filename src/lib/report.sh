# shellcheck shell=bash
# Kernel error scan, final verdict screen, text/HTML report, saving to USB.

KLOG_BASELINE=0
REPORT_TXT=$RUN_DIR/report.txt
REPORT_HTML=$RUN_DIR/report.html

KLOG_CPU='mce: \[Hardware Error\]|Machine check|EDAC .*(CE|UE)|soft lockup|hard LOCKUP|BUG: |Oops'
KLOG_GPU='NVRM: Xid|fallen off the bus'
KLOG_DISK='I/O error|nvme.*(timeout|reset controller)|ata[0-9.]+: (exception|failed command)|blk_update_request'
KLOG_PCIE='PCIe Bus Error|AER: .*error'

klog_mark() {
    KLOG_BASELINE=$(dmesg 2>/dev/null | wc -l)
}

# klog_eval FILE -> lines "CATEGORY<TAB>COUNT" for each category with hits
klog_eval() {
    local f=$1 n
    n=$(grep -cE "$KLOG_CPU" "$f"); [ "$n" -gt 0 ] && printf 'CPU/RAM\t%s\n' "$n"
    n=$(grep -cE "$KLOG_GPU" "$f"); [ "$n" -gt 0 ] && printf 'GPU\t%s\n' "$n"
    n=$(grep -vE 'sr[0-9]|loop[0-9]' "$f" | grep -cE "$KLOG_DISK"); [ "$n" -gt 0 ] && printf 'Disk\t%s\n' "$n"
    n=$(grep -cE "$KLOG_PCIE" "$f"); [ "$n" -gt 0 ] && printf 'PCIe\t%s\n' "$n"
    return 0
}

check_kernel_log() {
    local before=$LOG_DIR/dmesg-before-tests.txt during=$LOG_DIR/dmesg-during-tests.txt cat n found=0
    dmesg >"$LOG_DIR/dmesg.txt" 2>/dev/null
    head -n "$KLOG_BASELINE" "$LOG_DIR/dmesg.txt" >"$before"
    tail -n +"$((KLOG_BASELINE + 1))" "$LOG_DIR/dmesg.txt" >"$during"
    while IFS=$'\t' read -r cat n; do
        [ -n "$cat" ] || continue
        found=1
        if [ "$cat" = PCIe ] && ! grep -qE 'Uncorrect|Fatal' "$during"; then
            result System "Kernel log" WARN "$n corrected PCIe errors during tests"
        else
            result System "Kernel log" FAIL "$n $cat hardware errors logged during tests (see logs/dmesg-during-tests.txt)"
        fi
    done < <(klog_eval "$during")
    while IFS=$'\t' read -r cat n; do
        [ -n "$cat" ] || continue
        found=1
        result System "Kernel log (boot)" WARN "$n $cat errors already logged at boot, before any test"
    done < <(klog_eval "$before")
    [ "$found" = 0 ] && result System "Kernel log" PASS "no machine-check, GPU, disk or PCIe errors"
    return 0
}

summary_table() {
    local comp s
    for comp in System CPU RAM GPU Disk Network; do
        grep -q "^$comp"$'\t' "$RESULTS_TSV" || continue
        s=$(component_status "$comp")
        printf '%-10s %s\n' "$comp" "$s"
    done
}

identity_line() {
    awk -F'\t' '$1 == "System" && $2 == "Motherboard" { print $4 }' "$RESULTS_TSV"
}

write_text_report() {
    local verdict=$1
    {
        echo "HARDWARE CHECK REPORT"
        echo "====================="
        echo "Date:        $(date '+%F %T %Z')"
        echo "Profile:     $PROFILE ($SPEC_NAME)"
        echo "Mode:        $MODE (GPU ${T_GPU}s, CPU ${T_CPU}s, RAM ${T_RAM}s, CPU+GPU ${T_COMBO}s)"
        echo "Motherboard: $(identity_line)"
        echo "Duration:    $(fmt_mmss $((SECONDS - RUN_START)))"
        echo "VERDICT:     $verdict"
        echo
        echo "Summary"
        echo "-------"
        summary_table
        echo
        echo "All checks"
        echo "----------"
        awk -F'\t' '{ printf "[%-4s] %-8s %-24s %s\n", $3, $1, $2, $4 }' "$RESULTS_TSV"
        echo
        echo "Raw logs are in the logs/ folder next to this report."
    } >"$REPORT_TXT"
}

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_html_report() {
    local verdict=$1 vcolor
    case $verdict in
    PASSED) vcolor="#1a7f37" ;;
    "PASSED WITH WARNINGS") vcolor="#9a6700" ;;
    *) vcolor="#cf222e" ;;
    esac
    {
        cat <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hardware check report</title>
<style>
body{font-family:system-ui,sans-serif;max-width:1000px;margin:24px auto;padding:0 16px;color:#1f2328;background:#fff}
h1{font-size:22px}.verdict{font-size:28px;font-weight:700;color:#fff;background:$vcolor;padding:14px 18px;border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:14px;margin:12px 0}td,th{border-bottom:1px solid #d0d7de;padding:6px 8px;text-align:left;vertical-align:top}
.PASS{color:#1a7f37;font-weight:700}.WARN{color:#9a6700;font-weight:700}.FAIL{color:#cf222e;font-weight:700}.INFO,.SKIP{color:#656d76}
.meta td:first-child{color:#656d76;width:140px}
</style></head><body>
<h1>Hardware check report</h1>
<div class="verdict">$verdict</div>
<table class="meta">
<tr><td>Date</td><td>$(date '+%F %T %Z')</td></tr>
<tr><td>Expected spec</td><td>$(html_escape <<<"$SPEC_NAME")</td></tr>
<tr><td>Motherboard</td><td>$(identity_line | html_escape)</td></tr>
<tr><td>Mode</td><td>$MODE (GPU ${T_GPU}s, CPU ${T_CPU}s, RAM ${T_RAM}s, CPU+GPU ${T_COMBO}s)</td></tr>
<tr><td>Duration</td><td>$(fmt_mmss $((SECONDS - RUN_START)))</td></tr>
</table>
<table><tr><th>Status</th><th>Component</th><th>Check</th><th>Detail</th></tr>
EOF
        html_escape <"$RESULTS_TSV" | awk -F'\t' '{ printf "<tr><td class=\"%s\">%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $3, $3, $1, $2, $4 }'
        echo "</table><p>Generated by hwcheck. All internal disks were locked read-only during the tests.</p></body></html>"
    } >"$REPORT_HTML"
}

# Copy the report to the first partition labeled HWREPORT (on the boot stick or another stick)
save_report() {
    local dev mnt=/mnt/hwreport dir
    dev=$(blkid -l -t LABEL=HWREPORT -o device 2>/dev/null)
    if [ -z "$dev" ]; then
        result Report Saved INFO "no HWREPORT partition found, report kept in $RUN_DIR (run hwcheck-save after plugging one in)"
        return 1
    fi
    mkdir -p "$mnt"
    if ! mountpoint -q "$mnt" && ! mount "$dev" "$mnt" 2>/dev/null; then
        result Report Saved WARN "could not mount $dev"
        return 1
    fi
    dir=$mnt/hwcheck-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$dir" && cp -r "$REPORT_TXT" "$REPORT_HTML" "$LOG_DIR" "$dir/" && sync
    umount "$mnt" 2>/dev/null
    result Report Saved INFO "copied to $dev (${dir#"$mnt"/})"
}

big_text() {
    if command -v figlet >/dev/null; then
        figlet -w "${COLUMNS:-100}" -c "$1"
    else
        printf '\n    *** %s ***\n\n' "$1"
    fi
}

show_verdict() {
    local overall=$1 verdict=$2 color comp s c
    case $overall in PASS) color=$C_GRN ;; WARN) color=$C_YEL ;; *) color=$C_RED ;; esac
    clear 2>/dev/null || true
    printf '%s' "$color"
    big_text "$verdict"
    printf '%s\n' "$C_0"
    printf '  %s%s%s\n\n' "$C_B" "$SPEC_NAME" "$C_0"
    while read -r comp s; do
        case $s in PASS) c=$C_GRN ;; WARN) c=$C_YEL ;; FAIL) c=$C_RED ;; *) c=$C_DIM ;; esac
        printf '    %-10s %s%-5s%s\n' "$comp" "$c" "$s" "$C_0"
    done < <(summary_table)
    echo
    if [ "$overall" != PASS ]; then
        printf '  %sItems that need attention:%s\n' "$C_B" "$C_0"
        awk -F'\t' '$3 == "FAIL" || $3 == "WARN" { printf "    [%s] %s %s: %s\n", $3, $1, $2, $4 }' "$RESULTS_TSV"
        echo
    fi
    printf '  Total time %s. Full report: less %s\n' "$(fmt_mmss $((SECONDS - RUN_START)))" "$REPORT_TXT"
    printf '  Alt+F2 opens a second shell. Type "poweroff" to shut down.\n\n'
}
