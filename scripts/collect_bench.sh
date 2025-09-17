#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# 配置 & 参数
# =========================
OUTDIR="${1:-}"                 # 第1个参数：结果目录（可不传，自动取 bench_out 下最新）
DB="${DB:-todos.db}"            # 数据库文件，可用环境变量覆盖
PACK="${PACK:-0}"               # 是否打包（0/1），或使用 --pack / -p 参数

usage() {
  cat <<EOF
用法:
  $(basename "$0") [OUTDIR]
  $(basename "$0") --pack [OUTDIR]
  $(basename "$0") -p [OUTDIR]
  $(basename "$0") -h | --help

说明:
  - 若不传 OUTDIR，则自动选 bench_out/ 下最新目录
  - --pack/-p: 额外打包 OUTDIR 为 .tar.gz
  - DB 路径可用环境变量覆盖: DB=todos.db

示例:
  ./collect_bench.sh
  ./collect_bench.sh bench_out/20250917-194500
  PACK=1 ./collect_bench.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage; exit 0
fi

# 支持：./collect_bench.sh --pack bench_out/2025...
if [[ "${1:-}" == "--pack" || "${1:-}" == "-p" ]]; then
  PACK=1
  OUTDIR="${2:-}"
fi

# 自动选择最新的 bench_out 子目录
if [[ -z "${OUTDIR}" ]]; then
  if [[ -d bench_out ]]; then
    OUTDIR="bench_out/$(ls -1t bench_out | head -1)"
  else
    echo "[x] 未指定 OUTDIR，且当前目录下不存在 bench_out/"
    echo "    用法示例："
    echo "      ./collect_bench.sh"
    echo "      ./collect_bench.sh bench_out/20250917-194500"
    echo "      PACK=1 ./collect_bench.sh  # 同时打包"
    exit 1
  fi
fi

[[ -d "$OUTDIR" ]] || { echo "[x] 结果目录不存在：$OUTDIR"; exit 1; }

echo "OUTDIR=$OUTDIR"
echo

# 小工具
have() { command -v "$1" >/dev/null 2>&1; }

print_section() { printf "\n==== %s ====\n" "$1"; }

show_file() {
  local file="$1" pattern="${2:-}"
  if [[ -f "$file" ]]; then
    if [[ -n "$pattern" ]]; then
      grep -E "$pattern" "$file" || cat "$file"
    else
      cat "$file"
    fi
  else
    echo "(缺失) $file"
  fi
}

# =========================
# 提取 wrk 结果
# =========================
print_section "WRK GET"
show_file "$OUTDIR/wrk_get.txt" 'Requests/sec|Latency Distribution|  50%|  99%|Transfer/sec'

print_section "WRK POST"
show_file "$OUTDIR/wrk_post.txt" 'Requests/sec|  50%|  99%'

# =========================
# 提取 vegeta 结果（若存在）
# =========================
shopt -s nullglob
VEG_SUMS=( "$OUTDIR"/vegeta_get_*_summary.json )
VEG_RAWS=( "$OUTDIR"/vegeta_get_*_raw.json )
VEG_TXTS=( "$OUTDIR"/vegeta_get_*.txt )
MIX_REPORT="$OUTDIR/mix_report.txt"

if (( ${#VEG_SUMS[@]} > 0 )) || (( ${#VEG_RAWS[@]} > 0 )) || (( ${#VEG_TXTS[@]} > 0 )) || [[ -f "$MIX_REPORT" ]]; then
  # 1) 优先展示已经由 bench.sh 生成的 summary（不再二次运算，避免 jq 对 null 再除）
  if (( ${#VEG_SUMS[@]} > 0 )); then
    print_section "VEGETA GET SUMMARY (from summary.json)"
    for f in "${VEG_SUMS[@]}"; do
      echo "-- $f"
      if have jq; then
        jq . "$f" || cat "$f"
      else
        cat "$f"
      fi
      echo
    done
  fi

  # 2) 如没有 summary，则从 raw.json 计算一个摘要（兼容 '50th'/'p50' 与 null）
  if (( ${#VEG_SUMS[@]} == 0 && ${#VEG_RAWS[@]} > 0 )); then
    print_section "VEGETA GET SUMMARY (computed from raw.json)"
    for f in "${VEG_RAWS[@]}"; do
      echo "-- $f"
      if have jq; then
        jq 'def ms(n): if n==null then null else (n/1000000) end;
            {rps:.rate,
             success:(.success*100),
             p50: ms(.latencies."50th" // .latencies.p50),
             p90: ms(.latencies."90th" // .latencies.p90),
             p99: ms(.latencies."99th" // .latencies.p99),
             status:.status_codes, errors:.errors }' "$f" \
        || cat "$f"
      else
        cat "$f"
      fi
      echo
    done
  fi

  # 3) 文本报告关键行
  if (( ${#VEG_TXTS[@]} > 0 )); then
    print_section "VEGETA GET TEXT"
    for f in "${VEG_TXTS[@]}"; do
      echo "-- $f"
      grep -E 'Requests|Duration|Latencies|Success|Status Codes' "$f" || cat "$f"
      echo
    done
  fi

  # 4) 混合场景报告
  if [[ -f "$MIX_REPORT" ]]; then
    print_section "VEGETA MIX REPORT"
    show_file "$MIX_REPORT"
  fi
fi
shopt -u nullglob

# =========================
# 数据库规模
# =========================
print_section "DB COUNT"
if have sqlite3; then
  if [[ -f "$DB" ]]; then
    sqlite3 "$DB" "SELECT COUNT(*) FROM todos;" || echo "(查询失败)"
  else
    echo "(缺失) $DB"
  fi
else
  echo "(未安装 sqlite3)"
fi

# =========================
# 可选：打包结果
# =========================
if [[ "$PACK" == "1" ]]; then
  TAR="${OUTDIR%/}.tar.gz"
  echo
  echo "[i] 打包结果到：$TAR"
  tar -czf "$TAR" "$OUTDIR" 2>/dev/null || {
    echo "[!] 打包失败（权限或路径问题）"
  }
fi

echo
echo "✅ 收集完成。"
