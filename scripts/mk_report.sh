#!/usr/bin/env bash
set -Eeuo pipefail

# ==== 参数 ====
OUTDIR="${1:-}"            # 传结果目录；不传则取 bench_out 下最新
DB="${DB:-todos.db}"       # 可用 env 覆盖
TITLE="${TITLE:-HTTP Benchmark Report}"

# ==== 帮助 ====
usage() {
  cat <<EOF
用法:
  $(basename "$0") [OUTDIR]

说明:
  - 若不传 OUTDIR，则自动取 bench_out/ 下最新目录
  - 输出文件: OUTDIR/REPORT.md

示例:
  ./scripts/mk_report.sh
  ./scripts/mk_report.sh bench_out/20250917-202801
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# ==== 工具 ====
have() { command -v "$1" >/dev/null 2>&1; }

# ==== 选 OUTDIR ====
if [[ -z "$OUTDIR" ]]; then
  [[ -d bench_out ]] || { echo "[x] 没有 bench_out/ 且未指定 OUTDIR"; exit 1; }
  OUTDIR="bench_out/$(ls -1t bench_out | head -1)"
fi
[[ -d "$OUTDIR" ]] || { echo "[x] 结果目录不存在: $OUTDIR"; exit 1; }

# ==== 提取 WRK 指标 ====
wrk_rps()      { grep -m1 "Requests/sec" "$1" | cut -d: -f2 | xargs; }
wrk_p50()      { grep -m1 "  50%"         "$1" | awk '{print $2}'; }
wrk_p99()      { grep -m1 "  99%"         "$1" | awk '{print $2}'; }
wrk_transfer() { grep -m1 "Transfer/sec"  "$1" | cut -d: -f2 | xargs; }

WRK_GET="$OUTDIR/wrk_get.txt"
WRK_POST="$OUTDIR/wrk_post.txt"

GET_RPS="$(  [[ -f "$WRK_GET"  ]] && wrk_rps "$WRK_GET"  || echo "N/A")"
GET_P50="$(  [[ -f "$WRK_GET"  ]] && wrk_p50 "$WRK_GET"  || echo "N/A")"
GET_P99="$(  [[ -f "$WRK_GET"  ]] && wrk_p99 "$WRK_GET"  || echo "N/A")"
GET_TX="$(   [[ -f "$WRK_GET"  ]] && wrk_transfer "$WRK_GET"  || echo "N/A")"

POST_RPS="$( [[ -f "$WRK_POST" ]] && wrk_rps "$WRK_POST" || echo "N/A")"
POST_P50="$( [[ -f "$WRK_POST" ]] && wrk_p50 "$WRK_POST" || echo "N/A")"
POST_P99="$( [[ -f "$WRK_POST" ]] && wrk_p99 "$WRK_POST" || echo "N/A")"

# ==== 提取 Vegeta ====
VEG_SUM="$(ls "$OUTDIR"/vegeta_get_*_summary.json 2>/dev/null | head -1 || true)"
VEG_RAW="$(ls "$OUTDIR"/vegeta_get_*_raw.json     2>/dev/null | head -1 || true)"
VEG_TXT="$(ls "$OUTDIR"/vegeta_get_*.txt          2>/dev/null | head -1 || true)"

VEG_RPS="N/A"; VEG_SUCC="N/A"; VEG_P50="N/A"; VEG_P99="N/A"

if [[ -n "$VEG_SUM" && -f "$VEG_SUM" && $(have jq && echo 1) ]]; then
  VEG_RPS=$(  jq -r '.rps // "N/A"' "$VEG_SUM" 2>/dev/null || echo "N/A")
  VEG_SUCC=$(jq -r '.success // "N/A"' "$VEG_SUM" 2>/dev/null || echo "N/A")
  VEG_P50=$( jq -r '.p50 // "N/A"' "$VEG_SUM" 2>/dev/null || echo "N/A")
  VEG_P99=$( jq -r '.p99 // "N/A"' "$VEG_SUM" 2>/dev/null || echo "N/A")
elif [[ -n "$VEG_RAW" && -f "$VEG_RAW" && $(have jq && echo 1) ]]; then
  read VEG_RPS VEG_SUCC VEG_P50 VEG_P99 < <(
    jq -r 'def ms(n): if n==null then "N/A" else (n/1000000|tostring) end
           | [.rate, (.success*100), (ms(.latencies."50th" // .latencies.p50)), (ms(.latencies."99th" // .latencies.p99))] | @tsv' \
       "$VEG_RAW" 2>/dev/null || echo -e "N/A\tN/A\tN/A\tN/A"
  )
elif [[ -n "$VEG_TXT" && -f "$VEG_TXT" ]]; then
  VEG_SUCC="$(grep -m1 '^Success' "$VEG_TXT" | grep -oE '[0-9]+(\.[0-9]+)?%' || echo "N/A")"
fi

# ==== 混合场景 ====
MIX_TXT="$OUTDIR/mix_report.txt"
MIX_RPS="N/A"; MIX_P50="N/A"; MIX_P99="N/A"; MIX_SUCC="N/A"
if [[ -f "$MIX_TXT" ]]; then
  MIX_RPS="$(grep -m1 'Requests' "$MIX_TXT" | awk '{print $8}' || echo N/A)"
  MIX_P50="$(grep -m1 '  50%' "$MIX_TXT" | awk '{print $2}' || echo N/A)"
  MIX_P99="$(grep -m1 '  99%' "$MIX_TXT" | awk '{print $2}' || echo N/A)"
  MIX_SUCC="$(grep -m1 '^Success' "$MIX_TXT" | grep -oE '[0-9]+(\.[0-9]+)?%' || echo N/A)"
fi


# ==== DB 规模 ====
DB_COUNT="N/A"
if have sqlite3 && [[ -f "$DB" ]]; then
  DB_COUNT="$(sqlite3 "$DB" "SELECT COUNT(*) FROM todos;" 2>/dev/null || echo N/A)"
fi

# ==== 生成报告 ====
REPORT="$OUTDIR/REPORT.md"
{
  echo "# $TITLE"
  echo
  echo "- **结果目录**: \`$OUTDIR\`  "
  echo "- **生成时间**: $(date '+%F %T')  "
  echo "- **数据库**: \`${DB}\`（rows = ${DB_COUNT}）  "
  echo
  echo "## 快速指标"
  echo
  echo "| 场景 | RPS | p50 | p99 | 备注 |"
  echo "|---|---:|---:|---:|---|"
  echo "| wrk GET  | ${GET_RPS} | ${GET_P50} | ${GET_P99} | Transfer/sec: ${GET_TX} |"
  echo "| wrk POST | ${POST_RPS} | ${POST_P50} | ${POST_P99} |  |"
  echo "| vegeta GET | ${VEG_RPS} | ${VEG_P50} ms | ${VEG_P99} ms | Success: ${VEG_SUCC} |"
  echo "| vegeta MIX | ${MIX_RPS} | ${MIX_P50} | ${MIX_P99} | Success: ${MIX_SUCC} |"

} >"$REPORT"

echo "✅ 报告已生成：$REPORT"
