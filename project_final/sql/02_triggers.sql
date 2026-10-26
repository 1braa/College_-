-- =====================================================================
-- 02_triggers.sql — триггеры: аудит, бизнес-правила, каскадные действия
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------- 1. Универсальный аудит изменений -------------------------
-- Аргумент триггера — имя столбца первичного ключа таблицы.
CREATE OR REPLACE FUNCTION fn_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_row JSONB;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_row := to_jsonb(OLD);
    ELSE
        v_row := to_jsonb(NEW);
    END IF;

    INSERT INTO audit_log (table_name, operation, record_id, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME,
            left(TG_OP, 1),
            v_row ->> TG_ARGV[0],
            CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END,
            -- имя пользователя приложения передаётся через set_config('app.user_name', ...)
            COALESCE(NULLIF(current_setting('app.user_name', true), ''), session_user));
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_students
    AFTER INSERT OR UPDATE OR DELETE ON students
    FOR EACH ROW EXECUTE FUNCTION fn_audit('student_id');

CREATE TRIGGER trg_audit_grades
    AFTER INSERT OR UPDATE OR DELETE ON grades
    FOR EACH ROW EXECUTE FUNCTION fn_audit('grade_id');

CREATE TRIGGER trg_audit_lessons
    AFTER INSERT OR UPDATE OR DELETE ON lessons
    FOR EACH ROW EXECUTE FUNCTION fn_audit('lesson_id');

-- ---------- 2. Проверка конфликтов расписания ------------------------
-- Бизнес-правило: у группы и у преподавателя не может быть двух занятий
-- в одну и ту же пару одного дня.
CREATE OR REPLACE FUNCTION fn_check_lesson_conflict() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_group   INTEGER;
    v_teacher INTEGER;
BEGIN
    SELECT group_id, teacher_id INTO v_group, v_teacher
    FROM teaching_load WHERE load_id = NEW.load_id;

    IF EXISTS (SELECT 1
               FROM lessons l
               JOIN teaching_load t ON t.load_id = l.load_id
               WHERE l.lesson_date = NEW.lesson_date
                 AND l.pair_number = NEW.pair_number
                 AND l.lesson_id IS DISTINCT FROM NEW.lesson_id
                 AND t.group_id = v_group) THEN
        RAISE EXCEPTION 'Конфликт расписания: у группы (id=%) уже есть занятие % (пара %)',
            v_group, NEW.lesson_date, NEW.pair_number;
    END IF;

    IF EXISTS (SELECT 1
               FROM lessons l
               JOIN teaching_load t ON t.load_id = l.load_id
               WHERE l.lesson_date = NEW.lesson_date
                 AND l.pair_number = NEW.pair_number
                 AND l.lesson_id IS DISTINCT FROM NEW.lesson_id
                 AND t.teacher_id = v_teacher) THEN
        RAISE EXCEPTION 'Конфликт расписания: преподаватель (id=%) занят % (пара %)',
            v_teacher, NEW.lesson_date, NEW.pair_number;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lessons_conflict
    BEFORE INSERT OR UPDATE OF load_id, lesson_date, pair_number ON lessons
    FOR EACH ROW EXECUTE FUNCTION fn_check_lesson_conflict();

-- ---------- 3. Проверка принадлежности студента группе занятия -------
-- Бизнес-правило: оценку и отметку посещаемости можно поставить только
-- студенту группы, для которой проводится занятие, и только обучающемуся.
CREATE OR REPLACE FUNCTION fn_check_student_lesson() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_student_group INTEGER;
    v_status        INTEGER;
    v_lesson_group  INTEGER;
BEGIN
    SELECT group_id, status_id INTO v_student_group, v_status
    FROM students WHERE student_id = NEW.student_id;

    SELECT tl.group_id INTO v_lesson_group
    FROM lessons l JOIN teaching_load tl ON tl.load_id = l.load_id
    WHERE l.lesson_id = NEW.lesson_id;

    IF v_student_group IS DISTINCT FROM v_lesson_group THEN
        RAISE EXCEPTION 'Студент (id=%) не относится к группе, у которой проводится занятие (id=%)',
            NEW.student_id, NEW.lesson_id;
    END IF;

    IF v_status <> 1 THEN
        RAISE EXCEPTION 'Студент (id=%) не обучается (статус %), операция запрещена',
            NEW.student_id, v_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_grades_check
    BEFORE INSERT OR UPDATE OF student_id, lesson_id ON grades
    FOR EACH ROW EXECUTE FUNCTION fn_check_student_lesson();

CREATE TRIGGER trg_attendance_check
    BEFORE INSERT OR UPDATE OF student_id, lesson_id ON attendance
    FOR EACH ROW EXECUTE FUNCTION fn_check_student_lesson();

-- ---------- 4. Автоматическая обработка статуса студента -------------
-- При отчислении (статус 3) фиксируется дата отчисления; при любом другом
-- статусе дата очищается. Также обновляется метка updated_at.
CREATE OR REPLACE FUNCTION fn_student_status() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status_id = 3 THEN
        IF NEW.expelled_date IS NULL THEN
            NEW.expelled_date := CURRENT_DATE;
        END IF;
    ELSE
        NEW.expelled_date := NULL;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_students_status
    BEFORE INSERT OR UPDATE ON students
    FOR EACH ROW EXECUTE FUNCTION fn_student_status();
