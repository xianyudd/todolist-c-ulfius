#!/usr/bin/env bash
# A robust, modular HTTP benchmark script for Ulfius/SQLite TodoList.
# 修改记录:
#  - 修正 vegeta 混合场景 gob 错误：报告阶段改为多输入文件而非 cat 级联
#  - 修正 vegeta 带参问题（-http2/-keepalive 为 flag）
#  - 增强错误/兼容性处理与输出友好性
#  - 默认直连本机，避免代理干扰
set -Eeuo pipefail

# 强制本地直连，避免 curl 走代理
export NO_PROXY=127.0.0.1,localhost,::1
export no_proxy=127.0.0.1,localhost,::1
# 避免 .curlrc 干预
export CURL_HOME="/dev/null"

############################################
#                默认参数（可用环境变量/命令行覆盖）
############################################
BASE="${BASE:-http://localhost:8080}"       # 服务根地址（不要带末尾 / 也可，join_url 会处理）
GET_PATH="${GET_PATH:-/api/todos}"          # GET 接口路径
POST_PATH="${POST_PATH:-/api/todos}"        # POST 接口路径
GET_LIMIT="${GET_LIMIT:-50}"                # GET 分页大小（空字符串则不加 ?limit）

DUR="${DUR:-30s}"                           # 压测时长（支持“30”或“30s”）
WARMUP_REQS="${WARMUP_REQS:-20}"            # 预热 GET 次数

# wrk（GET）
WRK_THREADS="${WRK_THREADS:-4}"
WRK_CONNS="${WRK_CONNS:-64}"

# wrk（POST）
WRK_POST_THREADS="${WRK_POST_THREADS:-2}"
WRK_POST_CONNS="${WRK_POST_CONNS:-16}"

# vegeta（开环固定速率，非必须）
VEGETA_GET_RATE="${VEGETA_GET_RATE:-200}"
MIX_GET_RATE="${MIX_GET_RATE:-160}"
MIX_POST_RATE="${MIX_POST_RATE:-40}"
USE_VEGETA="${USE_VEGETA:-auto}"            # auto|on|off

# vegeta 调优项（可通过环境变量覆盖）
VEGETA_GET_CONNS="${VEGETA_GET_CONNS:-300}"
VEGETA_POST_CONNS="${VEGETA_POST_CONNS:-60}"
VEGETA_TIMEOUT="${VEGETA_TIMEOUT:-10s}"
VEGETA_HTTP2="${VEGETA_HTTP2:-false}"       # false/true
VEGETA_KEEPALIVE="${VEGETA_KEEPALIVE:-true}"

# 输出目录
OUTDIR="${OUTDIR:-bench_out/$(date +%Y%m%d-%H%M%S)}"

############################################
#                彩色日志 & 工具
############################################
c_green='\033[0;32m'; c_yellow='\033[0;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
log()  { echo -e "${c_green}[i]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[!]${c_reset} $*" >&2; }
err()  { echo -e "${c_red}[x]${c_reset} $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }
}

normalize_duration() {
  local d="${1:-$DUR}"
  [[ "$d" =~ ^[0-9]+$ ]] && d="${d}s"
  echo "$d"
}

join_url() { # 连接 BASE 与 PATH
  local base="$1" path="$2"
  echo "${base%/}${path}"
}

