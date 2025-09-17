#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import requests
import signal
from pathlib import Path
import argparse
import shutil

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT_DIR = ROOT_DIR / "scripts"
TODOLIST_BIN = ROOT_DIR / "todolist"

def run_cmd(cmd, check=True, capture=False, env=None):
    print(f"[cmd] {' '.join(map(str, cmd))}")
    return subprocess.run(
        list(map(str, cmd)),
        check=check,
        capture_output=capture,
        text=True,
        env=env
    )

def sanitize_env_for_local_http(base_env=None):
    """屏蔽代理，确保本地 127.0.0.1 直连"""
    env = dict(base_env or os.environ)
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        env.pop(k, None)
    env["NO_PROXY"] = "127.0.0.1,localhost,::1"
    env["no_proxy"] = "127.0.0.1,localhost,::1"
    return env

def find_pids_on_port(port):
    # 尽量不依赖单一工具；ss 优先，退回 lsof
    try:
        out = subprocess.check_output(["ss", "-ltnp"], text=True)
        pids = []
        for line in out.splitlines():
            if f":{port} " in line:
                # e.g. users:(("todolist",pid=12345,fd=5))
                if "pid=" in line:
                    seg = line.split("pid=")[1]
                    pid = ""
                    for ch in seg:
                        if ch.isdigit():
                            pid += ch
                        else:
                            break
                    if pid:
                        pids.append(int(pid))
        return list(set(pids))
    except Exception:
        pass
    # fallback to lsof
    try:
        out = subprocess.check_output(["lsof", "-i", f":{port}", "-sTCP:LISTEN", "-nP"], text=True)
        pids = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) > 1 and parts[1].isdigit():
                pids.append(int(parts[1]))
        return list(set(pids))
    except Exception:
        return []

def kill_port(port):
    pids = find_pids_on_port(port)
    if not pids:
        return
    print(f"[i] Kill processes on port {port}: {pids}")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    # 等一会看看是否退出
    deadline = time.time() + 2.0
    still = []
    while time.time() < deadline:
        time.sleep(0.1)
        still = find_pids_on_port(port)
        if not still:
            break
    if still:
        print(f"[!] SIGKILL on {still}")
        for pid in still:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

def save_snapshot(snap, env):
    outdir = env.get("OUTDIR")
    Path(outdir).mkdir(parents=True, exist_ok=True)
    print(f"=== 1) 保存快照：{snap} ===")
    run_cmd([SCRIPT_DIR / "db_snapshot.sh", "save", snap], env=env)

def restore_snapshot(snap, db_path, env):
    print(f"=== 7) 恢复数据库：{snap} ===")
    r_env = dict(env)
    r_env["DB"] = str(db_path)
    r_env["FORCE"] = "1"
    run_cmd([SCRIPT_DIR / "db_snapshot.sh", "restore", snap], env=r_env)

def start_server(port, db_path, log_path, env):
    print("=== 3) 启动服务（后台）===")
    logf = open(log_path, "w")
    cmd = [
        TODOLIST_BIN,
        "--port", str(port),
        "--db", str(Path(db_path).resolve()),
        "--log-level", "info",
    ]
    # 直接前台子进程 + 输出重定向到文件
    proc = subprocess.Popen(list(map(str, cmd)), stdout=logf, stderr=logf, env=env)
    return proc

def stop_server(proc):
    print("=== 6) 关闭服务 ===")
    try:
        proc.terminate()
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()

def check_ready(url, retries=150, interval=0.2):
    print(f"=== 4) 健康检查 {url} ===")
    for i in range(retries):
        try:
            r = requests.get(url, timeout=1)
            if r.status_code == 200:
                print(f"[✓] 服务就绪 (第{i+1}次尝试)")
                return True
        except requests.RequestException:
            pass
        time.sleep(interval)
    return False

def run_bench(dur, outdir, base, limit, rate, env):
    print(f"=== 5) 执行压测（OUTDIR={outdir}）===")
    b_env = dict(env)
    b_env.update({
        "OUTDIR": str(outdir),
        "BASE": base,                 # bench.sh 会用 BASE 拼 URL
        "GET_LIMIT": str(limit),
        "VEGETA_GET_RATE": str(rate),
    })
    run_cmd([SCRIPT_DIR / "bench.sh", str(dur)], env=b_env)

def collect_report(outdir, env):
    print("=== 8) 收集报告 ===")
    run_cmd([SCRIPT_DIR / "collect_bench.sh", str(outdir)], env=env)
    mk_report = SCRIPT_DIR / "mk_report.sh"
    if mk_report.exists():
        print("=== 9) 生成 Markdown 报告 ===")
        run_cmd([mk_report, str(outdir)], env=env)

def main():
    parser = argparse.ArgumentParser(description="Bench suite (Python版)")
    parser.add_argument("--duration", default="30s", help="压测时长")
    parser.add_argument("--rate", default="200", help="固定RPS")
    parser.add_argument("--limit", default="50", help="分页大小")
    parser.add_argument("--name", default=None, help="结果目录名")
    parser.add_argument("--db", default="todos.db", help="数据库路径")
    parser.add_argument("--port", type=int, default=8080, help="服务端口")
    parser.add_argument("--no-restore", action="store_true", help="不恢复数据库快照")
    parser.add_argument("--kill-port", action="store_true", help="启动前释放端口")
    args = parser.parse_args()

    runname = args.name or f"run_{time.strftime('%Y%m%d-%H%M%S')}"
    outdir = ROOT_DIR / "bench_out" / runname
    log = outdir / "server.log"
    snap = f"prebench_{runname}"

    # 子进程的环境（屏蔽代理 + 设置 no_proxy）
    base_env = sanitize_env_for_local_http(os.environ.copy())
    base_env["OUTDIR"] = str(outdir)

    if args.kill_port:
        print(f"=== 2) 释放端口 {args.port} ===")
        kill_port(args.port)

    save_snapshot(snap, base_env)
    proc = start_server(args.port, args.db, log, base_env)

    health_url = f"http://127.0.0.1:{args.port}/health"
    if not check_ready(health_url):
        print("[x] 服务未就绪，退出。日志最后 100 行：")
        if log.exists():
            run_cmd(["tail", "-n", "100", str(log)], check=False)
        stop_server(proc)
        if not args.no_restore:
            restore_snapshot(snap, args.db, base_env)
        sys.exit(1)

    base = f"http://127.0.0.1:{args.port}"
    try:
        run_bench(args.duration, outdir, base, args.limit, args.rate, base_env)
    finally:
        stop_server(proc)
        if not args.no_restore:
            restore_snapshot(snap, args.db, base_env)
        collect_report(outdir, base_env)
        print(f"[✓] 完成：{runname}")

if __name__ == "__main__":
    main()
