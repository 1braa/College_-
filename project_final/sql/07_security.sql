-- =====================================================================
-- 07_security.sql — администрирование и защита: роли, права, хеширование
-- паролей, шифрование персональных данных, настройки аудита
-- Выполнять от имени суперпользователя после скриптов 01–06.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------- 1. Роли ---------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_admin')     THEN CREATE ROLE role_admin     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_methodist') THEN CREATE ROLE role_methodist NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_teacher')   THEN CREATE ROLE role_teacher   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_analyst')   THEN CREATE ROLE role_analyst   NOLOGIN; END IF;
    -- учётная запись, под которой приложение подключается к серверу
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'college_app') THEN
        CREATE ROLE college_app LOGIN NOINHERIT PASSWORD 'App#Secure2026';
    END IF;
END;
$$;

GRANT role_admin, role_methodist, role_teacher, role_analyst TO college_app;

-- ---------- 2. Закрываем доступ по умолчанию -------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL ROUTINES  IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

GRANT USAGE ON SCHEMA public TO role_admin, role_methodist, role_teacher, role_analyst, college_app;

-- ---------- 3. Администратор -----------------------------------------
GRANT ALL ON ALL TABLES    IN SCHEMA public TO role_admin;
GRANT ALL ON ALL ROUTINES  IN SCHEMA public TO role_admin;

-- ---------- 4. Методист (учебная часть) ------------------------------
GRANT SELECT ON specialties, positions, teachers, student_groups, student_statuses, students,
                disciplines, control_types, curriculum, teaching_load, classrooms,
                lessons, grades, attendance TO role_methodist;
GRANT INSERT, UPDATE, DELETE ON students, student_groups, teachers, disciplines, curriculum,
                teaching_load, classrooms, lessons TO role_methodist;
GRANT SELECT ON v_student_card, v_schedule, v_student_performance, v_group_performance,
                v_teacher_workload, v_at_risk_students TO role_methodist;
GRANT EXECUTE ON PROCEDURE sp_transfer_student(INTEGER, INTEGER),
                           sp_change_student_status(INTEGER, INTEGER) TO role_methodist;
GRANT EXECUTE ON FUNCTION fn_student_average(INTEGER), fn_attendance_rate(INTEGER),
                          fn_group_report(INTEGER) TO role_methodist;

-- ---------- 5. Преподаватель -----------------------------------------
-- Контактные данные студентов (телефон, e-mail, адрес) преподавателю недоступны:
-- права на таблицу students выдаются только на отдельные столбцы.
GRANT SELECT (student_id, last_name, first_name, middle_name, group_id, status_id)
      ON students TO role_teacher;
GRANT SELECT (teacher_id, last_name, first_name, middle_name, position_id)
      ON teachers TO role_teacher;
GRANT SELECT ON specialties, student_groups, student_statuses, disciplines, control_types,
                curriculum, teaching_load, classrooms, lessons, grades, attendance TO role_teacher;
GRANT INSERT, UPDATE ON grades, attendance TO role_teacher;
GRANT SELECT ON v_schedule, v_student_performance, v_group_performance TO role_teacher;
GRANT EXECUTE ON PROCEDURE sp_add_grade(INTEGER, INTEGER, INTEGER, VARCHAR),
                           sp_mark_attendance(INTEGER, INTEGER, VARCHAR) TO role_teacher;
GRANT EXECUTE ON FUNCTION fn_student_average(INTEGER), fn_attendance_rate(INTEGER),
                          fn_group_report(INTEGER) TO role_teacher;

-- ---------- 6. Аналитик (только чтение представлений) ----------------
GRANT SELECT ON v_schedule, v_student_performance, v_group_performance, v_teacher_workload,
                v_at_risk_students TO role_analyst;

-- ---------- 7. Учётная запись приложения ------------------------------
GRANT EXECUTE ON FUNCTION fn_authenticate(VARCHAR, TEXT) TO college_app;

-- ---------- 8. Пользователи приложения (пароли хранятся как bcrypt) --
CALL sp_register_user('admin',     'Adm!n2026pass',   'role_admin');
CALL sp_register_user('methodist', 'Meth0dist#2026',  'role_methodist');
CALL sp_register_user('teacher1',  'Teach3r#2026',    'role_teacher', 1);
CALL sp_register_user('analyst',   'An@lyst2026!',    'role_analyst');

-- ---------- 9. Шифрование персональных данных (СНИЛС) -----------------
-- Ключ в реальной системе хранится вне БД (менеджер секретов, переменная окружения).
INSERT INTO student_private (student_id, snils_enc)
SELECT student_id,
       pgp_sym_encrypt(
           lpad(floor(random() * 1000)::int::text, 3, '0') || '-' ||
           lpad(floor(random() * 1000)::int::text, 3, '0') || '-' ||
           lpad(floor(random() * 1000)::int::text, 3, '0') || ' ' ||
           lpad(floor(random() * 100)::int::text, 2, '0'),
           'college-demo-key-2026')
FROM students;

REVOKE ALL ON student_private FROM role_methodist, role_teacher, role_analyst;

-- ---------- 10. Аудит на уровне сервера ------------------------------
-- Журналирование всех изменяющих запросов и подключений; журнал изменений
-- данных ведёт триггер fn_audit (таблица audit_log).
ALTER DATABASE college_db SET log_statement = 'mod';
ALTER SYSTEM SET log_connections = on;       -- параметры уровня сервера задаются через ALTER SYSTEM
ALTER SYSTEM SET log_disconnections = on;
SELECT pg_reload_conf();
