#!/usr/bin/env bash
#
# splash-top.sh — colorful, htop-style terminal monitor for Inco AI's Splash
#
# A CLI reimplementation of the core functionality of SplashMonitor
# (https://github.com/hometrix/SplashMonitor): it polls
# GET http://127.0.0.1:<port>/status (with an optional API key) and renders
# the values formatted, colorized and live-updating.
#
# Dependencies: bash, curl, jq
#
# Usage:
#   ./splash-top.sh              # Auto-detect, live (htop-style)
#   ./splash-top.sh -p 8090      # Force a specific port
#   ./splash-top.sh -k KEY       # Splash API key (otherwise $SPLASH_API_KEY)
#   ./splash-top.sh -i 0.5       # Poll interval in seconds (default 1.5)
#   ./splash-top.sh -1           # Print once instead of a live loop
#   ./splash-top.sh -N           # Disable colors
#   ./splash-top.sh -v           # Debug output for port/auth detection
#

set -uo pipefail

# Force a dot as the decimal separator for printf/awk, regardless of the
# system locale.
unset LC_ALL
export LC_NUMERIC=C

# ---------- Defaults ----------
INTERVAL=1.5
FORCE_PORT=""
ONCE=0
VERBOSE=0
NOCOLOR=0
API_KEY="${SPLASH_API_KEY:-}"
LOCK_FILE="${HOME}/Library/Application Support/Splash/runtime/serve.lock"
FALLBACK_PORTS=(8000 8001 8005 8008 8080 8088 8888 9000 9005)

while getopts "p:i:k:1vNh" opt; do
  case "$opt" in
    p) FORCE_PORT="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    1) ONCE=1 ;;
    v) VERBOSE=1 ;;
    N) NOCOLOR=1 ;;
    h)
      cat <<EOF
Usage: $0 [-p port] [-i interval_seconds] [-k api_key] [-1] [-v] [-N]

  -p PORT   force a specific port (instead of auto-detection)
  -i SEC    poll interval in seconds (default 1.5)
  -k KEY    Splash API key (otherwise \$SPLASH_API_KEY from the environment)
  -1        print once instead of a live loop
  -N        disable colors
  -v        debug output for port/auth detection
EOF
      exit 0
      ;;
    *) exit 1 ;;
  esac
done

dbg() {
  [[ "$VERBOSE" == "1" ]] && echo "[debug] $*" >&2
}

# ---------- Dependencies ----------
for bin in curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: '$bin' is required but not installed." >&2
    exit 1
  fi
done

# ---------- Colors ----------
RESET="" BOLD="" DIM="" ITAL=""
TITLE="" ACCENT="" ACCENT2="" LABEL="" VALUE="" MUTED=""
OK="" WARN="" CRIT="" BORDER="" HEADER_BG=""

init_colors() {
  [[ "$NOCOLOR" == "1" ]] && return
  [[ -n "${NO_COLOR:-}" ]] && return
  [[ -t 1 ]] || return

  local ncolors
  ncolors=$(tput colors 2>/dev/null || echo 0)

  RESET=$'\e[0m'
  BOLD=$'\e[1m'
  DIM=$'\e[2m'
  ITAL=$'\e[3m'

  if (( ncolors >= 256 )); then
    TITLE=$'\e[1;38;5;51m'
    ACCENT=$'\e[38;5;45m'
    ACCENT2=$'\e[38;5;213m'
    LABEL=$'\e[38;5;110m'
    VALUE=$'\e[1;38;5;255m'
    MUTED=$'\e[38;5;240m'
    OK=$'\e[38;5;78m'
    WARN=$'\e[38;5;214m'
    CRIT=$'\e[1;38;5;203m'
    BORDER=$'\e[38;5;24m'
    HEADER_BG=$'\e[48;5;24m\e[1;38;5;231m'
  elif (( ncolors >= 8 )); then
    TITLE=$'\e[1;36m'
    ACCENT=$'\e[36m'
    ACCENT2=$'\e[35m'
    LABEL=$'\e[34m'
    VALUE=$'\e[1;37m'
    MUTED=$'\e[90m'
    OK=$'\e[32m'
    WARN=$'\e[33m'
    CRIT=$'\e[1;31m'
    BORDER=$'\e[34m'
    HEADER_BG=$'\e[44m\e[1;37m'
  fi
}

