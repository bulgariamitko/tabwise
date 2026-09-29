#!/usr/bin/env bash
# Claude Code statusline: model, effort, rate limits, tokens, git, session duration
# Runs on macOS (bash 3.2+), Linux, and Windows (Git Bash).
# Built to spawn as few processes as possible: process creation is the main
# cost on Windows/Git Bash, so JSON parsing, time math and formatting use bash
# builtins, and git runs once per CACHE_TTL.
STATUSLINE_VERSION="3.3.0"
STATUSLINE_REPO="bulgariamitko/claude-code-statusline"
STATUSLINE_RAW_URL="https://raw.githubusercontent.com/${STATUSLINE_REPO}/main/statusline.sh"

# Cache directory for performance
CACHE_DIR="$HOME/.claude/.statusline_cache"
[ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR"
CACHE_TTL=30  # seconds for git cache
SEP=$'\037'   # field separator for parsed JSON and cache files

# ---- current time (builtin when available) ----
if [ -n "$EPOCHSECONDS" ]; then
  now=$EPOCHSECONDS                        # bash 5+
elif printf -v now '%(%s)T' -1 2>/dev/null && [ -n "$now" ]; then
  :                                        # bash 4.2+
else
  now=$(date +%s)                          # bash 3.2 (macOS)
fi

# ---- auto-update check (runs in background, once per day) ----
check_for_update() {
  local update_cache="$CACHE_DIR/update_check"
  local last=0
  [ -f "$update_cache" ] && read -r last < "$update_cache"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last < 86400 )) && return

  # Run update check in background to not block the statusline
  (
    remote_version=$(curl -sf --max-time 5 "$STATUSLINE_RAW_URL" 2>/dev/null | grep '^STATUSLINE_VERSION=' | head -1 | sed 's/STATUSLINE_VERSION="\(.*\)"/\1/')
    if [ -n "$remote_version" ] && [ "$remote_version" != "$STATUSLINE_VERSION" ]; then
      echo "$remote_version" > "$CACHE_DIR/update_available"
    else
      rm -f "$CACHE_DIR/update_available"
    fi
    echo "$now" > "$update_cache"
  ) </dev/null &>/dev/null &
}

check_for_update

IFS= read -r -d '' input  # read all of stdin without spawning cat

# ---- JSON extraction ----
# jq when available (one process for every field), else pure-bash regex.
json_get() {
  # json_get <key> [enclosing object key]; result in REPLY
  local re="\"$1\"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|([-0-9.eE+]+|true|false))"
  [ -n "$2" ] && re="\"$2\"[[:space:]]*:[[:space:]]*\\{[^}]*$re"
  REPLY=""
  if [[ "$input" =~ $re ]]; then
    REPLY="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
}