#############################
#         参数解析
#############################
usage() {
  cat <<EOF
用法: $(basename "$0") [时长] [选项]

例子:
  ./bench.sh           # 默认 30s
  ./bench.sh 45        # 45 秒（自动补 s）
  ./bench.sh 60s       # 60 秒
可用参数（覆盖默认值）：
  --base URL            服务根地址，默认 $BASE
  --get PATH            GET 路径，默认 $GET_PATH
  --post PATH           POST 路径，默认 $POST_PATH
  --limit N             GET 分页大小（空字符串表示不加 limit）
  --threads N           wrk GET 线程数，默认 $WRK_THREADS
  --conns N             wrk GET 连接数，默认 $WRK_CONNS
  --post-threads N      wrk POST 线程数，默认 $WRK_POST_THREADS
  --post-conns N        wrk POST 连接数，默认 $WRK_POST_CONNS
  --rate N              vegeta GET 固定 RPS，默认 $VEGETA_GET_RATE
  --mix-get N           vegeta 混合 GET RPS，默认 $MIX_GET_RATE
  --mix-post N          vegeta 混合 POST RPS，默认 $MIX_POST_RATE
  --out DIR             输出目录，默认 $OUTDIR
  --vegeta on|off       强制开/关 vegeta（默认 auto: 如安装则执行）
  -h, --help            显示帮助
也可用环境变量覆盖：BASE, GET_PATH, POST_PATH, GET_LIMIT, DUR, OUTDIR 等。
EOF
}

# 简单解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --base) BASE="$2"; shift 2;;
    --get) GET_PATH="$2"; shift 2;;
    --post) POST_PATH="$2"; shift 2;;
    --limit) GET_LIMIT="$2"; shift 2;;
    --threads) WRK_THREADS="$2"; shift 2;;
    --conns) WRK_CONNS="$2"; shift 2;;
    --post-threads) WRK_POST_THREADS="$2"; shift 2;;
    --post-conns) WRK_POST_CONNS="$2"; shift 2;;
    --rate) VEGETA_GET_RATE="$2"; shift 2;;
    --mix-get) MIX_GET_RATE="$2"; shift 2;;
    --mix-post) MIX_POST_RATE="$2"; shift 2;;
    --out) OUTDIR="$2"; shift 2;;
    --vegeta) USE_VEGETA="$2"; shift 2;;
    *)  # 位置参数：时长
      DUR="$(normalize_duration "$1")"; shift;;
  esac
done

#############################
#         依赖检查
#############################
require_cmd curl
require_cmd wrk

HAS_VEGETA=0
if [[ "$USE_VEGETA" == "on" ]]; then
  require_cmd vegeta
  HAS_VEGETA=1
elif [[ "$USE_VEGETA" == "auto" ]]; then
  if command -v vegeta >/dev/null 2>&1; then HAS_VEGETA=1; fi
fi

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1

#############################
#         初始化
#############################
DUR="$(normalize_duration "$DUR")"
mkdir -p "$OUTDIR"
GET_URL="$(join_url "$BASE" "$GET_PATH")"
if [[ -n "${GET_LIMIT:-}" ]]; then
  if [[ "$GET_URL" == *\?* ]]; then
    GET_URL="${GET_URL}&limit=${GET_LIMIT}"
  else
    GET_URL="${GET_URL}?limit=${GET_LIMIT}"
  fi
fi
POST_URL="$(join_url "$BASE" "$POST_PATH")"

log "BASE     : $BASE"
log "GET      : $GET_URL"
log "POST     : $POST_URL"
log "DURATION : $DUR"
log "OUTDIR   : $OUTDIR"
[[ $HAS_VEGETA -eq 1 ]] && log "Vegeta   : ON (rate=$VEGETA_GET_RATE, mix=$MIX_GET_RATE/$MIX_POST_RATE)" || log "Vegeta   : OFF"

# 尝试提高 FD 限制
current_nofile=$(ulimit -n || echo 1024)
if [[ "$current_nofile" -lt 65536 ]]; then
  ulimit -n 65536 || warn "无法提升 ulimit -n（权限不足）"
  log "ulimit -n => $(ulimit -n || echo 'unknown')"
fi

#############################
#         模块：预热
#############################
warmup() {
  echo
  echo "=== Warmup ($WARMUP_REQS x GET) ==="
  local ok=0
  for ((i=1;i<=WARMUP_REQS;i++)); do
    # 强制直连，避免代理
    if curl -q --proxy '' --noproxy '*' -fsS "$GET_URL" >/dev/null; then
      ok=$((ok+1))
    fi
  done
  log "Warmup OK: $ok/$WARMUP_REQS"
}

