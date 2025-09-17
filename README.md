
---
# 📌 TodoList (C + Ulfius + SQLite)

一个用 **C 语言 + Ulfius 框架 + SQLite 数据库** 实现的 TodoList Web 服务，包含前后端完整示例，支持 REST API、前端页面、压测脚本。适合用来学习 **C 语言 Web 开发**、**Ulfius 框架**、**SQLite 应用** 以及 **性能测试**。


![Stars](https://img.shields.io/github/stars/xianyudd/todolist-c-ulfius?style=flat-square)
![Forks](https://img.shields.io/github/forks/xianyudd/todolist-c-ulfius?style=flat-square)
![Issues](https://img.shields.io/github/issues/xianyudd/todolist-c-ulfius?style=flat-square)
![License](https://img.shields.io/github/license/xianyudd/todolist-c-ulfius?style=flat-square)
![Language](https://img.shields.io/badge/language-C-orange?style=flat-square)
![Database](https://img.shields.io/badge/database-SQLite-blue?style=flat-square)

## ✨ 功能特性

* ✅ RESTful API（基于 Ulfius）
* ✅ SQLite 数据库存储，简单轻量
* ✅ 前端静态页面（HTML + JS + CSS）
* ✅ 提供 `scripts/` 脚本，支持：

  * 压测 (`wrk` / `vegeta`)
  * 数据库快照保存 / 恢复
  * 自动生成压测报告 (Markdown)
* ✅ 一键编译 & 运行 (`make`)

---

## 📦 依赖库

项目依赖 **Ulfius 框架**及相关库：

| 库           | 作用                                                    |
| ----------- | ----------------------------------------------------- |
| **Ulfius**  | C 语言的 REST API 框架（基于 `libmicrohttpd`），提供 HTTP 路由与响应支持 |
| **Orcania** | Ulfius 的工具库，包含字符串、内存、hash 工具函数                        |
| **Yder**    | Ulfius 的日志库，用于日志输出                                    |
| **SQLite3** | 嵌入式数据库，存储 TodoList 数据                                 |
| **jansson** | JSON 解析与生成库，用于序列化请求/响应                                |

### 开发工具

* **gcc/clang**：C 编译器
* **make**：构建工具
* **pkg-config**：库依赖检测

### 压测工具（可选）

* **wrk**：高性能 HTTP 压测工具
* **vegeta**：灵活的负载测试工具，支持固定速率和混合场景

#### Ubuntu/Debian 安装示例

```bash
sudo apt-get update
sudo apt-get install \
  gcc make pkg-config \
  libulfius-dev liborcania-dev libyder-dev \
  libjansson-dev libsqlite3-dev \
  wrk vegeta
```

#### macOS (Homebrew)

```bash
brew install \
  ulfius orcania yder jansson sqlite \
  wrk vegeta
```

---

## 🚀 快速开始

```bash
git clone https://github.com/xianyudd/todolist-c-ulfius.git
cd todolist-c-ulfius
make
./todolist
```

默认地址: [http://127.0.0.1:8080](http://127.0.0.1:8080)

* 前端页面: `/`
* 健康检查: `/health`
* API 示例:

  * `GET /api/todos?limit=50`
  * `POST /api/todos`

---

## 📊 性能压测

一键压测：

```bash
make suite
```

压测结果会保存在 `bench_out/`，并生成报告。

### 结果汇总

| 测试类型                               | Requests/sec | p50 Latency | p99 Latency | 成功率  |
| ---------------------------------- | ------------ | ----------- | ----------- | ---- |
| **wrk GET**                        | \~5903 req/s | \~10.9 ms   | \~18.3 ms   | 100% |
| **wrk POST**                       | \~7993 req/s | \~1.8 ms    | \~9.7 ms    | 100% |
| **vegeta GET (200 rps)**           | 200 req/s    | \~0.58 ms   | \~0.85 ms   | 100% |
| **vegeta Mix (160 GET + 40 POST)** | 200 req/s    | \~0.62 ms   | \~0.97 ms   | 100% |

### 延迟分布

**GET (wrk)**

* p50: 10.9 ms
* p75: 12.9 ms
* p90: 14.8 ms
* p99: 18.3 ms

**POST (wrk)**

* p50: 1.8 ms
* p75: 3.2 ms
* p90: 5.1 ms
* p99: 9.7 ms

**Vegeta (200 rps)**

* GET: p50 \~0.58 ms, p99 \~0.85 ms
* MIX: p50 \~0.62 ms, p99 \~0.97 ms

👉 轻压场景延迟几乎在 **亚毫秒级**，高并发场景也能保持稳定。

---

## 📂 项目结构

```
todolist-c-ulfius/
├── backend/         # 后端 C 代码 (Ulfius + SQLite)
│   ├── main.c       # 服务入口，路由定义
│   ├── db.c / db.h  # SQLite 封装
├── frontend/        # 前端静态资源
│   ├── index.html   # 页面
│   ├── main.js      # 与 API 交互
│   └── style.css    # 样式
├── scripts/         # 辅助脚本
│   ├── bench.sh     # 压测脚本
│   ├── db_snapshot.sh # 数据库快照
│   └── mk_report.sh # 生成报告
├── Makefile         # 构建脚本
├── README.md        # 项目说明
└── LICENSE          # MIT License
```

---


## 📄 License

MIT License.

