#!/bin/bash

BASE_URL="http://localhost:8080/api/todos"

echo "=== 1. 新增任务 ==="
curl -s -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{"text":"买牛奶"}' | jq

curl -s -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{"text":"写代码"}' | jq

echo
echo "=== 2. 获取任务列表 ==="
curl -s "$BASE_URL" | jq

echo
echo "=== 3. 更新第1个任务为完成状态 ==="
curl -s -X PUT "$BASE_URL/1" \
  -H "Content-Type: application/json" \
  -d '{"done":true}' | jq

echo
echo "=== 4. 再次获取任务列表 ==="
curl -s "$BASE_URL" | jq

echo
echo "=== 5. 删除第2个任务 ==="
curl -s -X DELETE "$BASE_URL/2" | jq

echo
echo "=== 6. 最终任务列表 ==="
curl -s "$BASE_URL" | jq

