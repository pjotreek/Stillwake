#!/bin/zsh
set -euo pipefail

label="${1:?usage: powertest.sh <label> [seconds]}"
seconds="${2:-120}"
results="$HOME/Desktop/stillwake-power.txt"
samples=$(mktemp)

echo "Close the lid within 15 s. Measuring '$label' for $seconds s after that."
sleep 15

end=$((SECONDS + seconds))
while (( SECONDS < end )); do
    ioreg -rn AppleSmartBattery | grep -oE '"SystemLoad"=[0-9]+' | head -1 | cut -d= -f2 >> "$samples"
    sleep 2
done

summary=$(awk -v label="$label" '{ sum += $1; n++; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
    END { if (n) printf "%-14s mean %.2f W  min %.2f W  max %.2f W  (%d samples)\n", label, sum / n / 1000, min / 1000, max / 1000, n }' "$samples")
rm -f "$samples"
echo "$summary" | tee -a "$results"
afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
