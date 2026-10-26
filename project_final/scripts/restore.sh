#!/bin/sh
# Восстановление: scripts/restore.sh файл.dump имя_новой_базы
set -e
[ $# -eq 2 ] || { echo "Использование: $0 файл.dump имя_базы"; exit 1; }
createdb -E UTF8 -T template0 --locale=C.UTF-8 "$2"
pg_restore --no-owner --no-privileges -d "$2" "$1"
echo "Восстановлено в базу $2"
