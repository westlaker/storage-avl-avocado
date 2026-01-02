#!/usr/bin/env bash
set -euo pipefail

# Uses run_sdpk.sh under the hood; expects its perf to:
#  - bind controller to uio (or whatever you use)
#  - pass --iova-mode=pa to spdk_nvme_perf (for UIO setups)
#  - restore to nvme afterwards
#
# Produces a single CSV including IOPS, BW(MB/s) and latency percentiles.

HERE="$(cd "$(dirname "$0")" && pwd)"
SPDK_SIMPLE="${SPDK_SIMPLE:-$HERE/run_spdk.sh}"

RES="$HERE/../results"; mkdir -p "$RES"

msg(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
die(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; }
ts(){ date +%Y%m%d-%H%M%S; }

usage() {
  cat <<'EOF'
Usage:
  run_spdk_stress_lantency.sh --dev /dev/nvmeXnY | --bdf 0000:BB:DD.F
                 [--time 120] [--loops 1]
                 [--rw read,randread,write,randwrite,randrw]
                 [--qd 1,4,16,32,64] [--iosize 4k,16k,128k,1m]
                 [--out DIR]
                 [--force-system] [--allow-mounted]

Output:
  <DIR or results/spdk-stress-TS>/summary.csv with columns:
  rw,qd,iosize,loop,iops,bw_MBps,lat_p50_us,lat_p90_us,lat_p99_us,lat_p999_us,dir
EOF
}

to_array() { local IFS=','; read -r -a arr <<<"$1"; printf '%s\n' "${arr[@]}"; }

# Parse a single spdk-perf.txt to IOPS/BW + latency percentiles.
# We look for:
#   - "Total ... IOPS=NNN BW=XX{KiB|MiB|GiB}/s"
#   - line containing "p50:" "p90:" "p99:" "p99.9:" tokens with values like "9.1us"
_scrape_run() {
  local logfile="$1"
  local iops="" bw="" unit="" p50="" p90="" p99="" p999=""

  # IOPS/BW
  awk '
    /Total/ && /IOPS=/ && /BW=/ {
      if (match($0,/IOPS=([0-9.]+)/,m)) iops=m[1];
      if (match($0,/BW=([0-9.]+)([KMG]?i?B)\/s/,b)) { bw=b[1]; unit=b[2]; }
      # keep last seen
      liops=iops; lbw=bw; lunit=unit
    }
    END {
      if (liops!="") {
        bwMB=lbw
        if (lunit ~ /^KiB|KB/)      bwMB = lbw/1024;
        else if (lunit ~ /^MiB|MB/) bwMB = lbw;
        else if (lunit ~ /^GiB|GB/) bwMB = lbw*1024;
        printf "IOPS=%s;BWMB=%s\n", liops, bwMB;
      }
    }
  ' "$logfile" 2>/dev/null | while IFS='=;' read -r k v rest; do
    case "$k" in
      IOPS) iops="$v" ;;
      BWMB) bw="$v" ;;
    esac
  done

  # Percentiles (scan tokens around "p50:" etc.)
  # cut commas, split into fields, grab token after the label, strip non-digits/dot, normalize to microseconds
  while IFS= read -r line; do
    echo "$line"
  done < "$logfile" \
  | tr ',' ' ' \
  | awk '
      function nstrip(x){ gsub(/[^0-9.]/,"",x); return x }
      /p50:|p90:|p99:/ {
        for (i=1;i<=NF;i++) {
          if ($i=="p50:")   { v=nstrip($(i+1)); sub(/us|ms|s/,"",$(i+1)); p50=v;  }
          if ($i=="p90:")   { v=nstrip($(i+1)); p90=v; }
          if ($i=="p99:")   { v=nstrip($(i+1)); p99=v; }
          if ($i=="p99.9:") { v=nstrip($(i+1)); p999=v; }
        }
        lp50=p50; lp90=p90; lp99=p99; lp999=p999
      }
      END {
        # print only latest captured set; units in SPDK are typically "us"
        if (lp50=="" && lp90=="" && lp99=="" && lp999=="") next
        printf "PCTS p50=%s p90=%s p99=%s p999=%s\n", lp50, lp90, lp99, lp999
      }
    ' 2>/dev/null \
  | while read -r tag rest; do
      case "$tag" in
        IOPS*) : ;;
        PCTS)
          # shell-parse p50=... p90=... p99=... p999=...
          for tok in $rest; do
            key="${tok%%=*}"; val="${tok##*=}"
            case "$key" in
              p50)  p50="$val" ;;
              p90)  p90="$val" ;;
              p99)  p99="$val" ;;
              p999) p999="$val" ;;
            esac
          done
          ;;
      esac
    done

  echo "${iops:-},${bw:-},${p50:-},${p90:-},${p99:-},${p999:-}"
}

# Replace your scrape_run() with this
scrape_run() {
  # Returns: "iops,bw_MBps,lat_p50_us,lat_p90_us,lat_p99_us,lat_p999_us"
  # Supports two SPDK output styles:
  #  A) tokens: "... IOPS=12345 BW=6789MiB/s ..."
  #  B) table:  "Total :   18172.88    2271.61   55.02  51.72  807.20"
  local logfile="$1"
  local iops="" bwMB="" unit=""
  local p50="" p90="" p99="" p999=""

  # --- Try token style first (IOPS= / BW=) ---
  if grep -q "IOPS=" "$logfile"; then
    # last Total line with tokens wins
    local line
    line="$(grep -E 'Total.*IOPS=.*BW=' "$logfile" | tail -1 || true)"
    if [ -n "$line" ]; then
      iops="$(printf "%s\n" "$line" | sed -n 's/.*IOPS=\([0-9.]\+\).*/\1/p')"
      local bwtok
      bwtok="$(printf "%s\n" "$line" | sed -n 's/.*BW=\([0-9.]\+\)\([KMG]\?i\?B\)\/s.*/\1 \2/p')"
      if [ -n "$bwtok" ]; then
        set -- $bwtok; local bw="$1"; unit="$2"
        case "$unit" in
          KiB|KB)  bwMB=$(awk -v x="$bw" 'BEGIN{printf "%.6f", x/1024}') ;;
          MiB|MB)  bwMB="$bw" ;;
          GiB|GB)  bwMB=$(awk -v x="$bw" 'BEGIN{printf "%.6f", x*1024}') ;;
          *)       bwMB="$bw" ;;
        esac
      fi
    fi
  fi

  # --- Fallback: table style "Total : <IOPS> <MiB/s> ..." ---
  if [ -z "$iops" ] || [ -z "$bwMB" ]; then
    # take numeric 1st and 2nd values after the colon on the *last* Total line
    read -r iops bwMB <<EOF
