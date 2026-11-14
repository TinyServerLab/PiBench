#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  PiBench runner — TinyServerLab
#  Benchmarks the Raspberry Pi's ROOT disk (SD card / NVMe) plus real-world
#  workloads, saves a JSON result file, and (optionally) uploads it to the
#  PiBench dashboard.
#
#  Usage:  sudo ./pibench-run.sh --label sd-card [--notes "..."] [--quick]
#          sudo ./pibench-run.sh --upload results/<file>.json
#          ./pibench-run.sh --help
# ---------------------------------------------------------------------------
set -uo pipefail

PIBENCH_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Optional config file next to the script (token, URL, container names ...)
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/pibench.env" ]] && source "$SCRIPT_DIR/pibench.env"

# ---- defaults (override in pibench.env or with flags) ----------------------
LABEL=""
NOTES=""
ITERATIONS="${PIBENCH_ITERATIONS:-3}"
FIO_RUNTIME="${PIBENCH_FIO_RUNTIME:-20}"      # seconds per fio test
FIO_SIZE="${PIBENCH_FIO_SIZE:-1G}"            # test file size
PGBENCH_TIME="${PIBENCH_PGBENCH_TIME:-30}"    # seconds per pgbench run
SMALLFILES_COUNT="${PIBENCH_SMALLFILES_COUNT:-5000}"
URL="${PIBENCH_URL:-http://127.0.0.1:8095/pibench}"
TOKEN="${PIBENCH_TOKEN:-}"
OUT_DIR="${PIBENCH_OUT:-$SCRIPT_DIR/results}"
PG_CONTAINER="${PIBENCH_PG_CONTAINER:-shared-postgres}"
PG_ADMIN_USER="${PIBENCH_PG_ADMIN_USER:-postgres}"
PG_ADMIN_PASSWORD="${PIBENCH_PG_ADMIN_PASSWORD:-}"
BENCH_URLS="${PIBENCH_URLS:-}"                         # space separated
RESTART_CONTAINERS="${PIBENCH_RESTART_CONTAINERS:-}"   # space separated, opt-in
SKIP="${PIBENCH_SKIP:-}"                               # comma list
UPLOAD_FILE=""
NO_UPLOAD=0
PGBENCH_DB="pibench_pgbench_db"   # throwaway DB, created and dropped by this script

usage() {
  cat <<EOF
PiBench runner v$PIBENCH_VERSION

  sudo $0 --label <name> [options]     run the benchmark suite
  sudo $0 --upload <file.json>         upload a saved result to the dashboard

Options:
  --label NAME       run label, e.g. sd-card | nvme-gen2 | nvme-gen3   (required)
  --notes TEXT       free-text notes shown on the dashboard
  --quick            1 iteration, 10 s fio tests, 15 s pgbench (~4 min)
  --iterations N     repeat each test N times, median is reported (default $ITERATIONS)
  --skip LIST        comma list of: fio,hdparm,boot,smallfiles,docker,pgbench,urls,cpu
  --no-upload        only save the JSON file
  --url URL          dashboard base URL (default $URL)
  --token TOKEN      dashboard ingest token (or PIBENCH_TOKEN in pibench.env)
  -h, --help         this help

Results are always saved to: $OUT_DIR
EOF
}

# ---- args -------------------------------------------------------------------
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --quick) ITERATIONS=1; FIO_RUNTIME=10; PGBENCH_TIME=15; shift ;;
    --iterations) ITERATIONS="${2:-3}"; shift 2 ;;
    --skip) SKIP="${2:-}"; shift 2 ;;
    --no-upload) NO_UPLOAD=1; shift ;;
    --upload) UPLOAD_FILE="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
URL="${URL%/}"

