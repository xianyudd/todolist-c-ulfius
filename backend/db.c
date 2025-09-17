// db.c
#include <stdio.h>
#include <sqlite3.h>
#include "db.h"

static sqlite3 *g_db = NULL;
/* 把当前 sqlite3_stmt 指向的行转换为 JSON。
   期望列顺序：id INTEGER, text TEXT, done INTEGER(0/1)
   若你的 SELECT 多了列（如 created_at），也能兼容忽略。*/
static int row_to_json(sqlite3_stmt *st, json_t **out) {
  if (!st || !out) return -1;

  int colc = sqlite3_column_count(st);
  if (colc < 3) return -1; // 至少需要 id/text/done 三列

  int id = sqlite3_column_int(st, 0);

  const unsigned char *t = sqlite3_column_text(st, 1);
  const char *text = t ? (const char*)t : "";

  int done = 0;
  /* 第 3 列如果不是整数，也向 0/1 兜底 */
  switch (sqlite3_column_type(st, 2)) {
    case SQLITE_INTEGER: done = sqlite3_column_int(st, 2) ? 1 : 0; break;
    case SQLITE_TEXT: {
      const unsigned char *s = sqlite3_column_text(st, 2);
      done = (s && (s[0]=='1' || s[0]=='t' || s[0]=='T' || s[0]=='y' || s[0]=='Y')) ? 1 : 0;
      break;
    }
    default: done = 0; break;
  }

  json_t *obj = json_pack("{s:i, s:s, s:b}", "id", id, "text", text, "done", done ? 1 : 0);
  if (!obj) return -1;

  // 如果你的 SELECT 里还有 created_at 且是第 4 列，可以可选附加：
  if (colc >= 4) {
    const unsigned char *c = sqlite3_column_text(st, 3);
    if (c) json_object_set_new(obj, "created_at", json_string((const char*)c));
  }

  *out = obj;
  return 0;
}

int db_open(const char *path) {
  if (sqlite3_open(path, &g_db) != SQLITE_OK) {
    fprintf(stderr, "sqlite3_open failed: %s\n", sqlite3_errmsg(g_db));
    return -1;
  }

  // 在高并发场景下，避免锁冲突导致长时间阻塞或超时
  sqlite3_busy_timeout(g_db, 5000); // 最多等待 5s

  // 打开 WAL，降低 writer 阻塞 reader 的概率；同步等级降到 NORMAL 以提升吞吐
  char *errmsg = NULL;
  if (sqlite3_exec(g_db, "PRAGMA journal_mode=WAL;", NULL, NULL, &errmsg) != SQLITE_OK) {
    fprintf(stderr, "PRAGMA journal_mode=WAL failed: %s\n", errmsg ? errmsg : "(null)");
    sqlite3_free(errmsg);
  }
  if (sqlite3_exec(g_db, "PRAGMA synchronous=NORMAL;", NULL, NULL, &errmsg) != SQLITE_OK) {
    fprintf(stderr, "PRAGMA synchronous=NORMAL failed: %s\n", errmsg ? errmsg : "(null)");
    sqlite3_free(errmsg);
  }
  if (sqlite3_exec(g_db, "PRAGMA foreign_keys=ON;", NULL, NULL, &errmsg) != SQLITE_OK) {
    fprintf(stderr, "PRAGMA foreign_keys=ON failed: %s\n", errmsg ? errmsg : "(null)");
    sqlite3_free(errmsg);
  }

  return 0;
}

void db_close(void) {
  if (g_db) {
    sqlite3_close(g_db);
    g_db = NULL;
  }
}



int db_init() {
  const char *sql =
    "CREATE TABLE IF NOT EXISTS todos ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " text TEXT NOT NULL,"
    " done INTEGER NOT NULL DEFAULT 0"
    ");";
  char *errmsg = NULL;
  int rc = sqlite3_exec(g_db, sql, NULL, NULL, &errmsg);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "sqlite init error: %s\n", errmsg ? errmsg : "(unknown)");
    sqlite3_free(errmsg);
    return 1;
  }
  return 0;
}

