# =========================
# Simple, portable Makefile for todolist bench suite
# =========================
SHELL := /bin/bash
.DEFAULT_GOAL := help

## ====== 新增：编译配置 ======
CC      ?= gcc
CSTD    ?= -std=c11
OPT     ?= -O2
WARN    ?= -Wall -Wextra -Wno-unused-parameter
INCLUDES= -Ibackend

# 依赖库：优先从 pkg-config 获取，失败则退回显式链接
PKGS    := ulfius jansson microhttpd orcania yder sqlite3
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS) 2>/dev/null)
PKG_LIBS   := $(shell pkg-config --libs   $(PKGS) 2>/dev/null)
ifeq ($(strip $(PKG_LIBS)),)
  PKG_LIBS := -lulfius -ljansson -lmicrohttpd -lorcania -lyder -lsqlite3
endif
LDFLAGS ?= $(PKG_LIBS)


CFLAGS  ?= $(CSTD) $(OPT) $(WARN) $(INCLUDES) $(PKG_CFLAGS)
LDFLAGS ?= $(PKG_LIBS)

SRC     := backend/main.c backend/db.c
BIN     := todolist

##@ 配置
SCRIPTS      := scripts
PORT         ?= 8080
DB           ?= todos.db
DUR          ?= 30s
RATE         ?= 200
LIMIT        ?= 50
NAME         ?= baseline
COUNT        ?= 50000
USE_VEGETA   ?= auto
KILL_PORT    ?= 0
OUTDIR       ?= $(shell ls -1td bench_out/* 2>/dev/null | head -1)

ifeq ($(KILL_PORT),1)
KILL_FLAG := --kill-port
endif

## ====== 新增：构建相关目标 ======
build: $(BIN) ## 编译生成 ./todolist
	@echo "[OK] build done: $(BIN)"

$(BIN): $(SRC)
	$(CC) $(CFLAGS) $(SRC) -o $(BIN) $(LDFLAGS)

rebuild: clean build ## 先清理再编译

clean: ## 只清理可执行文件（不动 bench_out/db_snaps）
	@rm -f $(BIN)

##@ 基本
help: ## 显示可用目标与说明
	@echo "Usage: make <target>"; echo; \
	echo "Targets:"; \
	grep -E '^[a-zA-Z0-9_%-]+:.*##' $(MAKEFILE_LIST) | \
	awk -F':.*##[[:space:]]*' '{printf "  %-20s %s\n", $$1, $$2}'; \
	echo; \
	echo "Variables (override via make VAR=value):"; \
	printf "  %-12s %s\n" PORT       "$(PORT)"; \
	printf "  %-12s %s\n" DB         "$(DB)"; \
	printf "  %-12s %s\n" DUR        "$(DUR)"; \
	printf "  %-12s %s\n" RATE       "$(RATE)"; \
	printf "  %-12s %s\n" LIMIT      "$(LIMIT)"; \
	printf "  %-12s %s\n" NAME       "$(NAME)"; \
	printf "  %-12s %s\n" COUNT      "$(COUNT)"; \
	printf "  %-12s %s\n" USE_VEGETA "$(USE_VEGETA)"; \
	printf "  %-12s %s\n" KILL_PORT  "$(KILL_PORT)"; \
	printf "  %-12s %s\n" OUTDIR     "$(OUTDIR)"

help-verbose: ## 显示 help（同上）
	@$(MAKE) -s help

check: ## 检查依赖（curl/wrk；可选 vegeta；库用 pkg-config 尝试探测）
	@for f in $(SCRIPTS)/bench.sh $(SCRIPTS)/collect_bench.sh $(SCRIPTS)/db_snapshot.sh $(SCRIPTS)/bench_suite.py; do \
  		[ -x $$f ] || { echo "[x] missing or not exec: $$f"; exit 1; }; \
	done

	@if [ "$(USE_VEGETA)" != "off" ]; then command -v vegeta >/dev/null 2>&1 || echo "[!] vegeta not installed (optional)"; fi
	@for f in $(SCRIPTS)/bench.sh $(SCRIPTS)/collect_bench.sh $(SCRIPTS)/db_snapshot.sh $(SCRIPTS)/bench_suite.sh; do \
	  [ -x $$f ] || { echo "[x] missing or not exec: $$f"; exit 1; }; \
	done
	@pkg-config --exists $(PKGS) >/dev/null 2>&1 || echo "[!] pkg-config not found or .pc missing, will fallback to direct libs: $(PKG_LIBS)"
	@echo "[OK] deps ready"

env: ## 打印当前变量值
	@echo "PORT=$(PORT)"; echo "DB=$(DB)"; echo "DUR=$(DUR)"; echo "RATE=$(RATE)"; echo "LIMIT=$(LIMIT)"
	@echo "NAME=$(NAME)"; echo "COUNT=$(COUNT)"; echo "USE_VEGETA=$(USE_VEGETA)"; echo "KILL_PORT=$(KILL_PORT)"
	@echo "OUTDIR=$(OUTDIR)"

##@ 运行控制
run: build ## 前台运行服务（Ctrl+C 停止）
	./todolist

stop: ## 停止服务进程
	-@pkill -f ./todolist || true

kill-port: ## 强制释放端口（需要 fuser）
	-@fuser -k $(PORT)/tcp || true

##@ 数据/快照
seed: ## 造数 COUNT 条到 $(DB)
	$(SCRIPTS)/seed_db.sh $(DB) $(COUNT)

db-save: ## 保存数据库快照（NAME=$(NAME))
	$(SCRIPTS)/db_snapshot.sh save $(NAME)

db-restore: ## 恢复数据库快照（NAME=$(NAME))
	$(SCRIPTS)/db_snapshot.sh restore $(NAME)

##@ 压测
bench: build ## 仅执行压测（bench.sh），产物落在 bench_out/<timestamp>
	USE_VEGETA=$(USE_VEGETA) GET_LIMIT=$(LIMIT) $(SCRIPTS)/bench.sh $(DUR)

collect: ## 收集关键指标（从 OUTDIR 或默认最新目录）
	$(SCRIPTS)/collect_bench.sh $(OUTDIR)

pack: ## 打包压测结果目录 OUTDIR 为 .tar.gz
	PACK=1 $(SCRIPTS)/collect_bench.sh $(OUTDIR)

report: ## 生成 Markdown 报告（REPORT.md），默认取 OUTDIR
	$(SCRIPTS)/mk_report.sh $(OUTDIR)

suite: build ## 一键：快照→启服→压测→收集→关服→恢复→报告
	$(SCRIPTS)/bench_suite.py --duration $(DUR) --rate $(RATE) --limit $(LIMIT) $(KILL_FLAG)
	$(MAKE) report OUTDIR=$(shell ls -1td bench_out/* 2>/dev/null | head -1)

full: suite ## full = suite 的别名

##@ 清理
clean-bench: ## 清空 bench_out 目录（谨慎）
	-@rm -rf bench_out/*

.PHONY: help help-verbose check env build rebuild clean run stop kill-port seed db-save db-restore bench collect pack report suite full clean-bench
