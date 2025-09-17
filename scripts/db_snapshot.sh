#!/usr/bin/env bash
set -Eeuo pipefail

DB="${DB:-todos.db}"                 # 目标数据库文件
SNAPDIR="${SNAPDIR:-db_snaps}"       # 快照目录
FORCE="${FORCE:-0}"                  # 恢复时是否强制关闭占用进程（0/1）

usage() {
  cat <<EOF
用法:
  $0 save [name]        保存快照到 ${SNAPDIR}/<name>.db（默认: snap_时间戳）
  $0 restore <name>     从 ${SNAPDIR}/<name>.db 恢复到 ${DB}
  $0 list               列出已有快照
环境变量:
  DB=todos.db           目标数据库路径
  SNAPDIR=db_snaps      快照目录
  FORCE=1               恢复前强制关闭占用 ${DB} 的进程
示例:
  $0 save
  $0 save baseline
  FORCE=1 $0 restore baseline
  $0 list
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1"; exit 1; }; }

save_snap() {
  local name="${1:-snap_$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$SNAPDIR"
  local out="$SNAPDIR/$name.db"
  echo "[*] 备份 ${DB} -> ${out}"
  need sqlite3
  sqlite3 "$DB" ".backup '$out'"
  # 记录校验和，方便核对
  command -v sha256sum >/dev/null 2>&1 && sha256sum "$out" > "$out.sha256" || true
  echo "[✓] 完成: $out"
}

kill_holders() {
  # 关掉占用 DB 或 8080 端口的进程（尽量温和，TERM）
  echo "[!] 尝试关闭占用进程..."
  if command -v lsof >/dev/null 2>&1; then
    mapfile -t pids < <(lsof -t -- "$DB" 2>/dev/null || true)
  else
    pids=()
  fi
  # 补充：监听 8080 的服务
  if command -v fuser >/dev/null 2>&1; then
    fuser -k 8080/tcp || true
  fi
  if ((${#pids[@]})); then
    echo "Killing: ${pids[*]}"
    kill -TERM "${pids[@]}" 2>/dev/null || true
    sleep 1
  fi
}

restore_snap() {
  local name="${1:-}"; [ -z "$name" ] && { echo "缺少快照名"; usage; exit 1; }
  local src="$SNAPDIR/$name.db"
  [ -f "$src" ] || { echo "找不到快照文件: $src"; exit 1; }
  need sqlite3

  if [ "$FORCE" = "1" ]; then kill_holders; fi

  echo "[*] 从 ${src} 恢复到 ${DB}"
  # .restore 需要能获取独占锁，若服务还在占用会失败
  if ! sqlite3 "$DB" ".restore '$src'"; then
    echo "[x] 恢复失败：数据库可能正被占用。"
    echo "   1) 停止 ./todolist（或关闭占用进程）"
    echo "   2) 重新执行: $0 restore $name"
    exit 1
  fi
  # 清掉 WAL 伴生文件（如存在）
  rm -f "${DB}-wal" "${DB}-shm" || true
  echo "[✓] 恢复完成。"
}

list_snaps() {
  mkdir -p "$SNAPDIR"
  ls -1t "$SNAPDIR"/*.db 2>/dev/null || echo "(无快照)"
}

case "${1:-}" in
  save)    save_snap "${2:-}";;
  restore) restore_snap "${2:-}";;
  list)    list_snaps;;
  -h|--help|"") usage;;
  *) echo "未知命令: $1"; usage; exit 1;;
esac

