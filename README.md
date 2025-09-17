# TodoList in C (Ulfius + SQLite)

## 0) Install dependencies (Ubuntu/WSL2)

```bash
sudo apt update
sudo apt install -y build-essential pkg-config libulfius-dev libjansson-dev libsqlite3-dev
```

If `libulfius-dev` is not found, enable `universe` repo:
```bash
sudo add-apt-repository universe
sudo apt update
sudo apt install -y libulfius-dev
```

## 1) Build
```bash
make
```

## 2) Run
```bash
./todolist
```

Open http://localhost:8080/ in your browser.

## 3) API (optional)
- `GET /api/todos`
- `POST /api/todos` body: `{"text":"xxx"}`
- `PUT /api/todos/{id}` body: `{"text":"xxx", "done":true}` (either field is optional)
- `DELETE /api/todos/{id}`

## Notes
- Data stored in `todos.db` (SQLite) in the project root.
- Static files are served from `./frontend`.
```
## 4) 项目结构
```
todolist-c-ulfius/
├── backend/
│   ├── main.c          # Ulfius 入口 + 路由 + 静态文件服务
│   ├── db.c / db.h     # SQLite CRUD 封装
├── frontend/
│   ├── index.html      # 页面
│   ├── main.js         # 调用 /api 的 JS
│   └── style.css       # 样式
├── Makefile            # 一键编译
└── README.md

```