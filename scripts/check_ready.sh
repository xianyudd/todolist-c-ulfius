#!/usr/bin/env bash
port=$1
url="http://127.0.0.1:${port}/"
retries=${2:-50}
interval=${3:-0.2}

for i in $(seq 1 "$retries"); do
  if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then
    echo "[✓] Service ready on $url"
    exit 0
  fi
  echo "[i] Waiting for $url (attempt $i/$retries)"
  sleep "$interval"
done

echo "[x] Service not ready after $((retries * interval))s"
exit 1