#############################
#         模块：wrk GET
#############################
wrk_get() {
  echo
  echo "=== wrk: GET $GET_URL ==="
  local out="$OUTDIR/wrk_get.txt"
  if ! wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$DUR" --latency "$GET_URL" | tee "$out"; then
    warn "wrk GET 执行失败（参见 $out）"
  fi
}

#############################
#         模块：wrk POST
#############################
wrk_post() {
  echo
  echo "=== wrk: POST $POST_URL (low write) ==="
  local out="$OUTDIR/wrk_post.txt"
  local lua="$OUTDIR/post.lua"
  cat > "$lua" <<LUA
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
counter = 0
request = function()
  counter = counter + 1
  local body = string.format('{"text":"bench-%d"}', counter)
  return wrk.format("POST", "${POST_PATH}", nil, body)
end
LUA
  if ! wrk -t"$WRK_POST_THREADS" -c"$WRK_POST_CONNS" -d"$DUR" --latency -s "$lua" "$BASE" | tee "$out"; then
    warn "wrk POST 执行失败（参见 $out）"
  fi
}

#############################
#         模块：vegeta GET 固定 RPS
#############################
vegeta_get() {
  [[ $HAS_VEGETA -eq 1 ]] || return 0
  echo
  echo "=== vegeta: GET fixed rate ${VEGETA_GET_RATE} rps ==="
  local bin="$OUTDIR/vegeta_get_${VEGETA_GET_RATE}.bin"
  local txt="$OUTDIR/vegeta_get_${VEGETA_GET_RATE}.txt"
  local html="$OUTDIR/vegeta_get_${VEGETA_GET_RATE}.html"
  local raw="$OUTDIR/vegeta_get_${VEGETA_GET_RATE}_raw.json"
  local sum="$OUTDIR/vegeta_get_${VEGETA_GET_RATE}_summary.json"

  local veg_opts=( -duration "$DUR" -rate "$VEGETA_GET_RATE" -connections "$VEGETA_GET_CONNS" -timeout "$VEGETA_TIMEOUT" )
  [[ "$VEGETA_HTTP2" == "true" ]] && veg_opts+=( -http2 )
  [[ "$VEGETA_KEEPALIVE" == "true" ]] && veg_opts+=( -keepalive )

  # 生成原始数据 + 文本报告
  if ! echo "GET $GET_URL" | vegeta attack "${veg_opts[@]}" | tee "$bin" | vegeta report | tee "$txt"; then
    warn "vegeta GET 执行失败（查看 $bin / $txt）"
  fi

  # 曲线
  if ! cat "$bin" | vegeta plot > "$html" 2>/dev/null; then
    warn "vegeta plot 失败"
  fi

  # JSON 报告
  if ! cat "$bin" | vegeta report -type=json > "$raw" 2>/dev/null; then
    warn "vegeta JSON 报告失败"
  fi

  # 提取摘要
  if [[ $HAS_JQ -eq 1 && -f "$raw" ]]; then
    cat "$raw" \
    | jq 'def ms(v): if v==null then null else (v/1000000) end;
          {rps:.rate,
           success:(.success*100),
           p50: ms(.latencies."50th" // .latencies.p50 // null),
           p90: ms(.latencies."90th" // .latencies.p90 // null),
           p99: ms(.latencies."99th" // .latencies.p99 // null),
           status:.status_codes, errors:.errors }' \
    > "$sum" || warn "jq 提取摘要失败"
  else
    [[ $HAS_JQ -eq 0 ]] && warn "未安装 jq，跳过 JSON 摘要（保留 raw.json）"
  fi
}

#############################
#         模块：vegeta 混合（修复 gob: duplicate type）
#############################
vegeta_mix() {
  [[ $HAS_VEGETA -eq 1 ]] || return 0
  echo
  echo "=== vegeta: mixed (GET ${MIX_GET_RATE} rps + POST ${MIX_POST_RATE} rps) ==="
  local getbin="$OUTDIR/mix_get.bin"
  local postbin="$OUTDIR/mix_post.bin"
  local report="$OUTDIR/mix_report.txt"
  local html="$OUTDIR/mix_plot.html"
  local body="$OUTDIR/post.json"
  echo '{"text":"from-vegeta"}' > "$body"

  # GET opts
  local get_opts=( -duration "$DUR" -rate "$MIX_GET_RATE" -connections "$VEGETA_GET_CONNS" -timeout "$VEGETA_TIMEOUT" )
  [[ "$VEGETA_HTTP2" == "true" ]] && get_opts+=( -http2 )
  [[ "$VEGETA_KEEPALIVE" == "true" ]] && get_opts+=( -keepalive )

  # POST opts
  local post_opts=( -duration "$DUR" -rate "$MIX_POST_RATE" -connections "$VEGETA_POST_CONNS" -timeout "$VEGETA_TIMEOUT" -header "Content-Type: application/json" -body "$body" )
  [[ "$VEGETA_HTTP2" == "true" ]] && post_opts+=( -http2 )
  [[ "$VEGETA_KEEPALIVE" == "true" ]] && post_opts+=( -keepalive )

  # 并发采集两个流
  ( echo "GET $GET_URL"   | vegeta attack "${get_opts[@]}"   > "$getbin"  ) &
  ( echo "POST $POST_URL" | vegeta attack "${post_opts[@]}"  > "$postbin" ) &
  wait

  if [[ -s "$getbin" || -s "$postbin" ]]; then
    # 正确写法：report 支持多文件
    if ! vegeta report "$getbin" "$postbin" | tee "$report"; then
      warn "vegeta mix report 失败"
    fi
    # plot 只能吃单一流，所以还是用 cat
    if ! cat "$getbin" "$postbin" | vegeta plot > "$html" 2>/dev/null; then
      warn "vegeta mix plot 失败"
    fi
  else
    warn "vegeta mix 未生成任何数据文件"
  fi
}

#############################
#         模块：简要汇总
#############################
summ_line() {
  local file="$1" key="$2" label="$3"
  if [[ -f "$file" ]]; then
    local v; v="$(grep -m1 "$key" "$file" || true)"
    printf "%-26s %s\n" "$label" "${v:-N/A}"
  else
    printf "%-26s %s\n" "$label" "N/A"
  fi
}

summary() {
  echo
  echo "=== Summary (quick view) ==="
  summ_line "$OUTDIR/wrk_get.txt"  "Requests/sec"         "wrk GET  Requests/sec"
  summ_line "$OUTDIR/wrk_get.txt"  "Latency Distribution" "wrk GET  Latency Dist."
  summ_line "$OUTDIR/wrk_get.txt"  "  50%"                "wrk GET  p50"
  summ_line "$OUTDIR/wrk_get.txt"  "  99%"                "wrk GET  p99"
  summ_line "$OUTDIR/wrk_post.txt" "Requests/sec"         "wrk POST Requests/sec"
  summ_line "$OUTDIR/wrk_post.txt" "  50%"                "wrk POST p50"
  summ_line "$OUTDIR/wrk_post.txt" "  99%"                "wrk POST p99"

  if command -v vegeta >/dev/null 2>&1 && [[ $HAS_VEGETA -eq 1 ]]; then
    echo "(vegeta 详情见 $OUTDIR/*.txt / *.html / *_summary.json / *_raw.json)"
  fi
  echo
  log "完成，结果目录：$OUTDIR"
}

#############################
#         主流程
#############################
trap 'err "执行失败（中途退出）。已生成的文件保留在：$OUTDIR"; exit 1' ERR

warmup
wrk_get
wrk_post
vegeta_get
vegeta_mix
summary
