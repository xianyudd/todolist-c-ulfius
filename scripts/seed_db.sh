#!/usr/bin/env bash
set -Eeuo pipefail
DB="${1:-todos.db}"
N="${2:-10000}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "[x] 需要 sqlite3" >&2; exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "[x] 数据库不存在：$DB" >&2; exit 1
fi

echo "[i] 向 $DB 批量插入 $N 行..."
sqlite3 "$DB" <<SQL
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
BEGIN;
WITH RECURSIVE seq(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM seq WHERE x < $N
)
INSERT INTO todos(text, done)
SELECT 'seed-' || x, 0 FROM seq;
COMMIT;
SQL
echo "[✓] 造数完成"

