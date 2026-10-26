#!/usr/bin/env python3
"""Консольное приложение «Колледж» — работа с БД college_db (PostgreSQL)."""
import getpass
import os
import sys
from datetime import date

import psycopg2
from psycopg2 import errors

DSN = {
    "host": os.getenv("DB_HOST", "localhost"),
    "port": os.getenv("DB_PORT", "5432"),
    "dbname": os.getenv("DB_NAME", "college_db"),
    "user": os.getenv("DB_USER", "college_app"),
    "password": os.getenv("DB_PASSWORD", "App#Secure2026"),
}

# Какие пункты меню доступны каждой роли
MENU = {
    "role_admin":     ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
    "role_methodist": ["1", "2", "3", "4", "6", "7", "0"],
    "role_teacher":   ["1", "5", "6", "7", "0"],
    "role_analyst":   ["6", "7", "0"],
}
TITLES = {
    "1": "Список студентов группы",
    "2": "Добавить студента",
    "3": "Изменить телефон студента",
    "4": "Перевести студента в другую группу / сменить статус",
    "5": "Выставить оценку",
    "6": "Отчёт: успеваемость группы",
    "7": "Расписание группы на дату",
    "8": "Удалить занятие",
    "9": "Журнал аудита (последние записи)",
    "0": "Выход",
}


class CollegeDB:
    """Тонкая обёртка над соединением: один метод — один запрос или вызов процедуры."""

    def __init__(self, dsn):
        self.conn = psycopg2.connect(**dsn)
        self.conn.autocommit = False
        self.username = None
        self.role = None

    # ---- аутентификация ----
    def login(self, username, password):
        with self.conn.cursor() as cur:
            cur.execute("SELECT fn_authenticate(%s, %s)", (username, password))
            role = cur.fetchone()[0]
        self.conn.commit()                       # счётчик неудачных попыток должен сохраниться
        if role is None:
            return False
        with self.conn.cursor() as cur:
            cur.execute("SET ROLE " + psycopg2.extensions.quote_ident(role, cur))
            cur.execute("SELECT set_config('app.user_name', %s, false)", (username,))
        self.conn.commit()
        self.username, self.role = username, role
        return True

    def _query(self, sql, params=None):
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [d[0] for d in cur.description]
            return cols, cur.fetchall()

    def _call(self, sql, params):
        with self.conn.cursor() as cur:
            cur.execute(sql, params)

    # ---- операции (SELECT / INSERT / UPDATE / DELETE / вызов процедур) ----
    def students_of_group(self, group_name):
        return self._query(
            """SELECT s.student_id, s.last_name, s.first_name, st.name AS status
               FROM students s
               JOIN student_groups g ON g.group_id = s.group_id
               JOIN student_statuses st ON st.status_id = s.status_id
               WHERE g.name = %s ORDER BY s.last_name, s.first_name""", (group_name,))

    def add_student(self, last, first, middle, birth, gender, email, group_name):
        with self.conn.cursor() as cur:
            cur.execute("SELECT group_id, admission_year FROM student_groups WHERE name = %s", (group_name,))
            row = cur.fetchone()
            if row is None:
                raise ValueError(f"Группа «{group_name}» не найдена")
            cur.execute(
                """INSERT INTO students (last_name, first_name, middle_name, birth_date, gender,
                                         email, group_id, enrollment_date)
                   VALUES (%s, %s, NULLIF(%s, ''), %s, %s, %s, %s, make_date(%s, 9, 1))
                   RETURNING student_id""",
                (last, first, middle, birth, gender, email, row[0], row[1]))
            return cur.fetchone()[0]

    def update_phone(self, student_id, phone):
        with self.conn.cursor() as cur:
            cur.execute("UPDATE students SET phone = %s WHERE student_id = %s", (phone, student_id))
            return cur.rowcount

    def transfer(self, student_id, new_group_id):
        self._call("CALL sp_transfer_student(%s, %s)", (student_id, new_group_id))

    def change_status(self, student_id, status_id):
        self._call("CALL sp_change_student_status(%s, %s)", (student_id, status_id))

    def add_grade(self, student_id, lesson_id, value):
        self._call("CALL sp_add_grade(%s, %s, %s)", (student_id, lesson_id, value))

    def group_report(self, group_name):
        return self._query(
            """SELECT r.full_name, r.grades_count, r.avg_grade, r.absences
               FROM student_groups g, LATERAL fn_group_report(g.group_id) r
               WHERE g.name = %s""", (group_name,))

    def schedule(self, group_name, day):
        return self._query(
            """SELECT pair_number, discipline, lesson_type, teacher, room
               FROM v_schedule WHERE group_name = %s AND lesson_date = %s
               ORDER BY pair_number""", (group_name, day))

    def delete_lesson(self, lesson_id):
        with self.conn.cursor() as cur:
            cur.execute("DELETE FROM lessons WHERE lesson_id = %s", (lesson_id,))
            return cur.rowcount

    def audit_tail(self, n=10):
        return self._query(
            """SELECT log_id, changed_at::timestamp(0), table_name, operation, record_id, changed_by
               FROM audit_log ORDER BY log_id DESC LIMIT %s""", (n,))


