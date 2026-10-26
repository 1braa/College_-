"""Тест-кейсы БД «Колледж». Каждый тест выполняется в отдельной транзакции с
откатом, поэтому данные не меняются. Результаты пишутся в docs/checks.json.
Запуск:  su postgres -c "python3 tests/run_tests.py"
"""
import json, os, datetime, decimal
import psycopg2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Подключение через переменные окружения PGHOST / PGUSER / PGPASSWORD (по умолчанию —
# локальный сокет и текущий пользователь ОС). Нужен суперпользователь (SET ROLE в тестах).
conn = psycopg2.connect(dbname=os.getenv("DB_NAME", "college_db"))
cur = conn.cursor()


def fmt(v):
    if isinstance(v, decimal.Decimal):
        return format(v, "f")
    if isinstance(v, (datetime.date, datetime.datetime)):
        return v.isoformat()[:19]
    return v


def q(sql, params=None):
    cur.execute(sql, params)
    return cur.fetchall()


def attempt(statements, role=None, user_name=None):
    """Выполняет список SQL в транзакции, возвращает (ok, last_result_or_error)."""
    result = None
    try:
        if role:
            cur.execute(f"SET LOCAL ROLE {role}")
        if user_name:
            cur.execute("SELECT set_config('app.user_name', %s, true)", (user_name,))
        for st in statements:
            sql, params = (st, None) if isinstance(st, str) else st
            cur.execute(sql, params)
            if cur.description:
                result = [[fmt(v) for v in r] for r in cur.fetchall()]
        return True, result
    except psycopg2.Error as e:
        msg = (e.pgerror or str(e)).split("\n")[0].replace("ERROR:  ", "")
        return False, f"{msg} [SQLSTATE {e.pgcode}]"
    finally:
        conn.rollback()


# ---------- подбор тестовых данных ----------
# занятие и студент из его группы, у которого за это занятие нет оценки
lesson_id, student_ok, group_id = q("""
    SELECT l.lesson_id, s.student_id, tl.group_id
    FROM lessons l JOIN teaching_load tl ON tl.load_id = l.load_id
    JOIN students s ON s.group_id = tl.group_id AND s.status_id = 1
    WHERE NOT EXISTS (SELECT 1 FROM grades g WHERE g.student_id = s.student_id AND g.lesson_id = l.lesson_id)
    ORDER BY l.lesson_id, s.student_id LIMIT 1""")[0]
# студент другой группы
student_other = q("SELECT student_id FROM students WHERE group_id <> %s AND status_id = 1 ORDER BY student_id LIMIT 1", (group_id,))[0][0]
# отчисленный студент и обучающийся студент для тестов статуса
student_expelled = q("SELECT student_id FROM students WHERE status_id = 3 ORDER BY student_id LIMIT 1")[0][0]
student_active = q("SELECT student_id FROM students WHERE status_id = 1 AND group_id = %s ORDER BY student_id LIMIT 1", (group_id,))[0][0]
# занятие, на котором у группы уже есть пара — для теста конфликта
cf = q("""SELECT l.load_id, l.lesson_date, l.pair_number, l.classroom_id, tl.group_id
          FROM lessons l JOIN teaching_load tl ON tl.load_id = l.load_id ORDER BY l.lesson_id LIMIT 1""")[0]
# другая нагрузка той же группы, но иная дисциплина, и другая аудитория
other_load = q("SELECT load_id FROM teaching_load WHERE group_id = %s AND load_id <> %s ORDER BY load_id LIMIT 1", (cf[4], cf[0]))[0][0]
other_room = q("SELECT classroom_id FROM classrooms WHERE classroom_id <> %s ORDER BY classroom_id LIMIT 1", (cf[3],))[0][0]
# нагрузка другой группы и другого преподавателя, свободных в ту же пару, — чтобы сработал именно UNIQUE по аудитории
free_load = q("""SELECT tl.load_id FROM teaching_load tl
    WHERE tl.group_id <> %s
      AND NOT EXISTS (SELECT 1 FROM lessons l JOIN teaching_load t2 ON t2.load_id = l.load_id
                      WHERE l.lesson_date = %s AND l.pair_number = %s
                        AND (t2.group_id = tl.group_id OR t2.teacher_id = tl.teacher_id))
    ORDER BY tl.load_id LIMIT 1""", (cf[4], cf[1], cf[2]))[0][0]
new_group = q("SELECT group_id FROM student_groups WHERE group_id <> %s ORDER BY group_id LIMIT 1", (group_id,))[0][0]
lesson_with_children = q("""SELECT l.lesson_id FROM lessons l
    WHERE EXISTS (SELECT 1 FROM grades g WHERE g.lesson_id = l.lesson_id)
    ORDER BY l.lesson_id LIMIT 1""")[0][0]

tests = []


def add(tc, title, sql_text, expected, ok_expected, statements, **kw):
    ok, res = attempt(statements, **kw)
    if ok_expected:
        passed = ok
        actual = res if res is not None else "Операция выполнена без ошибок"
    else:
        passed = not ok
        actual = res if not ok else "Ошибка не возникла"
    tests.append(dict(id=tc, title=title, sql=sql_text, expected=expected,
                      actual=actual if isinstance(actual, str) else json.dumps(actual, ensure_ascii=False),
                      passed=bool(passed)))


add("TC-01", "Выставление корректной оценки",
    f"CALL sp_add_grade({student_ok}, {lesson_id}, 5)", "Оценка добавлена", True,
    [(f"CALL sp_add_grade(%s, %s, 5)", (student_ok, lesson_id)),
     ("SELECT grade_value, grade_kind FROM grades WHERE student_id=%s AND lesson_id=%s", (student_ok, lesson_id))])
add("TC-02", "Оценка вне диапазона 2–5",
    f"CALL sp_add_grade({student_ok}, {lesson_id}, 6)", "Ошибка: оценка должна быть в диапазоне 2–5", False,
    [(f"CALL sp_add_grade(%s, %s, 6)", (student_ok, lesson_id))])
add("TC-03", "Оценка студенту, не относящемуся к группе занятия",
    f"CALL sp_add_grade({student_other}, {lesson_id}, 4)", "Ошибка триггера trg_grades_check", False,
    [(f"CALL sp_add_grade(%s, %s, 4)", (student_other, lesson_id))])
add("TC-04", "Оценка несуществующему студенту",
    f"CALL sp_add_grade(999999, {lesson_id}, 4)", "Ошибка: студент не найден", False,
    [(f"CALL sp_add_grade(999999, %s, 4)", (lesson_id,))])
add("TC-05", "Конфликт расписания группы (две пары одновременно)",
    "INSERT INTO lessons (load_id, classroom_id, lesson_date, pair_number, lesson_type) …",
    "Ошибка триггера trg_lessons_conflict", False,
    [("INSERT INTO lessons (load_id, classroom_id, lesson_date, pair_number, lesson_type) VALUES (%s,%s,%s,%s,'Практика')",
      (other_load, other_room, cf[1], cf[2]))])
add("TC-06", "Одна аудитория занята двумя занятиями одновременно",
    "INSERT INTO lessons (…) с теми же classroom_id, lesson_date, pair_number",
    "Нарушение UNIQUE (classroom_id, lesson_date, pair_number)", False,
    [("INSERT INTO lessons (load_id, classroom_id, lesson_date, pair_number, lesson_type) VALUES (%s,%s,%s,%s,'Практика')",
      (free_load, cf[3], cf[1], cf[2]))])
add("TC-07", "Отчисление студента: автоматическая дата отчисления",
    f"CALL sp_change_student_status({student_active}, 3)",
    "status_id = 3, expelled_date = текущая дата", True,
    [(f"CALL sp_change_student_status(%s, 3)", (student_active,)),
     ("SELECT status_id, expelled_date = CURRENT_DATE AS date_is_today FROM students WHERE student_id=%s", (student_active,))])
add("TC-08", "Оценка отчисленному студенту",
    f"INSERT INTO grades … student_id = {student_expelled}",
    "Ошибка: студент не обучается", False,
    [("""INSERT INTO grades (student_id, lesson_id, grade_value)
         SELECT %s, l.lesson_id, 4 FROM lessons l JOIN teaching_load tl ON tl.load_id=l.load_id
         WHERE tl.group_id = (SELECT group_id FROM students WHERE student_id=%s) LIMIT 1""", (student_expelled, student_expelled))])
add("TC-09", "Перевод студента в ту же группу",
    f"CALL sp_transfer_student({student_active}, {group_id})", "Ошибка: студент уже в этой группе", False,
    [(f"CALL sp_transfer_student(%s, %s)", (student_active, group_id))])
add("TC-10", "Перевод студента в другую группу",
    f"CALL sp_transfer_student({student_active}, {new_group})", "group_id студента изменился", True,
    [(f"CALL sp_transfer_student(%s, %s)", (student_active, new_group)),
     ("SELECT group_id FROM students WHERE student_id=%s", (student_active,))])
add("TC-11", "Аутентификация с верным паролем",
    "SELECT fn_authenticate('admin', 'Adm!n2026pass')", "Возвращается роль role_admin", True,
    [("SELECT fn_authenticate('admin', 'Adm!n2026pass')", None)])
add("TC-12", "Аутентификация с неверным паролем",
    "SELECT fn_authenticate('admin', 'wrong')", "Возвращается NULL", True,
    [("SELECT fn_authenticate('admin', 'wrong')", None)])
add("TC-13", "Блокировка учётной записи после 5 неверных попыток",
    "6 вызовов fn_authenticate('analyst', 'bad…')", "Ошибка: учётная запись заблокирована", False,
    [("SELECT fn_authenticate('analyst', 'bad1')", None)] * 5 + [("SELECT fn_authenticate('analyst', 'An@lyst2026!')", None)])
add("TC-14", "Пароль хранится в виде bcrypt-хеша, а не открытым текстом",
    "SELECT password_hash LIKE '$2%' AND password_hash <> 'Adm!n2026pass' FROM app_users WHERE username='admin'",
    "true", True,
    [("SELECT password_hash LIKE '$2%' AND password_hash <> 'Adm!n2026pass' FROM app_users WHERE username='admin'", None)])
add("TC-15", "Преподаватель не может удалять студентов",
    "SET ROLE role_teacher; DELETE FROM students WHERE student_id = 1",
    "permission denied", False,
    [("DELETE FROM students WHERE student_id = 1", None)], role="role_teacher")
add("TC-16", "Преподаватель не видит телефон студента (права на уровне столбцов)",
    "SET ROLE role_teacher; SELECT phone FROM students LIMIT 1", "permission denied", False,
    [("SELECT phone FROM students LIMIT 1", None)], role="role_teacher")
add("TC-17", "Аналитик не имеет доступа к таблице оценок",
    "SET ROLE role_analyst; SELECT * FROM grades", "permission denied", False,
    [("SELECT * FROM grades", None)], role="role_analyst")
add("TC-18", "Аналитик читает представление успеваемости",
    "SET ROLE role_analyst; SELECT * FROM v_group_performance", "Данные возвращаются", True,
    [("SELECT count(*) FROM v_group_performance", None)], role="role_analyst")
add("TC-19", "Преподаватель выставляет оценку через процедуру",
    f"SET ROLE role_teacher; CALL sp_add_grade({student_ok}, {lesson_id}, 4)", "Оценка добавлена", True,
    [(f"CALL sp_add_grade(%s, %s, 4)", (student_ok, lesson_id)),
     ("SELECT grade_value FROM grades WHERE student_id=%s AND lesson_id=%s", (student_ok, lesson_id))],
    role="role_teacher", user_name="teacher1")
add("TC-20", "Методист не имеет доступа к журналу аудита",
    "SET ROLE role_methodist; SELECT * FROM audit_log", "permission denied", False,
    [("SELECT * FROM audit_log", None)], role="role_methodist")
add("TC-21", "Каскадное удаление занятия удаляет связанные оценки",
    f"DELETE FROM lessons WHERE lesson_id = {lesson_with_children}", "Оценок по занятию не остаётся (0)", True,
    [("DELETE FROM lessons WHERE lesson_id = %s", (lesson_with_children,)),
     ("SELECT count(*) FROM grades WHERE lesson_id = %s", (lesson_with_children,))])
add("TC-22", "Некорректный e-mail студента (CHECK)",
    "INSERT INTO students (…, email) VALUES (…, 'not-an-email')", "Нарушение CHECK-ограничения", False,
    [("""INSERT INTO students (last_name, first_name, birth_date, gender, email, group_id, enrollment_date)
         VALUES ('Тестов','Тест','2007-01-01','М','not-an-email',1,'2026-09-01')""", None)])
add("TC-23", "Дубликат e-mail студента (UNIQUE)",
    "INSERT INTO students (…, email) с уже существующим e-mail", "Нарушение UNIQUE", False,
    [("""INSERT INTO students (last_name, first_name, birth_date, gender, email, group_id, enrollment_date)
         VALUES ('Тестов','Тест','2007-01-01','М',(SELECT email FROM students LIMIT 1),1,'2026-09-01')""", None)])
add("TC-24", "Расшифровка СНИЛС верным ключом",
    "SELECT fn_decrypt_snils(1, 'college-demo-key-2026')", "Возвращается строка формата ХХХ-ХХХ-ХХХ ХХ", True,
    [("SELECT fn_decrypt_snils(1, 'college-demo-key-2026') ~ '^[0-9]{3}-[0-9]{3}-[0-9]{3} [0-9]{2}$'", None)])
add("TC-25", "Расшифровка СНИЛС неверным ключом",
    "SELECT fn_decrypt_snils(1, 'wrong-key')", "Ошибка pgcrypto", False,
    [("SELECT fn_decrypt_snils(1, 'wrong-key')", None)])

# ---------- демонстрации ----------
demo = {}
# аудит
conn.rollback()
cur.execute("SELECT set_config('app.user_name', 'methodist', true)")
cur.execute("UPDATE students SET phone = '+7 900 000-00-00' WHERE student_id = 1")
cur.execute("""SELECT log_id > 0 AS ok, table_name, operation, record_id, changed_by,
                      old_data ->> 'phone' AS old_phone, new_data ->> 'phone' AS new_phone
               FROM audit_log ORDER BY log_id DESC LIMIT 1""")
demo["audit"] = {"cols": [d[0] for d in cur.description], "rows": [[fmt(v) for v in r] for r in cur.fetchall()]}
conn.rollback()

# функции
fn = {}
for name, sql in [
    ("fn_student_average", "SELECT fn_student_average(1)"),
    ("fn_attendance_rate", "SELECT fn_attendance_rate(%s)" % q("SELECT student_id FROM attendance GROUP BY student_id ORDER BY count(*) DESC, student_id LIMIT 1")[0][0]),
]:
    cur.execute(sql)
    fn[name] = {"sql": sql, "result": fmt(cur.fetchone()[0])}
cur.execute("SELECT * FROM fn_group_report(2) LIMIT 5")
fn["fn_group_report"] = {"sql": "SELECT * FROM fn_group_report(2) LIMIT 5",
                         "cols": [d[0] for d in cur.description],
                         "rows": [[fmt(v) for v in r] for r in cur.fetchall()]}
demo["functions"] = fn
conn.rollback()

# итоговые счётчики и проверки целостности
tables = ["specialties", "positions", "teachers", "student_groups", "student_statuses", "students",
          "disciplines", "control_types", "curriculum", "teaching_load", "classrooms",
          "lessons", "grades", "attendance", "app_users", "student_private", "audit_log"]
counts = [[t, q(f"SELECT count(*) FROM {t}")[0][0]] for t in tables]
integrity = []
checks = [
    ("Оценки студентам не из группы занятия",
     """SELECT count(*) FROM grades g JOIN students s ON s.student_id=g.student_id
        JOIN lessons l ON l.lesson_id=g.lesson_id JOIN teaching_load tl ON tl.load_id=l.load_id
        WHERE s.group_id <> tl.group_id"""),
    ("Отметки посещаемости студентам не из группы занятия",
     """SELECT count(*) FROM attendance a JOIN students s ON s.student_id=a.student_id
        JOIN lessons l ON l.lesson_id=a.lesson_id JOIN teaching_load tl ON tl.load_id=l.load_id
        WHERE s.group_id <> tl.group_id"""),
    ("Группы с двумя занятиями в одну пару",
     """SELECT count(*) FROM (SELECT tl.group_id, l.lesson_date, l.pair_number FROM lessons l
        JOIN teaching_load tl ON tl.load_id=l.load_id GROUP BY 1,2,3 HAVING count(*)>1) x"""),
    ("Преподаватели с двумя занятиями в одну пару",
     """SELECT count(*) FROM (SELECT tl.teacher_id, l.lesson_date, l.pair_number FROM lessons l
        JOIN teaching_load tl ON tl.load_id=l.load_id GROUP BY 1,2,3 HAVING count(*)>1) x"""),
    ("Отчисленные студенты без даты отчисления",
     "SELECT count(*) FROM students WHERE status_id = 3 AND expelled_date IS NULL"),
    ("Нагрузка по дисциплинам вне учебного плана специальности",
     """SELECT count(*) FROM teaching_load tl JOIN student_groups g ON g.group_id=tl.group_id
        WHERE NOT EXISTS (SELECT 1 FROM curriculum c WHERE c.specialty_id=g.specialty_id AND c.discipline_id=tl.discipline_id)"""),
    ("Оценки вне диапазона 2–5", "SELECT count(*) FROM grades WHERE grade_value NOT BETWEEN 2 AND 5"),
    ("Студенты без группы (нарушение ссылочной целостности)",
     "SELECT count(*) FROM students s WHERE NOT EXISTS (SELECT 1 FROM student_groups g WHERE g.group_id=s.group_id)"),
]
for name, sql in checks:
    integrity.append([name, q(sql)[0][0]])

out = {"tests": tests, "demo": demo, "counts": counts, "integrity": integrity}
os.makedirs(f"{ROOT}/docs", exist_ok=True)
json.dump(out, open(f"{ROOT}/docs/checks.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("=== Тесты БД «Колледж» ===")
for t in tests:
    print(f'{t["id"]}  {"ПРОЙДЕН " if t["passed"] else "НЕ ПРОЙДЕН"}  {t["title"]}')
    print(f'        ожидалось: {t["expected"]}')
    print(f'        получено : {t["actual"][:110]}')
print("=== Проверки целостности (должно быть 0) ===")
for name, v in integrity:
    print(f"{v:>4}  {name}")
print("ИТОГО: пройдено", sum(t["passed"] for t in tests), "из", len(tests))