if command -v jq >/dev/null 2>&1; then
  parsed=$(printf '%s' "$input" | jq -r '[
      (.workspace.current_dir // .cwd // ""),
      (.model.display_name // ""),
      (.version // ""),
      (.effort.level // ""),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.context_window.current_usage.cache_read_input_tokens // ""),
      (.context_window.total_input_tokens // ""),
      (.context_window.total_output_tokens // ""),
      (.cost.total_duration_ms // "")
    ] | map(tostring) | join("\u001f")' 2>/dev/null)
  parsed=${parsed%$'\r'}  # jq on Windows may emit CRLF
  IFS="$SEP" read -r current_dir model_name cc_version effort_level \
    session_usage session_resets_at weekly_usage weekly_resets_at \
    cache_read sess_in sess_out duration_ms <<< "$parsed"
else
  json_get current_dir workspace; current_dir=$REPLY
  if [ -z "$current_dir" ]; then json_get cwd; current_dir=$REPLY; fi
  current_dir=${current_dir//\\\\/\\}  # unescape JSON backslashes (Windows paths)
  json_get display_name model;              model_name=$REPLY
  json_get version;                         cc_version=$REPLY
  json_get level effort;                    effort_level=$REPLY
  json_get used_percentage five_hour;       session_usage=$REPLY
  json_get resets_at five_hour;             session_resets_at=$REPLY
  json_get used_percentage seven_day;       weekly_usage=$REPLY
  json_get resets_at seven_day;             weekly_resets_at=$REPLY
  json_get cache_read_input_tokens;         cache_read=$REPLY
  json_get total_input_tokens;              sess_in=$REPLY
  json_get total_output_tokens;             sess_out=$REPLY
  json_get total_duration_ms;               duration_ms=$REPLY
fi

[ -z "$model_name" ] && model_name="Claude"
current_dir=${current_dir//\\//}  # C:\Users\me -> C:/Users/me

# Round a JSON number to an integer; empty if not numeric
to_int() {
  REPLY=""
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?([eE][+]?[0-9]+)?$ ]] && printf -v REPLY '%.0f' "$1"
}
to_int "$session_usage";     session_usage=$REPLY
to_int "$session_resets_at"; session_resets_at=$REPLY
to_int "$weekly_usage";      weekly_usage=$REPLY
to_int "$weekly_resets_at";  weekly_resets_at=$REPLY
to_int "$cache_read";        cache_read=$REPLY
to_int "$sess_in";           sess_in=$REPLY
to_int "$sess_out";          sess_out=$REPLY
to_int "$duration_ms";       duration_ms=$REPLY

# ---- colors (plain variables: no subshell per color) ----
if [ -z "$NO_COLOR" ]; then
  c() { printf -v "$1" '\033[%sm' "$2"; }
else
  c() { printf -v "$1" ''; }
fi
c RST          0
c DIR_C        '38;5;117'  # sky blue
c MODEL_C      '38;5;147'  # light purple
c CC_VER_C     '38;5;249'  # light gray
c STYLE_C      '38;5;245'  # gray
c UPDATE_C     '38;5;208'  # orange
c DUR_C        '38;5;186'  # light yellow
c RESET_C      '38;5;245'  # gray
c TOKEN_DIM_C  '38;5;245'  # gray
c SESS_TOK_C   '38;5;183'  # lavender
c GIT_C        '38;5;150'  # soft green
c GIT_CLEAN_C  '38;5;120'  # bright green
c GIT_DIRTY_C  '38;5;203'  # coral red
c GIT_AHEAD_C  '38;5;75'   # cyan
c GIT_BEHIND_C '38;5;220'  # yellow
c GREEN_C      '38;5;118'
c YELLOW_C     '38;5;226'
c RED_C        '38;5;196'

case "$effort_level" in
  low)    c EFFORT_C '38;5;245' ;;  # gray
  medium) c EFFORT_C '38;5;117' ;;  # sky blue
  high)   c EFFORT_C '38;5;213' ;;  # pink
  xhigh)  c EFFORT_C '38;5;208' ;;  # orange
  max)    c EFFORT_C '38;5;196' ;;  # red
  *)      c EFFORT_C '38;5;249' ;;
esac

# ---- formatting helpers (results in REPLY) ----
usage_color_for() {
  if   [ "$1" -lt 50 ]; then REPLY=$GREEN_C
  elif [ "$1" -lt 75 ]; then REPLY=$YELLOW_C
  else                       REPLY=$RED_C; fi
}

BAR_FULL="=========="
BAR_EMPTY="----------"
progress_bar() {
  local pct="${1:-0}" width="${2:-10}" filled
  ((pct < 0)) && pct=0; ((pct > 100)) && pct=100
  filled=$(( pct * width / 100 ))
  REPLY="${BAR_FULL:0:filled}${BAR_EMPTY:0:width-filled}"
}

format_remaining() {
  local remaining=$(( $1 - now ))
  REPLY=""
  ((remaining <= 0)) && return
  local days=$((remaining / 86400)) hours=$(((remaining % 86400) / 3600)) mins=$(((remaining % 3600) / 60))
  if ((days > 0)); then REPLY="${days}d ${hours}h ${mins}m"; else REPLY="${hours}h ${mins}m"; fi
}

format_tokens() {
  local n="$1"
  if ((n >= 1000000)); then REPLY="$((n / 1000000)).$(((n % 1000000) / 100000))M"
  elif ((n >= 1000)); then  REPLY="$((n / 1000)).$(((n % 1000) / 100))k"
  else                      REPLY="$n"; fi
}

# ---- git (single git call, cached per directory) ----
get_git_info() {
  local key=${current_dir:-$PWD}
  local cache_file="$CACHE_DIR/git_${key//[^A-Za-z0-9._-]/_}"
  local ts="" branch="" status="" ahead=0 behind=0

  if [ -f "$cache_file" ]; then
    IFS="$SEP" read -r ts branch status ahead behind < "$cache_file"
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < CACHE_TTL )); then
      git_branch=$branch; git_status=$status; git_ahead=${ahead:-0}; git_behind=${behind:-0}
      return
    fi
    branch=""; status=""; ahead=0; behind=0
  fi

  local out="" line oid=""
  if [ -n "$current_dir" ] && [ -d "$current_dir" ]; then
    out=$(cd "$current_dir" 2>/dev/null && git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
  else
    out=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
  fi

  if [ -n "$out" ]; then
    status="clean"
    while IFS= read -r line; do
      line=${line%$'\r'}
      case "$line" in
        "# branch.oid "*)  oid=${line#\# branch.oid } ;;
        "# branch.head "*) branch=${line#\# branch.head } ;;
        "# branch.ab "*)
          line=${line#\# branch.ab +}
          ahead=${line%% *}
          behind=${line##*-}
          ;;
        "#"*) ;;
        ?*) status="dirty" ;;
      esac
    done <<< "$out"
    [ "$branch" = "(detached)" ] && branch=${oid:0:7}
  fi

  printf '%s\n' "$now$SEP$branch$SEP$status$SEP$ahead$SEP$behind" > "$cache_file" 2>/dev/null
  git_branch=$branch; git_status=$status; git_ahead=$ahead; git_behind=$behind
}

