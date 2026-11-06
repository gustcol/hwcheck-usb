# shellcheck shell=bash disable=SC2034
# Shared helpers: result bookkeeping, colors, kernel cmdline, formatting.

RUN_DIR=${RUN_DIR:-/run/hwcheck}
LOG_DIR=$RUN_DIR/logs
RESULTS_TSV=$RUN_DIR/results.tsv
CMDLINE_FILE=${CMDLINE_FILE:-/proc/cmdline}
PROFILE_DIR=${PROFILE_DIR:-/etc/hwcheck/profiles}

C_RED=$'\e[1;31m'
C_GRN=$'\e[1;32m'
C_YEL=$'\e[1;33m'
C_CYN=$'\e[1;36m'
C_DIM=$'\e[2m'
C_B=$'\e[1m'
C_0=$'\e[0m'

init_dirs() {
    mkdir -p "$LOG_DIR"
    : >"$RESULTS_TSV"
}

# cmdline_get KEY [DEFAULT] -> value of KEY=value on the kernel command line
cmdline_get() {
    local key=$1 default=${2-} tok
    local -a toks=()
    read -r -a toks <"$CMDLINE_FILE" || true
    for tok in "${toks[@]}"; do
        case $tok in
        "$key="*)
            printf '%s\n' "${tok#*=}"
            return 0
            ;;
        esac
    done
    printf '%s\n' "$default"
}

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_DIR/hwcheck.log"
}

# result COMPONENT CHECK STATUS [DETAIL]
# STATUS is one of PASS WARN FAIL INFO SKIP
result() {
    local comp=$1 check=$2 status=$3 detail=${4-} color
    detail=${detail//$'\t'/ }
    detail=${detail//$'\n'/ }
    printf '%s\t%s\t%s\t%s\n' "$comp" "$check" "$status" "$detail" >>"$RESULTS_TSV"
    log "$status $comp/$check: $detail"
    case $status in
    PASS) color=$C_GRN ;;
    WARN) color=$C_YEL ;;
    FAIL) color=$C_RED ;;
    *) color=$C_DIM ;;
    esac
    printf '  %s[%-4s]%s %-26s %s\n' "$color" "$status" "$C_0" "$comp: $check" "$detail"
}

section() {
    printf '\n%s== %s ==%s\n' "$C_CYN" "$*" "$C_0"
    log "== $* =="
}

# Worst status recorded so far: FAIL > WARN > PASS
overall_status() {
    if cut -f3 "$RESULTS_TSV" | grep -qx FAIL; then
        echo FAIL
    elif cut -f3 "$RESULTS_TSV" | grep -qx WARN; then
        echo WARN
    else
        echo PASS
    fi
}

# Worst status for one component
component_status() {
    local s
    s=$(awk -F'\t' -v c="$1" '$1 == c { print $3 }' "$RESULTS_TSV")
    if grep -qx FAIL <<<"$s"; then
        echo FAIL
    elif grep -qx WARN <<<"$s"; then
        echo WARN
    elif grep -qx PASS <<<"$s"; then
        echo PASS
    elif grep -qx SKIP <<<"$s"; then
        echo SKIP
    else
        echo INFO
    fi
}

fmt_mmss() {
    printf '%02d:%02d' $(($1 / 60)) $(($1 % 60))
}

# bytes -> "2.00 TB" (decimal units, like disk labels)
human_bytes() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1000 && i < 6) { b /= 1000; i++ }
        printf (i == 1 ? "%d %s" : "%.2f %s"), b, u[i]
    }'
}

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# float compare: fgt A B -> true when A > B
fgt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) > (b + 0)) }'
}

is_int() {
    [[ ${1-} =~ ^[0-9]+$ ]]
}
