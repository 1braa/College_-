# БД «Колледж: студенты, группы, оценки» (PostgreSQL 16 + Python)

Учебная практика ПМ.11, специальность 09.02.07, группа П1-24, Сафаров Ибрагим

## Быстрый старт
1. Установите PostgreSQL 16 и Python 3.10+, затем `pip install -r requirements.txt`.
2. От имени суперпользователя: `scripts/rebuild.sh` — создаёт БД `college_db`, выполняет `sql/01…07`, грузит данные.
3. Запуск приложения: оконная версия `python3 app/college_gui.py` или консольная `python3 app/college_app.py` (параметры — переменные окружения, см. `.env.example`). Для окна нужен tkinter (на Linux: `sudo apt install python3-tk`; на Windows и macOS входит в Python).

## Демонстрационные пользователи
| Логин     | Пароль         | Роль           |
|-----------|----------------|----------------|
| admin     | Adm!n2026pass  | role_admin     |
| methodist | Meth0dist#2026 | role_methodist |
| teacher1  | Teach3r#2026   | role_teacher   |
| analyst   | An@lyst2026!   | role_analyst   |

## Тесты и замеры
- `python3 tests/run_tests.py` — 25 тест-кейсов (с откатом, данные не меняются);
- `python3 tests/perf_backup.py` — EXPLAIN до/после, pgbench, backup/restore;
- резервная копия: `scripts/backup.sh`, восстановление: `scripts/restore.sh файл.dump новая_база`.

## Структура
`sql/` скрипты 01–07, `app/` приложение, `scripts/` сопровождение, `tests/` тесты, `docs/` диаграммы и отчёт, `backup/` копия БД.
