#include <ulfius.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <signal.h>
#include <unistd.h>
#include "db.h"

#define PORT 8080
#define STATIC_DIR "./frontend"

/* 先声明，避免隐式声明告警 */
static int get_query_int(const char *url, const char *key, int defv);

/* ========== 通用 JSON 响应 ========== */
static int send_json(struct _u_response *resp, int status, json_t *j) {
  u_map_put(resp->map_header, "Content-Type", "application/json");
  return ulfius_set_json_body_response(resp, status, j);
}

static int send_error_json(struct _u_response *resp, int status, const char* msg) {
  json_t *j = json_pack("{s:s}", "error", msg ? msg : "error");
  int ret = send_json(resp, status, j);
  json_decref(j);
  return ret;
}

/* ========== 路径参数解析（:id），并兜底从 url_path 手动解析 ========== */
static int parse_id_from_request(const struct _u_request *req) {
  const char *idstr = u_map_get(req->map_url, "id");
  if (idstr && *idstr) {
    for (const char *p = idstr; *p; ++p) if (!isdigit((unsigned char)*p)) return -1;
    return atoi(idstr);
  }
  const char *path = req->url_path ? req->url_path : req->http_url;
  if (!path) return -1;
  const char *prefix = "/api/todos/";
  size_t plen = strlen(prefix);
  if (strncmp(path, prefix, plen) != 0) return -1;
  const char *p = path + plen;
  if (!*p) return -1;
  const char *q = p;
  while (*q && isdigit((unsigned char)*q)) q++;
  if (*q == '\0' || *q == '/') {
    return atoi(p);
  }
  return -1;
}

/* ========== Handlers ========== */
/* GET /api/todos */
static int h_get_todos(const struct _u_request *req, struct _u_response *resp, void *user_data) {
  int limit  = get_query_int(req->http_url, "limit", 50);
  int offset = get_query_int(req->http_url, "offset", 0);
  json_t *arr = NULL;
  if (db_list_paged(limit, offset, &arr) != 0) return send_error_json(resp, 500, "db list error");
  send_json(resp, 200, arr);
  json_decref(arr);
  return U_CALLBACK_CONTINUE;
}

/* POST /api/todos  body: {"text":"..."} */
static int h_post_todo(const struct _u_request *req, struct _u_response *resp, void *user_data) {
  json_error_t jerr;
  json_t *body = json_loadb((const char*)req->binary_body, req->binary_body_length, 0, &jerr);
  if (!body) return send_error_json(resp, 400, "invalid json");

  json_t *jtext = json_object_get(body, "text");
  if (!jtext || !json_is_string(jtext)) { json_decref(body); return send_error_json(resp, 400, "missing text"); }

  const char *text = json_string_value(jtext);
  json_t *created = NULL;
  int rc = db_create(text, &created);
  json_decref(body);
  if (rc != 0) return send_error_json(resp, 500, "db create error");

  send_json(resp, 201, created);
  json_decref(created);
  return U_CALLBACK_CONTINUE;
}

/* PUT /api/todos/:id  body: {"text": "...", "done": true/false} (both optional) */
static int h_put_todo(const struct _u_request *req, struct _u_response *resp, void *user_data) {
  int id = parse_id_from_request(req);
  if (id <= 0) return send_error_json(resp, 400, "invalid id");

  json_error_t jerr;
  json_t *body = json_loadb((const char*)req->binary_body, req->binary_body_length, 0, &jerr);
  if (!body) return send_error_json(resp, 400, "invalid json");

  const char *text = NULL;
  int done_flag = -1;

  json_t *jtext = json_object_get(body, "text");
  if (jtext && json_is_string(jtext)) text = json_string_value(jtext);
  json_t *jdone = json_object_get(body, "done");
  if (jdone && json_is_boolean(jdone)) done_flag = json_boolean_value(jdone) ? 1 : 0;

  json_t *updated = NULL;
  int rc = db_update(id, text, done_flag, &updated);
  json_decref(body);

  if (rc != 0) return send_error_json(resp, 404, "not found or update failed");
  if (!updated) return send_error_json(resp, 404, "not found");

  send_json(resp, 200, updated);
  json_decref(updated);
  return U_CALLBACK_CONTINUE;
}

/* DELETE /api/todos/:id */
static int h_delete_todo(const struct _u_request *req, struct _u_response *resp, void *user_data) {
  int id = parse_id_from_request(req);
  if (id <= 0) return send_error_json(resp, 400, "invalid id");
  int rc = db_delete(id);
  if (rc != 0) return send_error_json(resp, 404, "not found");
  json_t *ok = json_pack("{s:s}", "status", "deleted");
  send_json(resp, 200, ok);
  json_decref(ok);
  return U_CALLBACK_CONTINUE;
}

/* 健康检查：GET /health -> {"ok":true} */
static int h_health(const struct _u_request *req, struct _u_response *resp, void *user_data) {
  json_t *ok = json_pack("{s:b}", "ok", 1);
  send_json(resp, 200, ok);
  json_decref(ok);
  return U_CALLBACK_CONTINUE;
}

/* ========== 静态文件服务 ========== */
static const char* guess_content_type(const char *path) {
  const char *ext = strrchr(path, '.');
  if (!ext) return "application/octet-stream";
  if (strcmp(ext, ".html")==0) return "text/html; charset=utf-8";
  if (strcmp(ext, ".css")==0) return "text/css; charset=utf-8";
  if (strcmp(ext, ".js")==0) return "application/javascript; charset=utf-8";
  if (strcmp(ext, ".json")==0) return "application/json; charset=utf-8";
  if (strcmp(ext, ".png")==0) return "image/png";
  if (strcmp(ext, ".jpg")==0 || strcmp(ext, ".jpeg")==0) return "image/jpeg";
  return "application/octet-stream";
}