init_colors

# ---------- Terminal ----------
term_cols() {
  tput cols 2>/dev/null || echo 80
}

WIDTH=74
LAST_TERM_COLS=0

resize_width() {
  local c
  c=$(term_cols)

  if (( c - 2 < WIDTH )); then
    WIDTH=$(( c > 40 ? c - 2 : 40 ))
  else
    WIDTH=74
  fi

  LAST_TERM_COLS="$c"
}

repeat_char() {
  local ch="$1"
  local n="$2"
  local out=""
  local i

  for ((i=0; i<n; i++)); do
    out+="$ch"
  done

  printf '%s' "$out"
}

hline() {
  printf '%s%s%s\n' \
    "$BORDER" \
    "$(repeat_char "$1" "$WIDTH")" \
    "$RESET"
}

pad_line() {
  local content="$1"
  local visible
  visible=$(printf '%s' "$content" | sed -E 's/\x1b\[[0-9;]*m//g')

  local vislen=${#visible}
  local padlen=$(( WIDTH - vislen ))

  (( padlen < 0 )) && padlen=0

  printf '%s%s\n' \
    "$content" \
    "$(repeat_char ' ' "$padlen")"
}

section_title() {
  printf '%s %s%s%s\n' \
    "$1" \
    "${BOLD}${ACCENT}" \
    "$2" \
    "$RESET"
}

# ---------- Process/Port detection ----------
discover_ports_via_process() {
  command -v lsof >/dev/null 2>&1 || return

  local pids
  pids=$(pgrep -f '[s]plash serve' 2>/dev/null)
  [[ -z "$pids" ]] && pids=$(pgrep -x splash 2>/dev/null)
  [[ -z "$pids" ]] && return

  local p

  for p in $pids; do
    lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk 'NR>1 {n=split($9,a,":"); print a[n]}'
  done | sort -u
}

LAST_PORT=""

read_lock_file() {
  LOCK_PID=""
  LOCK_PORT=""
  LOCK_MODEL=""

  if [[ -f "$LOCK_FILE" ]]; then
    local json
    json=$(cat "$LOCK_FILE" 2>/dev/null) || return

    LOCK_PID=$(jq -r '.pid // empty' <<<"$json" 2>/dev/null)
    LOCK_PORT=$(jq -r '.port // empty' <<<"$json" 2>/dev/null)
    LOCK_MODEL=$(jq -r '.model // empty' <<<"$json" 2>/dev/null)

    if [[ -n "$LOCK_PID" ]] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
      rm -f "$LOCK_FILE" 2>/dev/null
      LOCK_PID=""
      LOCK_PORT=""
      LOCK_MODEL=""
    fi
  fi
}

try_status() {
  local port="$1"

  local -a curl_args=(
    -s
    -m 1
    -o -
    -w '\n%{http_code}'
  )

  if [[ -n "$API_KEY" ]]; then
    curl_args+=(-H "Authorization: Bearer ${API_KEY}")
  fi

  STATUS_JSON=$(curl "${curl_args[@]}" \
    "http://127.0.0.1:${port}/status" \
    2>/dev/null)

  local code="${STATUS_JSON##*$'\n'}"

  STATUS_JSON="${STATUS_JSON%$'\n'"$code"}"

  if [[ "$code" == "401" || "$code" == "403" ]]; then
    AUTH_ERROR=1
  fi

  [[ "$code" == "200" ]]
}

resolve_and_fetch() {
  AUTH_ERROR=0

  if [[ -n "$API_KEY" ]]; then
    dbg "using API key from $( \
      [[ -n "${SPLASH_API_KEY:-}" ]] \
        && echo '\$SPLASH_API_KEY' \
        || echo '-k' \
    )"
  else
    dbg "no API key set (\$SPLASH_API_KEY empty, -k not given)"
  fi

  if [[ -n "$FORCE_PORT" ]]; then
    dbg "forced port: $FORCE_PORT"

    if try_status "$FORCE_PORT"; then
      ACTIVE_PORT="$FORCE_PORT"
      return 0
    fi

    dbg "no Splash reachable on forced port $FORCE_PORT"
    return 1
  fi

  if [[ -n "$LAST_PORT" ]] && try_status "$LAST_PORT"; then
    ACTIVE_PORT="$LAST_PORT"
    return 0
  fi

  read_lock_file

  if [[ -n "$LOCK_PORT" ]]; then
    dbg "serve.lock found: pid=$LOCK_PID port=$LOCK_PORT model=$LOCK_MODEL"

    if try_status "$LOCK_PORT"; then
      ACTIVE_PORT="$LOCK_PORT"
      return 0
    fi
  else
    dbg "no serve.lock at: $LOCK_FILE"
  fi

  local proc_ports
  proc_ports=$(discover_ports_via_process)

  if [[ -n "$proc_ports" ]]; then
    dbg "running splash process listening on port(s): $( \
      echo "$proc_ports" | tr '\n' ' ' \
    )"

    local p

    for p in $proc_ports; do
      if try_status "$p"; then
        ACTIVE_PORT="$p"
        return 0
      fi
    done
  else
    dbg "no running splash process found via pgrep/lsof"
  fi

  dbg "fallback port scan: ${FALLBACK_PORTS[*]}"

  local p

  for p in "${FALLBACK_PORTS[@]}"; do
    if try_status "$p"; then
      ACTIVE_PORT="$p"
      return 0
    fi
  done

  return 1
}

# ---------- Format helpers ----------
human_bytes() {
  local b="${1:-0}"

  awk -v b="$b" 'BEGIN {
    if (b == "" || b == "null") {
      print "–"
      exit
    }

    gb = b / 1073741824.0

    if (gb >= 1.0) {
      printf "%.1f GB", gb
    } else {
      printf "%.0f MB", b/1048576.0
    }
  }'
}