int db_list(json_t **out_json) {
  const char *sql = "SELECT id, text, done FROM todos ORDER BY id ASC;";
  sqlite3_stmt *st = NULL;
  int rc = sqlite3_prepare_v2(g_db, sql, -1, &st, NULL);
  if (rc != SQLITE_OK) return 1;

  json_t *arr = json_array();
  if (!arr) { sqlite3_finalize(st); return 2; }

  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    json_t *obj = NULL;
    if (row_to_json(st, &obj) == 0) {
      json_array_append_new(arr, obj);
    }
  }
  sqlite3_finalize(st);
  *out_json = arr;
  return 0;
}

int db_create(const char *text, json_t **out_json) {
  const char *sql = "INSERT INTO todos(text, done) VALUES(?, 0);";
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 1;
  sqlite3_bind_text(st, 1, text ? text : "", -1, SQLITE_TRANSIENT);
  if (sqlite3_step(st) != SQLITE_DONE) { sqlite3_finalize(st); return 2; }
  sqlite3_finalize(st);

  int id = (int)sqlite3_last_insert_rowid(g_db);
  const char *sql2 = "SELECT id, text, done FROM todos WHERE id=?;";
  if (sqlite3_prepare_v2(g_db, sql2, -1, &st, NULL) != SQLITE_OK) return 3;
  sqlite3_bind_int(st, 1, id);
  if (sqlite3_step(st) == SQLITE_ROW) {
    json_t *obj = NULL;
    if (row_to_json(st, &obj) == 0) { *out_json = obj; sqlite3_finalize(st); return 0; }
  }
  sqlite3_finalize(st);
  return 4;
}

int db_update(int id, const char *text, int done_flag, json_t **out_json) {
  int rc = 0;
  sqlite3_stmt *st = NULL;

  if (text != NULL && (done_flag == 0 || done_flag == 1)) {
    const char *sql = "UPDATE todos SET text=?, done=? WHERE id=?;";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 1;
    sqlite3_bind_text(st, 1, text, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, done_flag);
    sqlite3_bind_int(st, 3, id);
  } else if (text != NULL) {
    const char *sql = "UPDATE todos SET text=? WHERE id=?;";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 1;
    sqlite3_bind_text(st, 1, text, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, id);
  } else if (done_flag == 0 || done_flag == 1) {
    const char *sql = "UPDATE todos SET done=? WHERE id=?;";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 1;
    sqlite3_bind_int(st, 1, done_flag);
    sqlite3_bind_int(st, 2, id);
  } else {
    return 0; // nothing to update
  }

  rc = sqlite3_step(st);
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return 2;

  // return updated row
  const char *sql2 = "SELECT id, text, done FROM todos WHERE id=?;";
  if (sqlite3_prepare_v2(g_db, sql2, -1, &st, NULL) != SQLITE_OK) return 3;
  sqlite3_bind_int(st, 1, id);
  if (sqlite3_step(st) == SQLITE_ROW) {
    json_t *obj = NULL;
    if (row_to_json(st, &obj) == 0) { *out_json = obj; sqlite3_finalize(st); return 0; }
  }
  sqlite3_finalize(st);
  return 4;
}

int db_delete(int id) {
  const char *sql = "DELETE FROM todos WHERE id=?;";
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 1;
  sqlite3_bind_int(st, 1, id);
  int rc = sqlite3_step(st);
  sqlite3_finalize(st);
  return (rc == SQLITE_DONE) ? 0 : 2;
}

int db_list_paged(int limit, int offset, json_t **out_json) {
  if (limit <= 0) limit = 50;          // 默认分页 50
  if (limit > 500) limit = 500;        // 上限保护
  if (offset < 0) offset = 0;
  const char *sql = "SELECT id, text, done FROM todos ORDER BY id ASC LIMIT ? OFFSET ?;";
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 1;
  sqlite3_bind_int(st, 1, limit);
  sqlite3_bind_int(st, 2, offset);
  json_t *arr = json_array();
  if (!arr) { sqlite3_finalize(st); return 2; }
  while (sqlite3_step(st) == SQLITE_ROW) {
    json_t *obj = NULL;
    // 复用你已有的 row_to_json(...)
    int id = sqlite3_column_int(st, 0);
    const unsigned char *txt = sqlite3_column_text(st, 1);
    int done = sqlite3_column_int(st, 2);
    obj = json_pack("{s:i,s:s,s:b}", "id", id, "text", txt?(const char*)txt:"", "done", done?1:0);
    json_array_append_new(arr, obj);
  }
  sqlite3_finalize(st);
  *out_json = arr;
  return 0;
}
