#!/bin/sh
# Резервная копия БД college_db в формате custom (сжатие). Запуск от суперпользователя postgres.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$DIR/backup/college_db_$(date +%Y%m%d_%H%M%S).dump}"
mkdir -p "$(dirname "$OUT")"
pg_dump -Fc -Z 6 -f "$OUT" college_db
echo "Резервная копия создана: $OUT"