fmt() {
  local v="$1"

  [[ -z "$v" || "$v" == "null" ]] \
    && echo "–" \
    || echo "$v"
}

num_fmt() {
  awk -v n="$1" 'BEGIN {
    if (n=="" || n=="null") {
      print "–"
      exit
    }

    n=int(n+0)
    s=sprintf("%d", n)
    l=length(s)
    r=""
    c=0

    for (i=l; i>=1; i--) {
      r = substr(s,i,1) r
      c++

      if (c%3==0 && i!=1) {
        r="."r
      }
    }

    print r
  }'
}

pct_fmt() {
  local v="$1"

  [[ -z "$v" || "$v" == "null" ]] && {
    echo "–"
    return
  }

  awk -v v="$v" 'BEGIN {
    printf "%d%%", v*100
  }'
}

level_color() {
  local pct="$1"
  local bad_high="${2:-1}"
  local level

  if [[ "$bad_high" == "1" ]]; then
    level=$(awk -v p="$pct" 'BEGIN {
      if(p>=85) print "crit"
      else if(p>=60) print "warn"
      else print "ok"
    }')
  else
    level=$(awk -v p="$pct" 'BEGIN {
      if(p<40) print "crit"
      else if(p<70) print "warn"
      else print "ok"
    }')
  fi

  case "$level" in
    crit) echo "$CRIT" ;;
    warn) echo "$WARN" ;;
    *)    echo "$OK" ;;
  esac
}

