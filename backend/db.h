#ifndef TODO_DB_H
#define TODO_DB_H

#include <jansson.h>
#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

int db_open(const char *path);
void db_close();
int db_init();

// 返回值：0 成功，非0 失败。成功时 out_json 会被填充（需由调用方 json_decref）
int db_list(json_t **out_json);
int db_create(const char *text, json_t **out_json);
// done_flag: -1 表示不更新；0/1 表示设置；text = NULL 表示不更新文本
int db_update(int id, const char *text, int done_flag, json_t **out_json);
int db_delete(int id);
int db_list_paged(int limit, int offset, json_t **out_json);

#ifdef __cplusplus
}
#endif

#endif // TODO_DB_H