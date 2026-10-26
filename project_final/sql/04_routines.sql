-- =====================================================================
-- 04_routines.sql — серверная логика: функции и хранимые процедуры
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------- 1. Средний балл студента ---------------------------------
CREATE OR REPLACE FUNCTION fn_student_average(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_avg NUMERIC;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Студент с id=% не найден', p_student_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT round(avg(grade_value), 2) INTO v_avg
    FROM grades WHERE student_id = p_student_id;
    RETURN v_avg;                       -- NULL, если оценок ещё нет
END;
$$;

-- ---------- 2. Процент посещаемости студента -------------------------
CREATE OR REPLACE FUNCTION fn_attendance_rate(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT round(100.0 * count(*) FILTER (WHERE status IN ('Присутствовал', 'Опоздал'))
                 / NULLIF(count(*), 0), 1)
    FROM attendance WHERE student_id = p_student_id;
$$;

-- ---------- 3. Отчёт по успеваемости группы --------------------------
CREATE OR REPLACE FUNCTION fn_group_report(p_group_id INTEGER)
RETURNS TABLE (student_id INTEGER, full_name TEXT, grades_count BIGINT,
               avg_grade NUMERIC, absences BIGINT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
    IF NOT EXISTS (SELECT 1 FROM student_groups WHERE group_id = p_group_id) THEN
        RAISE EXCEPTION 'Группа с id=% не найдена', p_group_id
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT s.student_id,
           s.last_name || ' ' || s.first_name,
           (SELECT count(*) FROM grades g WHERE g.student_id = s.student_id),
           (SELECT round(avg(g.grade_value), 2) FROM grades g WHERE g.student_id = s.student_id),
           (SELECT count(*) FROM attendance a
             WHERE a.student_id = s.student_id AND a.status = 'Отсутствовал')
    FROM students s
    WHERE s.group_id = p_group_id
    ORDER BY s.last_name, s.first_name;
END;
$$;

-- ---------- 4. Выставление оценки (добавление или исправление) -------
CREATE OR REPLACE PROCEDURE sp_add_grade(
    p_student_id INTEGER, p_lesson_id INTEGER, p_value INTEGER,
    p_kind VARCHAR DEFAULT 'Текущая')
LANGUAGE plpgsql AS $$
BEGIN
    IF p_value IS NULL OR p_value NOT BETWEEN 2 AND 5 THEN
        RAISE EXCEPTION 'Оценка должна быть в диапазоне 2–5 (получено: %)', p_value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Студент с id=% не найден', p_student_id USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM lessons WHERE lesson_id = p_lesson_id) THEN
        RAISE EXCEPTION 'Занятие с id=% не найдено', p_lesson_id USING ERRCODE = 'no_data_found';
    END IF;

    -- принадлежность студента группе занятия проверяет триггер trg_grades_check
    INSERT INTO grades (student_id, lesson_id, grade_value, grade_kind)
    VALUES (p_student_id, p_lesson_id, p_value, p_kind)
    ON CONFLICT (student_id, lesson_id)
    DO UPDATE SET grade_value = EXCLUDED.grade_value,
                  grade_kind  = EXCLUDED.grade_kind,
                  graded_at   = now();
END;
$$;

-- ---------- 5. Отметка посещаемости ----------------------------------
CREATE OR REPLACE PROCEDURE sp_mark_attendance(
    p_lesson_id INTEGER, p_student_id INTEGER, p_status VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO attendance (lesson_id, student_id, status)
    VALUES (p_lesson_id, p_student_id, p_status)
    ON CONFLICT (lesson_id, student_id)
    DO UPDATE SET status = EXCLUDED.status;
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION 'Недопустимый статус посещаемости: %', p_status;
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Студент (%) или занятие (%) не существует', p_student_id, p_lesson_id;
END;
$$;

-- ---------- 6. Перевод студента в другую группу ----------------------
CREATE OR REPLACE PROCEDURE sp_transfer_student(p_student_id INTEGER, p_new_group_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_old_group INTEGER;
    v_status    INTEGER;
BEGIN
    SELECT group_id, status_id INTO v_old_group, v_status
    FROM students WHERE student_id = p_student_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Студент с id=% не найден', p_student_id USING ERRCODE = 'no_data_found';
    END IF;
    IF v_status = 3 THEN
        RAISE EXCEPTION 'Отчисленного студента (id=%) переводить нельзя', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM student_groups WHERE group_id = p_new_group_id) THEN
        RAISE EXCEPTION 'Группа с id=% не найдена', p_new_group_id USING ERRCODE = 'no_data_found';
    END IF;
    IF v_old_group = p_new_group_id THEN
        RAISE EXCEPTION 'Студент уже обучается в этой группе';
    END IF;

    UPDATE students SET group_id = p_new_group_id WHERE student_id = p_student_id;
    RAISE NOTICE 'Студент % переведён из группы % в группу %', p_student_id, v_old_group, p_new_group_id;
END;
$$;

-- ---------- 7. Смена статуса студента (отчисление, академ и т. д.) ---
CREATE OR REPLACE PROCEDURE sp_change_student_status(p_student_id INTEGER, p_status_id INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM student_statuses WHERE status_id = p_status_id) THEN
        RAISE EXCEPTION 'Статус с id=% не существует', p_status_id USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE students SET status_id = p_status_id WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Студент с id=% не найден', p_student_id USING ERRCODE = 'no_data_found';
    END IF;
    -- дату отчисления проставит триггер trg_students_status
END;
$$;

-- ---------- 8. Регистрация пользователя приложения -------------------
CREATE OR REPLACE PROCEDURE sp_register_user(
    p_username VARCHAR, p_password TEXT, p_role VARCHAR, p_teacher_id INTEGER DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF length(p_password) < 8 THEN
        RAISE EXCEPTION 'Пароль должен содержать не менее 8 символов';
    END IF;

    INSERT INTO app_users (username, password_hash, role_name, teacher_id)
    VALUES (p_username, crypt(p_password, gen_salt('bf', 10)), p_role, p_teacher_id);
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Пользователь "%" уже существует', p_username;
    WHEN check_violation THEN
        RAISE EXCEPTION 'Недопустимая роль: %', p_role;
END;
$$;

-- ---------- 9. Аутентификация ----------------------------------------
-- Возвращает имя роли при успехе, NULL — при неверном логине/пароле.
-- После 5 неудачных попыток подряд учётная запись блокируется.
CREATE OR REPLACE FUNCTION fn_authenticate(p_username VARCHAR, p_password TEXT)
RETURNS VARCHAR
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user app_users%ROWTYPE;
BEGIN
    SELECT * INTO v_user FROM app_users WHERE username = p_username;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF NOT v_user.is_active OR v_user.failed_attempts >= 5 THEN
        RAISE EXCEPTION 'Учётная запись заблокирована' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_user.password_hash = crypt(p_password, v_user.password_hash) THEN
        UPDATE app_users SET failed_attempts = 0, last_login = now() WHERE user_id = v_user.user_id;
        RETURN v_user.role_name;
    END IF;

    UPDATE app_users SET failed_attempts = failed_attempts + 1 WHERE user_id = v_user.user_id;
    RETURN NULL;
END;
$$;

-- ---------- 10. Расшифровка СНИЛС (только для администратора) --------
CREATE OR REPLACE FUNCTION fn_decrypt_snils(p_student_id INTEGER, p_key TEXT)
RETURNS TEXT
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT pgp_sym_decrypt(snils_enc, p_key) FROM student_private WHERE student_id = p_student_id;
$$;
