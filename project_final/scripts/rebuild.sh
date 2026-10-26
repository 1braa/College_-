#!/bin/sh
# Полная пересборка БД college_db (запускать от суперпользователя postgres)
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
dropdb --if-exists college_db
createdb -E UTF8 -T template0 --locale=C.UTF-8 college_db 2>/dev/null \
  || createdb -E UTF8 -T template0 --locale=en_US.UTF-8 college_db   # запасной вариант для macOS
for f in 01_schema 02_triggers 03_data 04_routines 06_views_advanced 07_security; do
  echo "== $f"; psql -q -d college_db -v ON_ERROR_STOP=1 -f "$DIR/sql/$f.sql"
done