gauge_bar() {
  local pct="$1"
  local width="${2:-18}"
  local bad_high="${3:-1}"

  local filled
  filled=$(awk \
    -v p="$pct" \
    -v w="$width" \
    'BEGIN {
      f=int(p/100*w+0.5)
      if(f<0)f=0
      if(f>w)f=w
      print f
    }')

  local empty=$(( width - filled ))

  local color
  color=$(level_color "$pct" "$bad_high")

  printf '%s%s%s%s%s' \
    "$color" \
    "$(repeat_char '█' "$filled")" \
    "$MUTED" \
    "$(repeat_char '░' "$empty")" \
    "$RESET"
}

sparkline() {
  local vals=("$@")
  local chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  local max=0

  for v in "${vals[@]}"; do
    awk -v v="$v" -v max="$max" \
      'BEGIN {
        if (v+0>max+0) print "1"
        else print "0"
      }' \
      | grep -q 1 && max=$v
  done

  [[ "$max" == "0" ]] && max=1

  local out=""
  local idx

  for v in "${vals[@]}"; do
    idx=$(awk \
      -v v="$v" \
      -v max="$max" \
      'BEGIN {
        i=int((v/max)*7)
        if(i<0)i=0
        if(i>7)i=7
        print i
      }')

    out+="${chars[$idx]}"
  done

  echo "$out"
}

status_dot() {
  case "$1" in
    true)
      printf '%s●%s %sREADY%s' \
        "$OK" "$RESET" "${BOLD}${OK}" "$RESET"
      ;;
    false)
      printf '%s●%s %sNOT READY%s' \
        "$CRIT" "$RESET" "${BOLD}${CRIT}" "$RESET"
      ;;
    *)
      printf '%s●%s %sUNKNOWN%s' \
        "$MUTED" "$RESET" "$MUTED" "$RESET"
      ;;
  esac
}

# ---------- Not-found screen ----------
draw_not_found() {
  local now="$1"

  resize_width

  # Move the cursor to the top instead of rebuilding the whole screen with
  # "clear".
  printf '\033[H'

  echo
  printf '  %s🌊 SPLASH TOP%s  %s— no running server found%s\n' \
    "$TITLE" "$RESET" "$MUTED" "$RESET"

  hline "─"

  printf '  %sLast check:%s %s\n\n' \
    "$LABEL" "$RESET" "$now"

  if [[ "${AUTH_ERROR:-0}" == "1" ]]; then
    printf '  %s⚠  Splash is responding but requires a valid API key (401/403).%s\n\n' \
      "${BOLD}${WARN}" "$RESET"

    printf '     Set it as you did when starting the server, e.g.:\n'
    printf '       %sexport SPLASH_API_KEY=your-key%s\n' \
      "$ACCENT" "$RESET"

    printf '       %s%s%s\n\n' \
      "$ACCENT" "$0" "$RESET"

    printf '     or directly: %s%s -k your-key%s\n' \
      "$ACCENT" "$0" "$RESET"
  else
    printf '  Checked: lock file, running splash process (lsof), fallback ports\n'
    printf '  (%s)\n\n' "${FALLBACK_PORTS[*]}"

    printf '  If Splash is already running but on a different port:\n'
    printf '    %s%s -p <PORT>%s     explicitly set the port (see the Splash start line)\n' \
    "$ACCENT" "$0" "$RESET"

    printf '    %s%s -v%s            shows what the script checked\n\n' \
      "$ACCENT" "$0" "$RESET"

    printf '  Otherwise start Splash e.g. with: %ssplash serve --model <model>%s\n' \
      "$ACCENT" "$RESET"
  fi

  echo
}