def print_table(cols, rows):
    if not rows:
        print("  (нет данных)")
        return
    data = [[("" if v is None else str(v)) for v in r] for r in rows]
    widths = [max(len(c), *(len(r[i]) for r in data)) for i, c in enumerate(cols)]
    print("  " + " | ".join(c.ljust(w) for c, w in zip(cols, widths)))
    print("  " + "-+-".join("-" * w for w in widths))
    for r in data:
        print("  " + " | ".join(v.ljust(w) for v, w in zip(r, widths)))


def parse_date(text):
    y, m, d = (int(x) for x in text.split("-"))
    return date(y, m, d)


def run_action(db, choice):
    """Выполняет один пункт меню. Ошибки БД показываются пользователю, откатываются, не роняя программу."""
    try:
        if choice == "1":
            print_table(*db.students_of_group(input("Группа (например, П1-24): ").strip()))
        elif choice == "2":
            sid = db.add_student(input("Фамилия: "), input("Имя: "), input("Отчество (можно пусто): "),
                                 parse_date(input("Дата рождения (ГГГГ-ММ-ДД): ")),
                                 input("Пол (М/Ж): ").strip().upper(), input("E-mail: ").strip(),
                                 input("Группа: ").strip())
            db.conn.commit()
            print(f"  Студент добавлен, id = {sid}")
        elif choice == "3":
            n = db.update_phone(int(input("id студента: ")), input("Новый телефон: ").strip())
            db.conn.commit()
            print("  Обновлено строк:", n)
        elif choice == "4":
            sid = int(input("id студента: "))
            if input("1 — перевод в группу, 2 — смена статуса: ").strip() == "1":
                db.transfer(sid, int(input("id новой группы: ")))
            else:
                db.change_status(sid, int(input("id статуса (1 учится, 2 академ, 3 отчислен): ")))
            db.conn.commit()
            print("  Готово")
        elif choice == "5":
            db.add_grade(int(input("id студента: ")), int(input("id занятия: ")), int(input("Оценка (2–5): ")))
            db.conn.commit()
            print("  Оценка сохранена")
        elif choice == "6":
            print_table(*db.group_report(input("Группа: ").strip()))
        elif choice == "7":
            print_table(*db.schedule(input("Группа: ").strip(), parse_date(input("Дата (ГГГГ-ММ-ДД): "))))
        elif choice == "8":
            n = db.delete_lesson(int(input("id занятия: ")))
            db.conn.commit()
            print("  Удалено занятий:", n, "(связанные оценки и посещаемость удалены каскадно)")
        elif choice == "9":
            print_table(*db.audit_tail())
    except ValueError as e:
        db.conn.rollback()
        print("  Ошибка ввода:", e)
    except errors.InsufficientPrivilege:
        db.conn.rollback()
        print("  Отказано в доступе: у вашей роли нет прав на эту операцию")
    except psycopg2.Error as e:
        db.conn.rollback()
        msg = (e.diag.message_primary or str(e)).strip()
        print("  Ошибка БД:", msg)


def main():
    try:
        db = CollegeDB(DSN)
    except psycopg2.OperationalError as e:
        print("Не удалось подключиться к БД:", str(e).strip())
        return 1

    print("=== Колледж: учёт студентов и успеваемости ===")
    for attempt in range(3):
        user = input("Логин: ").strip()
        pwd = getpass.getpass("Пароль: ") if sys.stdin.isatty() else input("Пароль: ")
        try:
            if db.login(user, pwd):
                break
        except psycopg2.Error as e:
            db.conn.rollback()
            print("  ", (e.diag.message_primary or str(e)).strip())
            return 1
        print("  Неверный логин или пароль")
    else:
        print("Слишком много неудачных попыток")
        return 1

    print(f"Вы вошли как {db.username} (роль {db.role})")
    while True:
        print("\nМеню:")
        for key in MENU[db.role]:
            print(f"  {key}. {TITLES[key]}")
        choice = input("Выберите пункт: ").strip()
        if choice == "0":
            break
        if choice not in MENU[db.role]:
            print("  Пункт недоступен")
            continue
        run_action(db, choice)
    db.conn.close()
    print("До свидания!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
