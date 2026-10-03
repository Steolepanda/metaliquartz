#!/bin/zsh

set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 /path/to/Metaliquartz.app /path/to/composition.mquartz [duration-seconds]"
    exit 64
fi

app_path="$1"
composition_path="$2"
duration_seconds="${3:-7200}"
sample_interval=60
report_directory="$(mktemp -d "${TMPDIR%/}/MetaliquartzSoak.XXXXXX")"
report_path="$report_directory/memory.csv"

if [[ ! -x "$app_path/Contents/MacOS/Metaliquartz" ]]; then
    echo "Metaliquartz executable not found in $app_path"
    exit 66
fi
if [[ ! -d "$composition_path" ]]; then
    echo "Composition package not found at $composition_path"
    exit 66
fi

echo "elapsed_seconds,rss_kilobytes" > "$report_path"
"$app_path/Contents/MacOS/Metaliquartz" "$composition_path" &
app_pid=$!
start_seconds=$SECONDS

cleanup() {
    if kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid"
        wait "$app_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

while (( SECONDS - start_seconds < duration_seconds )); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "Metaliquartz exited before the soak test completed."
        exit 1
    fi
    elapsed=$((SECONDS - start_seconds))
    rss=$(ps -o rss= -p "$app_pid" | tr -d ' ')
    echo "$elapsed,$rss" >> "$report_path"
    sleep "$sample_interval"
done

echo "Soak report: $report_path"