# ---------- Main display ----------
draw() {
  local now
  now=$(date "+%H:%M:%S")

  if ! resolve_and_fetch; then
    draw_not_found "$now"
    return
  fi

  LAST_PORT="$ACTIVE_PORT"

  # Check the terminal width.
  # On a change, clear once cleanly; afterwards update flicker-free via ESC[H.
  local current_cols
  current_cols=$(term_cols)

  if [[ "$current_cols" != "$LAST_TERM_COLS" ]]; then
    resize_width

    printf '\033[2J\033[H'
  else
    resize_width

    # Move the cursor to the top-left.
    printf '\033[H'
  fi

  local j="$STATUS_JSON"

  local ready model pid port
  ready=$(jq -r '.ready' <<<"$j" 2>/dev/null)
  model=$(jq -r '.instance.model // "–"' <<<"$j")
  pid=$(jq -r '.instance.pid // "–"' <<<"$j")
  port=$(jq -r ".instance.port // ${ACTIVE_PORT}" <<<"$j")

  local decode_tps prefill_tps accept_rate ttft_p50 ttft_p95
  local itl_p50 itl_p95

  decode_tps=$(jq -r '.metrics.decode_tokens_per_second // 0' <<<"$j")
  prefill_tps=$(jq -r '.metrics.prefill_tokens_per_second // 0' <<<"$j")
  accept_rate=$(jq -r '.metrics.draft_acceptance_rate // null' <<<"$j")
  ttft_p50=$(jq -r '.metrics.ttft_ms.p50 // null' <<<"$j")
  ttft_p95=$(jq -r '.metrics.ttft_ms.p95 // null' <<<"$j")
  itl_p50=$(jq -r '.metrics.itl_ms.p50 // null' <<<"$j")
  itl_p95=$(jq -r '.metrics.itl_ms.p95 // null' <<<"$j")

  local kv_hits kv_lookups kv_hit_rate reused_tokens

  kv_hits=$(jq -r '.cache.hits // null' <<<"$j")
  kv_lookups=$(jq -r '.cache.lookups // null' <<<"$j")
  kv_hit_rate=$(jq -r '.cache.hit_rate // null' <<<"$j")
  reused_tokens=$(jq -r '.cache.reused_tokens // null' <<<"$j")

  local queued prefilling decoding

  queued=$(jq -r '.scheduler.queued // 0' <<<"$j")
  prefilling=$(jq -r '.scheduler.prefilling // 0' <<<"$j")
  decoding=$(jq -r '.scheduler.decoding // 0' <<<"$j")

  local submitted completed cancelled failed

  submitted=$(jq -r '.requests.submitted // 0' <<<"$j")
  completed=$(jq -r '.requests.completed // 0' <<<"$j")
  cancelled=$(jq -r '.requests.cancelled // 0' <<<"$j")
  failed=$(jq -r '.requests.failed // 0' <<<"$j")

  local mem_current mem_peak mem_limit mem_headroom mem_pressure

  mem_current=$(jq -r '.memory_actual.current_bytes // null' <<<"$j")
  mem_peak=$(jq -r '.memory_actual.peak_bytes // null' <<<"$j")
  mem_limit=$(jq -r '.memory_governor.limit_bytes // null' <<<"$j")
  mem_headroom=$(jq -r '.memory_governor.headroom_bytes // null' <<<"$j")
  mem_pressure=$(jq -r '.memory_governor.system_pressure // .memory_pressure // "–"' <<<"$j")

  # ---------- Speed history ----------
  HIST_FILE="/tmp/.splash_top_hist_${ACTIVE_PORT}"

  echo "$decode_tps" >> "$HIST_FILE" 2>/dev/null

  tail -n 30 "$HIST_FILE" \
    > "${HIST_FILE}.tmp" 2>/dev/null \
    && mv "${HIST_FILE}.tmp" "$HIST_FILE"

  mapfile -t hist < "$HIST_FILE" 2>/dev/null

  local spark
  spark=$(sparkline "${hist[@]}")

  # ---------- Gauges ----------
  local mem_pct="0"

  if [[ -n "$mem_current" &&
        "$mem_current" != "null" &&
        -n "$mem_limit" &&
        "$mem_limit" != "null" &&
        "$mem_limit" != "0" ]]; then

    mem_pct=$(awk \
      -v c="$mem_current" \
      -v l="$mem_limit" \
      'BEGIN {
        printf "%.1f", (c/l)*100
      }')
  fi

  local kv_pct="0"

  [[ -n "$kv_hit_rate" && "$kv_hit_rate" != "null" ]] \
    && kv_pct=$(awk \
      -v v="$kv_hit_rate" \
      'BEGIN {
        printf "%.1f", v*100
      }')

  local accept_pct="0"

  [[ -n "$accept_rate" && "$accept_rate" != "null" ]] \
    && accept_pct=$(awk \
      -v v="$accept_rate" \
      'BEGIN {
        printf "%.1f", v*100
      }')

  local queue_color
  queue_color=$(
    [[ "$queued" -eq 0 ]] \
      && echo "$OK" \
      || {
        [[ "$queued" -le 5 ]] \
          && echo "$WARN" \
          || echo "$CRIT"
      }
  )

  local failed_color
  failed_color=$(
    [[ "$failed" -eq 0 ]] \
      && echo "$MUTED" \
      || echo "$CRIT"
  )

  local mem_gauge_color
  mem_gauge_color=$(level_color "$mem_pct" 1)

  local pressure_color="$OK"

  case "$mem_pressure" in
    *warn*|*Warn*)
      pressure_color="$WARN"
      ;;
    *crit*|*Crit*|*high*|*High*)
      pressure_color="$CRIT"
      ;;
    normal|Normal)
      pressure_color="$OK"
      ;;
    *)
      pressure_color="$MUTED"
      ;;
  esac

  # ==========================================================
  # FRAME
  #
  # Important:
  # No "clear" here.
  #
  # The cursor is already at the top-left and the whole frame
  # is written directly.
  # ==========================================================

  echo

  # Header
  printf '  %s🌊 SPLASH TOP%s   %s   %s│%s   Port %s%s%s   %s│%s   %s%s%s\n' \
    "$TITLE" "$RESET" \
    "$(status_dot "$ready")" \
    "$MUTED" "$RESET" \
    "$VALUE" "$port" "$RESET" \
    "$MUTED" "$RESET" \
    "$MUTED" "$now" "$RESET"

  echo

  printf '  %sModel%s  %s%s%s\n' \
    "$LABEL" "$RESET" "$VALUE" "$model" "$RESET"

  printf '  %sPID%s     %s%s%s\n' \
    "$LABEL" "$RESET" "$VALUE" "$pid" "$RESET"

  echo

  hline "─"

  section_title "📈" "TOKEN THROUGHPUT"

  printf '   Decode   %s%8.1f tok/s%s   %s%s%s\n' \
    "${BOLD}${ACCENT}" \
    "$decode_tps" \
    "$RESET" \
    "$ACCENT" \
    "$spark" \
    "$RESET"

  printf '   Prefill  %s%8.1f tok/s%s\n' \
    "${BOLD}${ACCENT2}" \
    "$prefill_tps" \
    "$RESET"

  printf '   DFlash 2 accept   %s %s%s%s\n' \
    "$(gauge_bar "$accept_pct" 18 0)" \
    "$VALUE" \
    "$(pct_fmt "$accept_rate")" \
    "$RESET"

  echo

  hline "─"

  section_title "⚡" "LATENCY (ms)"

  printf '   TTFT   p50 %s%-8s%s  p95 %s%-8s%s\n' \
    "$VALUE" "$(fmt "$ttft_p50")" "$RESET" \
    "$VALUE" "$(fmt "$ttft_p95")" "$RESET"

  printf '   ITL    p50 %s%-8s%s  p95 %s%-8s%s\n' \
    "$VALUE" "$(fmt "$itl_p50")" "$RESET" \
    "$VALUE" "$(fmt "$itl_p95")" "$RESET"

  echo

  hline "─"

  section_title "🧠" "KV CACHE"

  printf '   Hit rate   %s %s%s%s   %sHits/Lookups %s/%s%s   %sReused%s %s%s%s\n' \
    "$(gauge_bar "$kv_pct" 18 0)" \
    "$VALUE" "$(pct_fmt "$kv_hit_rate")" "$RESET" \
    "$LABEL" "$(fmt "$kv_hits")" "$(fmt "$kv_lookups")" "$RESET" \
    "$LABEL" "$RESET" "$VALUE" "$(num_fmt "$reused_tokens")" "$RESET"

  echo

  hline "─"

  section_title "🗂" " SCHEDULER"

  printf '   %sQueued%s      %s%-6s%s   %sPrefilling%s  %s%-6s%s   %sDecoding%s  %s%-6s%s\n' \
    "$LABEL" "$RESET" "$queue_color" "$queued" "$RESET" \
    "$LABEL" "$RESET" "$VALUE" "$prefilling" "$RESET" \
    "$LABEL" "$RESET" "$VALUE" "$decoding" "$RESET"

  echo

  section_title "📊" "REQUESTS"

  printf '   %sSubmitted%s   %s%-8s%s  %sCompleted%s  %s%-8s%s  %sCancelled%s %s%-6s%s  %sFailed%s %s%s%s\n' \
    "$LABEL" "$RESET" "$VALUE" "$(num_fmt "$submitted")" "$RESET" \
    "$LABEL" "$RESET" "$OK" "$(num_fmt "$completed")" "$RESET" \
    "$LABEL" "$RESET" "$WARN" "$cancelled" "$RESET" \
    "$LABEL" "$RESET" "$failed_color" "$failed" "$RESET"

  echo

  hline "─"

  section_title "💾" "UNIFIED MEMORY (Metal)"

  printf '   %s %s%s%s%s of %s%s%s\n' \
    "$(gauge_bar "$mem_pct" 24 1)" \
    "$mem_gauge_color" \
    "$(human_bytes "$mem_current")" \
    "$RESET" \
    "$LABEL" \
    "$VALUE" \
    "$(human_bytes "$mem_limit")" \
    "$RESET"

  printf '   %sPeak%s %s%-10s%s  %sHeadroom%s %s%-10s%s  %sPressure%s %s%s%s\n' \
    "$LABEL" "$RESET" \
    "$VALUE" "$(human_bytes "$mem_peak")" "$RESET" \
    "$LABEL" "$RESET" \
    "$VALUE" "$(human_bytes "$mem_headroom")" "$RESET" \
    "$LABEL" "$RESET" \
    "$pressure_color" "$mem_pressure" "$RESET"

  echo

  hline "─"

  printf '  %s[q]%s Quit    %s[r]%s Refresh/Clear    %sInterval %ss%s\n' \
    "$ACCENT" "$RESET" \
    "$ACCENT" "$RESET" \
    "$MUTED" "$INTERVAL" "$RESET"

  echo

  # Clear any leftover characters from a previous, longer frame without
  # clearing the screen.
  printf '\033[J'
}

# ---------- Cleanup ----------
cleanup() {
  tput cnorm 2>/dev/null
  printf '%s' "$RESET"

  # Place the cursor below the current frame and leave the screen cleanly.
  printf '\033[J'
  echo

  exit 0
}

trap cleanup INT TERM

# ---------- Start ----------
if [[ "$ONCE" == "1" ]]; then
  clear
  draw
  exit 0
fi

# Clear once at start.
# Afterwards "clear" is no longer used.
clear
tput civis 2>/dev/null

# Initialize the terminal width.
LAST_TERM_COLS=$(term_cols)
resize_width

while true; do
  draw

  key=""
  if IFS= read -rsn1 -t "$INTERVAL" key; then
    case "$key" in
      q|Q)
        cleanup
        ;;
      r|R)
        # Manual refresh: clear the screen once completely.
        # The next loop iteration then redraws immediately.
        clear
        ;;
    esac
  fi
done
