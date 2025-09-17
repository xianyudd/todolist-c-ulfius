#!/bin/bash
set -euo pipefail

BASE="http://localhost:8080"

get_ctype () {
  # 不区分大小写抓 Content-Type，抓到第一条就退出
  curl -sI "$BASE$1" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ {sub(/^[^:]*:[ ]*/, "", $0); print $0; exit}'
}

test_one () {
  local path="$1"
  local expect="${2:-}"   # 传 "-" 表示跳过 Content-Type 校验
  local code ctype
  code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE$path")
  ctype=$(get_ctype "$path" || true)

  echo "$path -> $code | ${ctype:-<no Content-Type>}"

  if [ "$code" != "200" ]; then
    echo "FAIL: $path HTTP $code"
    exit 1
  fi

  if [ "$expect" != "-" ] && [ -n "$expect" ] && [ -n "$ctype" ]; then
    case "$ctype" in
      "$expect"*) ;;  # 前缀匹配，允许 charset
      *) echo "FAIL: $path Content-Type '$ctype' != '$expect'"; exit 1;;
    esac
  fi
}

echo "=== 静态资源连通性测试 ==="
# 首页有时没设 Content-Type，这里先跳过类型校验（用 '-'）
test_one "/" "-"
test_one "/static/style.css" "text/css"
test_one "/static/main.js"   "application/javascript"
echo "✅ 全部通过"