get_git_info
[[ "$git_ahead" =~ ^[0-9]+$ ]] || git_ahead=0
[[ "$git_behind" =~ ^[0-9]+$ ]] || git_behind=0

# ---- render ----
# Line 1: directory, model, effort, Claude Code version, statusline version
current_dir_name=${current_dir%/}
current_dir_name=${current_dir_name##*/}
[ -z "$current_dir_name" ] && current_dir_name="unknown"

out="📁 ${DIR_C}${current_dir_name}${RST}  🤖 ${MODEL_C}${model_name}${RST}"

if [ -n "$effort_level" ]; then
  out+="  🧠 ${EFFORT_C}${effort_level}${RST}"
fi

if [ -n "$cc_version" ] && [ "$cc_version" != "null" ]; then
  out+="  📟 ${CC_VER_C}v${cc_version}${RST}"
fi

# Statusline version + update notification
update_avail=""
[ -f "$CACHE_DIR/update_available" ] && read -r update_avail < "$CACHE_DIR/update_available"
if [ -n "$update_avail" ]; then
  out+="  ${UPDATE_C}⬆ SL v${STATUSLINE_VERSION} → v${update_avail}${RST}"
else
  out+="  ${STYLE_C}SL v${STATUSLINE_VERSION}${RST}"
fi

# Line 2: rate limits (session + weekly with separate reset times)
line2=""
if [ -n "$session_usage" ]; then
  usage_color_for "$session_usage"; clr=$REPLY
  progress_bar "$session_usage" 6
  line2="⚡ ${clr}Session: ${session_usage}% [${REPLY}]${RST}"
  if [ -n "$session_resets_at" ]; then
    format_remaining "$session_resets_at"
    [ -n "$REPLY" ] && line2+=" ${RESET_C}⏱${REPLY}${RST}"
  fi
fi
if [ -n "$weekly_usage" ]; then
  usage_color_for "$weekly_usage"; clr=$REPLY
  progress_bar "$weekly_usage" 6
  [ -n "$line2" ] && line2+="  "
  line2+="📈 ${clr}Weekly: ${weekly_usage}% [${REPLY}]${RST}"
  if [ -n "$weekly_resets_at" ]; then
    format_remaining "$weekly_resets_at"
    [ -n "$REPLY" ] && line2+=" ${RESET_C}⏱${REPLY}${RST}"
  fi
fi
[ -n "$line2" ] && out+=$'\n'"$line2"

# Line 3: cached, total tokens, git, session duration
line3=""

if [ -n "$cache_read" ] && [ "$cache_read" -gt 0 ]; then
  format_tokens "$cache_read"
  line3="${TOKEN_DIM_C}📦 Cached: ${REPLY}${RST}"
fi

if [ -n "$sess_in" ] && [ -n "$sess_out" ]; then
  format_tokens $((sess_in + sess_out))
  [ -n "$line3" ] && line3+="  "
  line3+="${SESS_TOK_C}📊 Total: ${REPLY}${RST}"
fi

if [ -n "$git_branch" ]; then
  [ -n "$line3" ] && line3+="  "
  line3+="🌿 ${GIT_C}${git_branch}${RST}"
  if [ "$git_status" = "clean" ]; then
    line3+=" ${GIT_CLEAN_C}✅${RST}"
  elif [ "$git_status" = "dirty" ]; then
    line3+=" ${GIT_DIRTY_C}❌${RST}"
  fi
  ((git_ahead > 0)) && line3+=" ${GIT_AHEAD_C}↑${git_ahead}${RST}"
  ((git_behind > 0)) && line3+=" ${GIT_BEHIND_C}↓${git_behind}${RST}"
fi

if [ -n "$duration_ms" ] && [ "$duration_ms" -gt 0 ]; then
  dur_sec=$((duration_ms / 1000))
  [ -n "$line3" ] && line3+="  "
  line3+="⏱️ ${DUR_C}$((dur_sec / 3600))h $(((dur_sec % 3600) / 60))m${RST}"
fi

[ -n "$line3" ] && out+=$'\n'"$line3"

printf '%s\n' "$out"