static int send_file_response(struct _u_response *resp, const char *fs_path) {
  FILE *fp = fopen(fs_path, "rb");
  if (!fp) return 0;
  fseek(fp, 0, SEEK_END);
  long len = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  char *buf = (char*)malloc(len);
  if (!buf) { fclose(fp); return 0; }
  if (fread(buf, 1, len, fp) != (size_t)len) { free(buf); fclose(fp); return 0; }
  fclose(fp);

  ulfius_set_binary_body_response(resp, 200, buf, len); /* 兼容 Ulfius 2.x 签名 */
  free(buf);
  return 1;
}

static int h_static(const struct _u_request *req, struct _u_response *resp, void *user_data) {
  const char *path = req->url_path ? req->url_path : "/";
  char fs[1024] = {0};

  if (strcmp(path, "/") == 0) {
    snprintf(fs, sizeof(fs), "%s/index.html", STATIC_DIR);
  } else if (strcmp(path, "/static/style.css") == 0) {
    snprintf(fs, sizeof(fs), "%s/style.css", STATIC_DIR);
  } else if (strcmp(path, "/static/main.js") == 0) {
    snprintf(fs, sizeof(fs), "%s/main.js", STATIC_DIR);
  } else {
    return U_CALLBACK_CONTINUE;
  }

  fprintf(stderr, "[DEBUG] static request '%s' -> '%s'\n", path, fs); fflush(stderr);
  const char *ctype = guess_content_type(fs);
  if (!send_file_response(resp, fs)) return send_error_json(resp, 404, "not found");
  u_map_put(resp->map_header, "Content-Type", ctype);
  return U_CALLBACK_CONTINUE;
}

/* ========== 查询参数解析：从 http_url 中提取 int ========== */
static int get_query_int(const char *url, const char *key, int defv) {
  if (!url) return defv;
  const char *q = strchr(url, '?');
  if (!q) return defv;
  q++; // 跳过 '?'
  size_t klen = strlen(key);
  while (*q) {
    if (strncmp(q, key, klen) == 0 && q[klen]=='=') {
      q += klen+1;
      return atoi(q);
    }
    const char *amp = strchr(q, '&');
    if (!amp) break;
    q = amp + 1;
  }
  return defv;
}

/* ========== 运行控制：优雅退出 ========== */
static volatile sig_atomic_t g_running = 1;
static void on_signal(int sig) {
  (void)sig;
  g_running = 0;
}

/* ========== main ========== */
int main(int argc, char **argv) {
  /* CLI 参数：--port/--db/--log-level */
  int port = PORT;
  const char *db_path = "todos.db";
  const char *log_level = "info";

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--port") == 0 && i+1 < argc) {
      port = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--db") == 0 && i+1 < argc) {
      db_path = argv[++i];
    } else if (strcmp(argv[i], "--log-level") == 0 && i+1 < argc) {
      log_level = argv[++i];
    }
  }

  /* 打开/初始化数据库 */
  if (db_open(db_path) != 0) { fprintf(stderr, "DB open failed: %s\n", db_path); fflush(stderr); return 1; }
  if (db_init() != 0) { fprintf(stderr, "DB init failed\n"); fflush(stderr); return 1; }

  /* 初始化 Ulfius */
  struct _u_instance inst;
  if (ulfius_init_instance(&inst, (unsigned int)port, NULL, NULL) != U_OK) {
    fprintf(stderr, "ulfius init failed\n"); fflush(stderr);
    db_close();
    return 1;
  }

  /* API 路由 */
  ulfius_add_endpoint_by_val(&inst, "GET",    "/api/todos",     NULL, 0, &h_get_todos, NULL);
  ulfius_add_endpoint_by_val(&inst, "POST",   "/api/todos",     NULL, 0, &h_post_todo, NULL);
  ulfius_add_endpoint_by_val(&inst, "PUT",    "/api/todos/:id",  NULL, 0, &h_put_todo, NULL);
  ulfius_add_endpoint_by_val(&inst, "PUT",    "/api/todos/:id/", NULL, 0, &h_put_todo, NULL);
  ulfius_add_endpoint_by_val(&inst, "DELETE", "/api/todos/:id",  NULL, 0, &h_delete_todo, NULL);
  ulfius_add_endpoint_by_val(&inst, "DELETE", "/api/todos/:id/", NULL, 0, &h_delete_todo, NULL);

  /* 静态资源与首页 */
  ulfius_add_endpoint_by_val(&inst, "GET", "/",                  NULL, 0, &h_static,  NULL);
  ulfius_add_endpoint_by_val(&inst, "GET", "/static/style.css",  NULL, 0, &h_static,  NULL);
  ulfius_add_endpoint_by_val(&inst, "GET", "/static/main.js",    NULL, 0, &h_static,  NULL);

  /* 健康检查 */
  ulfius_add_endpoint_by_val(&inst, "GET", "/health",            NULL, 0, &h_health,  NULL);

  /* 启动服务（带优雅退出） */
  if (ulfius_start_framework(&inst) == U_OK) {
    fprintf(stderr, "✅ TodoList server on http://localhost:%d  (db=%s, log=%s)\n", port, db_path, log_level);
    fprintf(stderr, "   Health: http://localhost:%d/health\n", port);
    fflush(stderr);

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    while (g_running) {
      sleep(1);
    }
  } else {
    fprintf(stderr, "ulfius start failed\n"); fflush(stderr);
  }

  /* 收尾 */
  ulfius_stop_framework(&inst);
  ulfius_clean_instance(&inst);
  db_close();
  fprintf(stderr, "[i] server stopped.\n"); fflush(stderr);
  return 0;
}