# ---- helpers ------------------------------------------------------------------
c_cyan=$'\033[1;36m'; c_green=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { printf '%s▶%s %s\n' "$c_cyan" "$c_off" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "$c_green" "$c_off" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s✖ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
skipped() { [[ ",$SKIP," == *",$1,"* ]]; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }
median() { sort -g | awk '{a[NR]=$1} END{ if(NR==0){print ""; exit} if(NR%2){printf "%.2f\n", a[(NR+1)/2]} else {printf "%.2f\n",(a[NR/2]+a[NR/2+1])/2} }'; }
drop_caches() { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; }

MFILE=""
# record <key> <sample> [sample ...]  -> stores median + raw samples
record() {
  local key="$1"; shift
  local samples=() s
  for s in "$@"; do [[ "$s" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] && samples+=("$(awk -v x="$s" 'BEGIN{printf "%.2f", x}')"); done
  if [[ ${#samples[@]} -eq 0 ]]; then warn "$key: no valid samples"; return; fi
  local med; med=$(printf '%s\n' "${samples[@]}" | median)
  printf '%s\t%s\t%s\n' "$key" "$med" "${samples[*]}" >> "$MFILE"
  ok "$(printf '%-30s %s' "$key" "$med")  ${c_dim}(${samples[*]})${c_off}"
}

upload() {
  local file="$1"
  [[ -f "$file" ]] || die "File not found: $file"
  [[ -n "$TOKEN" ]] || { warn "No PIBENCH_TOKEN set — skipping upload. Later run: $0 --upload $file"; return 1; }
  log "Uploading $(basename "$file") to $URL"
  local code
  code=$(curl -sS -o /tmp/pibench-upload.out -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary @"$file" "$URL/api/runs" 2>/dev/null) || code="000"
  if [[ "$code" == "201" ]]; then
    ok "Uploaded (run id $(jq -r '.id' /tmp/pibench-upload.out 2>/dev/null))"
    return 0
  fi
  warn "Upload failed (HTTP $code): $(head -c 300 /tmp/pibench-upload.out 2>/dev/null)"
  warn "Your result is safe in $file — retry later with: $0 --upload $file"
  return 1
}

# ---- upload-only mode (no root needed) -----------------------------------------
if [[ -n "$UPLOAD_FILE" ]]; then
  have jq || die "jq is required (sudo apt install -y jq)"
  upload "$UPLOAD_FILE"; exit $?
fi

[[ -n "$LABEL" ]] || { usage; die "--label is required (e.g. sd-card, nvme-gen2, nvme-gen3)"; }
[[ "$LABEL" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "Label may only contain letters, digits, . _ - (max 64)"

# ---- need root for direct I/O, drop_caches, hdparm ------------------------------
if [[ $EUID -ne 0 ]]; then
  log "Re-running with sudo ..."
  exec sudo -E "$0" "${ORIG_ARGS[@]}"
fi

missing=()
for t in fio jq curl findmnt lsblk awk; do have "$t" || missing+=("$t"); done
[[ ${#missing[@]} -eq 0 ]] || die "Missing tools: ${missing[*]}  ->  sudo apt install -y fio jq curl util-linux"
skipped hdparm || have hdparm || { warn "hdparm not installed — skipping (sudo apt install -y hdparm)"; SKIP="$SKIP,hdparm"; }
skipped cpu || have sysbench || { warn "sysbench not installed — skipping CPU control test (sudo apt install -y sysbench)"; SKIP="$SKIP,cpu"; }

# ---- workspace on the ROOT filesystem ------------------------------------------
WORK="/var/tmp/pibench-$$"
mkdir -p "$WORK" "$OUT_DIR"
MFILE="$WORK/metrics.tsv"; : > "$MFILE"
TFILE="$WORK/temps.tsv";   : > "$TFILE"
SAMPLER_PID=""
cleanup() {
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
    pg_exec psql -U "$PG_ADMIN_USER" -d postgres -qtAc "DROP DATABASE IF EXISTS $PGBENCH_DB" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK" /dev/shm/pibench-src-$$ 2>/dev/null
}
trap cleanup EXIT
trap 'echo; die "Interrupted"' INT TERM

pg_exec() {
  if [[ -n "$PG_ADMIN_PASSWORD" ]]; then docker exec -e PGPASSWORD="$PG_ADMIN_PASSWORD" "$PG_CONTAINER" "$@"
  else docker exec "$PG_CONTAINER" "$@"; fi
}

# ---- system info -----------------------------------------------------------------
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_FS=$(findmnt -no FSTYPE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
[[ -z "$ROOT_DISK" ]] && ROOT_DISK=$(basename "$ROOT_SRC")
[[ "$(findmnt -no SOURCE -T /var/tmp)" == "$ROOT_SRC" ]] || warn "/var/tmp is not on the root filesystem — results may not reflect the root disk"

DISK_MODEL=$(lsblk -dno MODEL "/dev/$ROOT_DISK" 2>/dev/null | xargs)
[[ -z "$DISK_MODEL" && -r "/sys/block/$ROOT_DISK/device/name" ]] && DISK_MODEL="SD $(cat "/sys/block/$ROOT_DISK/device/name")"
DISK_SIZE=$(lsblk -dno SIZE "/dev/$ROOT_DISK" 2>/dev/null | xargs)
case "$ROOT_DISK" in
  mmcblk*) DISK_TYPE="sd-card" ;;
  nvme*)   DISK_TYPE="nvme" ;;
  sd*)     DISK_TYPE="usb/sata" ;;
  *)       DISK_TYPE="unknown" ;;
esac

PCIE_SPEED=""; PCIE_GEN=""; PCIE_WIDTH=""
if [[ "$DISK_TYPE" == "nvme" ]]; then
  ctrl=$(basename "$(readlink -f "/sys/block/$ROOT_DISK/device" 2>/dev/null)" 2>/dev/null)
  for f in "/sys/class/nvme/$ctrl/device/current_link_speed" /sys/class/nvme/nvme0/device/current_link_speed; do
    [[ -r "$f" ]] && { PCIE_SPEED=$(cat "$f"); PCIE_WIDTH=$(cat "$(dirname "$f")/current_link_width" 2>/dev/null); break; }
  done
  case "$PCIE_SPEED" in
    2.5*) PCIE_GEN=1 ;; 5.0*) PCIE_GEN=2 ;; 8.0*) PCIE_GEN=3 ;; 16.0*) PCIE_GEN=4 ;;
  esac
fi
PCIE_CONFIG=$(grep -hE '^\s*dtparam=pciex1' /boot/firmware/config.txt /boot/config.txt 2>/dev/null | xargs)

if [[ -r /proc/device-tree/model ]]; then MODEL=$(tr -d '\0' < /proc/device-tree/model); else MODEL="$(uname -m) (not a Raspberry Pi?)"; fi
OS_NAME=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
CONTAINERS_RUNNING=$(docker ps -q 2>/dev/null | wc -l | xargs)

cpu_temp() {
  if have vcgencmd; then vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
  elif [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp
  fi
}
NVME_HWMON=""
for h in /sys/class/hwmon/hwmon*; do [[ "$(cat "$h/name" 2>/dev/null)" == "nvme" ]] && { NVME_HWMON="$h"; break; }; done
nvme_temp() { [[ -n "$NVME_HWMON" && -r "$NVME_HWMON/temp1_input" ]] && awk '{printf "%.1f", $1/1000}' "$NVME_HWMON/temp1_input"; }
throttled() { have vcgencmd && vcgencmd get_throttled 2>/dev/null | cut -d= -f2; }

echo >&2
printf '%s PiBench v%s %s — label: %s%s%s\n' "$c_cyan━━━" "$PIBENCH_VERSION" "━━━$c_off" "$c_green" "$LABEL" "$c_off" >&2
printf '  Device : %s  (%s MB RAM)\n  OS     : %s / %s\n  Root   : %s (%s, %s) — %s %s\n' \
  "$MODEL" "$RAM_MB" "$OS_NAME" "$(uname -r)" "/dev/$ROOT_DISK" "$DISK_TYPE" "$ROOT_FS" "${DISK_MODEL:-?}" "${DISK_SIZE:-}" >&2
[[ -n "$PCIE_SPEED" ]] && printf '  PCIe   : %s x%s (Gen %s)  config: %s\n' "$PCIE_SPEED" "${PCIE_WIDTH:-?}" "${PCIE_GEN:-?}" "${PCIE_CONFIG:-default}" >&2
printf '  Runs   : %s iteration(s), fio %ss x %s, pgbench %ss, %s containers running\n\n' "$ITERATIONS" "$FIO_RUNTIME" "$FIO_SIZE" "$PGBENCH_TIME" "$CONTAINERS_RUNNING" >&2

LOAD1=$(cut -d' ' -f1 /proc/loadavg)
awk -v l="$LOAD1" 'BEGIN{exit !(l>1.5)}' && warn "Load average is $LOAD1 — stop busy containers for a fairer result"

THROTTLED_START=$(throttled)
CPU_TEMP_IDLE=$(cpu_temp)
NVME_TEMP_IDLE=$(nvme_temp)

# background temperature sampler (every 2 s)
( while true; do printf '%s\t%s\n' "$(cpu_temp)" "$(nvme_temp)" >> "$TFILE"; sleep 2; done ) &
SAMPLER_PID=$!
START_TS=$(now)

# ---- 1. boot time (of the current boot) -------------------------------------------------
to_seconds() { awk '{t=0; for(i=1;i<=NF;i++){v=$i; if(v~/ms$/){sub(/ms$/,"",v);t+=v/1000} else if(v~/min$/){sub(/min$/,"",v);t+=v*60} else if(v~/h$/){sub(/h$/,"",v);t+=v*3600} else if(v~/s$/){sub(/s$/,"",v);t+=v}} printf "%.3f\n",t}'; }
if ! skipped boot && have systemd-analyze; then
  log "Boot time (current boot — reboot before running for a clean number)"
  bt=$(systemd-analyze time 2>/dev/null | head -1)
  if [[ "$bt" == *"="* ]]; then
    record boot_total_s "$(sed -n 's/.*= \(.*\)$/\1/p' <<<"$bt" | to_seconds)"
    us=$(grep -oE '[0-9][0-9.a-z ]*\(userspace\)' <<<"$bt" | sed 's/(userspace)//')
    [[ -n "$us" ]] && record boot_userspace_s "$(to_seconds <<<"$us")"
  else
    warn "systemd-analyze: boot not finished or unavailable"
  fi
fi

# ---- 2. fio ------------------------------------------------------------------------
fio_job() { # name rw bs iodepth
  fio --name="$1" --filename="$WORK/fio.dat" --size="$FIO_SIZE" --rw="$2" --bs="$3" --iodepth="$4" \
      --ioengine=libaio --direct=1 --runtime="$FIO_RUNTIME" --time_based --ramp_time=2 \
      --group_reporting --output-format=json 2>/dev/null
}
if ! skipped fio; then
  log "Preparing $FIO_SIZE fio test file on the root disk ..."
  fio --name=prep --filename="$WORK/fio.dat" --size="$FIO_SIZE" --rw=write --bs=1M --direct=1 \
      --ioengine=libaio --iodepth=4 --output-format=json >/dev/null 2>&1 || warn "fio prep failed"
  declare -A FS=()
  for ((i=1; i<=ITERATIONS; i++)); do
    log "fio iteration $i/$ITERATIONS (6 tests x ${FIO_RUNTIME}s)"
    j=$(fio_job seqread  read      1M 4);  FS[seq_read]+="$(jq '.jobs[0].read.bw_bytes/1000000'  <<<"$j" 2>/dev/null) "
    j=$(fio_job seqwrite write     1M 4);  FS[seq_write]+="$(jq '.jobs[0].write.bw_bytes/1000000' <<<"$j" 2>/dev/null) "
    j=$(fio_job rr32     randread  4k 32); FS[rr32]+="$(jq '.jobs[0].read.iops'  <<<"$j" 2>/dev/null) "
    j=$(fio_job rw32     randwrite 4k 32); FS[rw32]+="$(jq '.jobs[0].write.iops' <<<"$j" 2>/dev/null) "
    j=$(fio_job rr1      randread  4k 1);  FS[rr1]+="$(jq '.jobs[0].read.iops'  <<<"$j" 2>/dev/null) "
                                           FS[rr1lat]+="$(jq '.jobs[0].read.clat_ns.mean/1000' <<<"$j" 2>/dev/null) "
    j=$(fio_job rw1      randwrite 4k 1);  FS[rw1]+="$(jq '.jobs[0].write.iops' <<<"$j" 2>/dev/null) "
  done
  # shellcheck disable=SC2086
  {
    record fio_seq_read_mbps          ${FS[seq_read]}
    record fio_seq_write_mbps         ${FS[seq_write]}
    record fio_rand4k_read_qd32_iops  ${FS[rr32]}
    record fio_rand4k_write_qd32_iops ${FS[rw32]}
    record fio_rand4k_read_qd1_iops   ${FS[rr1]}
    record fio_rand4k_read_qd1_lat_us ${FS[rr1lat]}
    record fio_rand4k_write_qd1_iops  ${FS[rw1]}
  }
  rm -f "$WORK/fio.dat"
fi

# ---- 3. hdparm ------------------------------------------------------------------------
if ! skipped hdparm; then
  log "hdparm buffered read (/dev/$ROOT_DISK)"
  hs=()
  for ((i=1; i<=ITERATIONS; i++)); do
    drop_caches
    hs+=("$(hdparm -t --direct "/dev/$ROOT_DISK" 2>/dev/null | grep -oE '[0-9.]+ MB/sec' | awk '{print $1}')")
  done
  record hdparm_read_mbps "${hs[@]}"
fi

# ---- 4. small files (the 'feels snappy' test) -----------------------------------------
if ! skipped smallfiles; then
  log "Small files: write / cold read / delete $SMALLFILES_COUNT x 4 KB"
  SRC="/dev/shm/pibench-src-$$"; mkdir -p "$SRC"
  head -c $((SMALLFILES_COUNT*4096)) /dev/urandom | (cd "$SRC" && split -b 4096 -a 5 - f)
  tar -C "$SRC" -cf "/dev/shm/pibench-src-$$.tar" . && rm -rf "$SRC"
  sw=(); sr=(); sd=()
  for ((i=1; i<=ITERATIONS; i++)); do
    d="$WORK/small"; drop_caches
    t0=$(now); mkdir -p "$d" && tar -C "$d" -xf "/dev/shm/pibench-src-$$.tar" && sync; t1=$(now)
    sw+=("$(elapsed "$t0" "$t1")")
    drop_caches
    t0=$(now); tar -C "$d" -cf - . > /dev/null; t1=$(now)
    sr+=("$(elapsed "$t0" "$t1")")
    t0=$(now); rm -rf "$d" && sync; t1=$(now)
    sd+=("$(elapsed "$t0" "$t1")")
  done
  rm -f "/dev/shm/pibench-src-$$.tar"
  record smallfiles_write_s  "${sw[@]}"
  record smallfiles_read_s   "${sr[@]}"
  record smallfiles_delete_s "${sd[@]}"
fi

# ---- 5. docker -----------------------------------------------------------------------
if ! skipped docker && have docker && docker info >/dev/null 2>&1; then
  log "Docker: container start latency"
  IMG="alpine:3.20"
  docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    ds=()
    for ((i=1; i<=ITERATIONS+2; i++)); do
      t0=$(now); docker run --rm "$IMG" true >/dev/null 2>&1; t1=$(now); ds+=("$(elapsed "$t0" "$t1")")
    done
    record docker_run_s "${ds[@]}"
  else
    warn "Could not pull $IMG — skipping container start test"
  fi
  if [[ -n "$RESTART_CONTAINERS" ]]; then
    log "Docker: restarting containers: $RESTART_CONTAINERS"
    # shellcheck disable=SC2086
    t0=$(now); docker restart $RESTART_CONTAINERS >/dev/null 2>&1; t1=$(now)
    record docker_restart_s "$(elapsed "$t0" "$t1")"
  fi
fi

# ---- 6. pgbench on the shared PostgreSQL (throwaway DB) -----------------------------------
if ! skipped pgbench && have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
  log "PostgreSQL pgbench in '$PG_CONTAINER' (throwaway DB $PGBENCH_DB, dropped afterwards)"
  if pg_exec psql -U "$PG_ADMIN_USER" -d postgres -qtAc "DROP DATABASE IF EXISTS $PGBENCH_DB" >/dev/null 2>&1 &&
     pg_exec psql -U "$PG_ADMIN_USER" -d postgres -qtAc "CREATE DATABASE $PGBENCH_DB" >/dev/null 2>&1; then
    t0=$(now); pg_exec pgbench -U "$PG_ADMIN_USER" -i -s 20 -q "$PGBENCH_DB" >/dev/null 2>&1; t1=$(now)
    record pgbench_init_s "$(elapsed "$t0" "$t1")"
    pt=(); ps=()
    for ((i=1; i<=ITERATIONS; i++)); do
      pt+=("$(pg_exec pgbench -U "$PG_ADMIN_USER" -c 8 -j 4 -T "$PGBENCH_TIME" "$PGBENCH_DB" 2>/dev/null | grep -m1 -oE 'tps = [0-9.]+' | awk '{print $3}')")
      ps+=("$(pg_exec pgbench -U "$PG_ADMIN_USER" -S -c 8 -j 4 -T 10 "$PGBENCH_DB" 2>/dev/null | grep -m1 -oE 'tps = [0-9.]+' | awk '{print $3}')")
    done
    record pgbench_tps        "${pt[@]}"
    record pgbench_select_tps "${ps[@]}"
    pg_exec psql -U "$PG_ADMIN_USER" -d postgres -qtAc "DROP DATABASE IF EXISTS $PGBENCH_DB" >/dev/null 2>&1
  else
    warn "Could not create $PGBENCH_DB as '$PG_ADMIN_USER' — set PIBENCH_PG_ADMIN_USER / _PASSWORD in pibench.env"
  fi
elif ! skipped pgbench; then
  warn "PostgreSQL container '$PG_CONTAINER' not running — skipping pgbench (set PIBENCH_PG_CONTAINER)"
fi

# ---- 7. page load latency of your apps -----------------------------------------------------
if ! skipped urls && [[ -n "$BENCH_URLS" ]]; then
  log "App response time"
  for u in $BENCH_URLS; do
    us=()
    curl -s -o /dev/null "$u" >/dev/null 2>&1   # warm-up
    for ((i=1; i<=5; i++)); do
      us+=("$(curl -s -o /dev/null -w '%{time_total}' "$u" 2>/dev/null | awk '{printf "%.1f", $1*1000}')")
    done
    record "url_ms:$u" "${us[@]}"
  done
fi

# ---- 8. CPU control test (should NOT change — proves a fair comparison) ----------------------
if ! skipped cpu; then
  log "CPU control test (sysbench, 4 threads)"
  cs=()
  for ((i=1; i<=ITERATIONS; i++)); do
    cs+=("$(sysbench cpu --threads=4 --time=10 run 2>/dev/null | awk -F: '/events per second/{gsub(/ /,"",$2); print $2}')")
  done
  record cpu_sysbench_eps "${cs[@]}"
fi

# ---- thermals ------------------------------------------------------------------------
kill "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""
END_TS=$(now)
[[ -n "$CPU_TEMP_IDLE" ]] && record cpu_temp_idle_c "$CPU_TEMP_IDLE"
mx=$(awk -F'\t' '$1!=""{if($1>m)m=$1} END{if(m!="")print m}' "$TFILE"); [[ -n "$mx" ]] && record cpu_temp_max_c "$mx"
[[ -n "$NVME_TEMP_IDLE" ]] && record nvme_temp_idle_c "$NVME_TEMP_IDLE"
mx=$(awk -F'\t' '$2!=""{if($2>m)m=$2} END{if(m!="")print m}' "$TFILE"); [[ -n "$mx" ]] && record nvme_temp_max_c "$mx"
THROTTLED_END=$(throttled)
[[ -n "$THROTTLED_END" && "$THROTTLED_END" != "0x0" ]] && warn "Throttling flags set: $THROTTLED_END — check power supply / cooling"

# ---- build JSON ------------------------------------------------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT_FILE="$OUT_DIR/$(date +%Y%m%d-%H%M%S)_${LABEL}.json"
jq -Rn \
  --arg label "$LABEL" --arg notes "$NOTES" --arg ts "$TS" --arg ver "$PIBENCH_VERSION" \
  --arg model "$MODEL" --arg os "$OS_NAME" --arg kernel "$(uname -r)" --arg host "$(hostname)" \
  --arg ram "$RAM_MB" --arg root_disk "/dev/$ROOT_DISK" --arg root_src "$ROOT_SRC" --arg fs "$ROOT_FS" \
  --arg dtype "$DISK_TYPE" --arg dmodel "$DISK_MODEL" --arg dsize "$DISK_SIZE" \
  --arg pspeed "$PCIE_SPEED" --arg pgen "$PCIE_GEN" --arg pwidth "$PCIE_WIDTH" --arg pcfg "$PCIE_CONFIG" \
  --arg thr0 "${THROTTLED_START:-}" --arg thr1 "${THROTTLED_END:-}" --arg cont "$CONTAINERS_RUNNING" \
  --arg iters "$ITERATIONS" --arg fiort "$FIO_RUNTIME" --arg fiosz "$FIO_SIZE" --arg pgt "$PGBENCH_TIME" \
  --arg dur "$(elapsed "$START_TS" "$END_TS")" --arg fiov "$(fio --version 2>/dev/null)" '
  def num: (try tonumber catch null);
  def nz: if . == "" then null else . end;
  [inputs | split("\t") | {k: .[0], v: (.[1]|num), s: ((.[2] // "") | split(" ") | map(num) | map(select(. != null)))}] as $rows
  | {
      label: $label, notes: ($notes|nz), captured_at: $ts, pibench_version: $ver,
      system: {
        model: $model, os: $os, kernel: $kernel, hostname: $host, ram_mb: ($ram|num),
        root_disk: $root_disk, root_source: $root_src, filesystem: $fs,
        disk_type: $dtype, disk_model: ($dmodel|nz), disk_size: ($dsize|nz),
        pcie_link_speed: ($pspeed|nz), pcie_gen: ($pgen|num), pcie_width: ($pwidth|num), pcie_config: ($pcfg|nz),
        throttled_start: ($thr0|nz), throttled_end: ($thr1|nz), containers_running: ($cont|num),
        fio_version: ($fiov|nz)
      },
      settings: { iterations: ($iters|num), fio_runtime_s: ($fiort|num), fio_size: $fiosz,
                  pgbench_time_s: ($pgt|num), duration_s: ($dur|num) },
      metrics: ($rows | map({key: .k, value: .v}) | from_entries),
      samples: ($rows | map({key: .k, value: .s}) | from_entries)
    }' < "$MFILE" > "$OUT_FILE" || die "Failed to write JSON"

[[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER": "$OUT_DIR" 2>/dev/null
echo >&2
printf '%s━━━ Done in %ss ━━━%s\n' "$c_green" "$(elapsed "$START_TS" "$END_TS" | cut -d. -f1)" "$c_off" >&2
printf '  Saved: %s\n' "$OUT_FILE" >&2

[[ $NO_UPLOAD -eq 1 ]] || upload "$OUT_FILE" || true
exit 0