$(awk '
  /^Total[[:space:]]*:/{
    # collect numeric fields on this line
    c=0
    for (i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) vals[++c]=$i
    if (c>=2) { iops=vals[1]; mib=vals[2]; print iops, mib }
    delete vals
  }' "$logfile" | tail -1)
EOF
  fi

  # --- Latency percentiles (if present) ---
  # not in your table sample; these will stay empty
  if grep -q 'p50:' "$logfile"; then
    # pull last line that mentions p50/p90/p99/p99.9
    local pct
    pct="$(grep -E 'p50:|p90:|p99:' "$logfile" | tail -1 || true)"
    if [ -n "$pct" ]; then
      p50="$(printf "%s\n" "$pct" | sed -n 's/.*p50:[[:space:]]*\([0-9.]\+\).*/\1/p')"
      p90="$(printf "%s\n" "$pct" | sed -n 's/.*p90:[[:space:]]*\([0-9.]\+\).*/\1/p')"
      p99="$(printf "%s\n" "$pct" | sed -n 's/.*p99:[[:space:]]*\([0-9.]\+\).*/\1/p')"
      p999="$(printf "%s\n" "$pct" | sed -n 's/.*p99\.9:[[:space:]]*\([0-9.]\+\).*/\1/p')"
    fi
  fi

  echo "${iops:-},${bwMB:-},${p50:-},${p90:-},${p99:-},${p999:-}"
}

# ------------ main ------------
dev=""; bdf=""; duration=120; loops=1; out=""
rw_csv="read,randread,write,randwrite,randrw"
qd_csv="1,4,16,32,64"
ios_csv="4k,16k,128k,1m"
force_system=0; allow_mounted=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) dev="$2"; shift 2;;
    --bdf) bdf="$2"; shift 2;;
    --time) duration="$2"; shift 2;;
    --loops) loops="$2"; shift 2;;
    --rw) rw_csv="$2"; shift 2;;
    --qd) qd_csv="$2"; shift 2;;
    --iosize) ios_csv="$2"; shift 2;;
    --out) out="$2"; shift 2;;
    --force-system) force_system=1; shift;;
    --allow-mounted) allow_mounted=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[ -x "$SPDK_SIMPLE" ] || die "run_sdpk.sh not found/executable at: $SPDK_SIMPLE"
if [ -z "$dev" ] && [ -z "$bdf" ]; then die "Provide --dev or --bdf"; fi

tsdir="${out:-$RES/spdk-stress-$(ts)}"
mkdir -p "$tsdir"
summary="$tsdir/summary.csv"
echo "rw,qd,iosize,loop,iops,bw_MBps,lat_p50_us,lat_p90_us,lat_p99_us,lat_p999_us,dir" > "$summary"

mapfile -t rws < <(to_array "$rw_csv")
mapfile -t qds < <(to_array "$qd_csv")
mapfile -t ios < <(to_array "$ios_csv")

for rw in "${rws[@]}"; do
  for qd in "${qds[@]}"; do
    for io in "${ios[@]}"; do
      for ((lp=1; lp<=loops; lp++)); do
        tag="rw${rw}-qd${qd}-o${io}-l${lp}"
        rundir="$tsdir/$tag"
        mkdir -p "$rundir"

        msg "Run $tag: $([ -n "$dev" ] && echo "--dev $dev" || echo "--bdf $bdf")  rw=$rw qd=$qd iosize=$io t=$duration"
        if [ -n "$dev" ]; then
          sudo "$SPDK_SIMPLE" perf --dev "$dev" \
            --rw "$rw" --qd "$qd" --iosize "$io" --time "$duration" \
            --out "$rundir" $([ $force_system -eq 1 ] && echo --force-system) $([ $allow_mounted -eq 1 ] && echo --allow-mounted)
        else
          sudo "$SPDK_SIMPLE" perf --bdf "$bdf" \
            --rw "$rw" --qd "$qd" --iosize "$io" --time "$duration" \
            --out "$rundir" $([ $force_system -eq 1 ] && echo --force-system) $([ $allow_mounted -eq 1 ] && echo --allow-mounted)
        fi

        log="$rundir/spdk-perf.txt"
        if [ -f "$log" ]; then
          kv="$(scrape_run "$log" || true)"
          if [ -n "$kv" ]; then
            IFS=',' read -r IOPS BW P50 P90 P99 P999 <<< "$kv"
            echo "$rw,$qd,$io,$lp,$IOPS,$BW,$P50,$P90,$P99,$P999,$rundir" >> "$summary"
          else
            echo "$rw,$qd,$io,$lp,,,,,,$rundir" >> "$summary"
          fi
        else
          echo "$rw,$qd,$io,$lp,,,,,,$rundir" >> "$summary"
        fi
      done
    done
  done
done

msg "Done. Summary -> $summary"

