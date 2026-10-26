-- PostgreSQL database dump

\restrict jCHXs2bq5wlsNrMFYvCe1wW2xosUXRFcIVW5yEHD0lHk1SpKPKQ9O4pVZKHoBC0

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: fn_attendance_rate(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_attendance_rate(p_student_id integer) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT round(100.0 * count(*) FILTER (WHERE status IN ('Присутствовал', 'Опоздал'))
                 / NULLIF(count(*), 0), 1)
    FROM attendance WHERE student_id = p_student_id;
$$;


--
-- Name: fn_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_audit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: fn_authenticate(character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_authenticate(p_username character varying, p_password text) RETURNS character varying
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: fn_check_lesson_conflict(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_check_lesson_conflict() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_check_student_lesson(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_check_student_lesson() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_decrypt_snils(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_decrypt_snils(p_student_id integer, p_key text) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT pgp_sym_decrypt(snils_enc, p_key) FROM student_private WHERE student_id = p_student_id;
$$;


--
-- Name: fn_group_report(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_group_report(p_group_id integer) RETURNS TABLE(student_id integer, full_name text, grades_count bigint, avg_grade numeric, absences bigint)
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: fn_student_average(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_student_average(p_student_id integer) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: fn_student_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_student_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: sp_add_grade(integer, integer, integer, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_add_grade(IN p_student_id integer, IN p_lesson_id integer, IN p_value integer, IN p_kind character varying DEFAULT 'Текущая'::character varying)
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: sp_change_student_status(integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_change_student_status(IN p_student_id integer, IN p_status_id integer)
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: sp_mark_attendance(integer, integer, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_mark_attendance(IN p_lesson_id integer, IN p_student_id integer, IN p_status character varying)
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: sp_register_user(character varying, text, character varying, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_register_user(IN p_username character varying, IN p_password text, IN p_role character varying, IN p_teacher_id integer DEFAULT NULL::integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: sp_transfer_student(integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_transfer_student(IN p_student_id integer, IN p_new_group_id integer)
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_users (
    user_id integer NOT NULL,
    username character varying(40) NOT NULL,
    password_hash text NOT NULL,
    role_name character varying(30) NOT NULL,
    teacher_id integer,
    is_active boolean DEFAULT true NOT NULL,
    failed_attempts smallint DEFAULT 0 NOT NULL,
    last_login timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_users_role_name_check CHECK (((role_name)::text = ANY ((ARRAY['role_admin'::character varying, 'role_methodist'::character varying, 'role_teacher'::character varying, 'role_analyst'::character varying])::text[])))
);


--
-- Name: TABLE app_users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.app_users IS 'Учётные записи приложения (пароли хранятся в виде bcrypt-хеша)';


--
-- Name: COLUMN app_users.password_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.app_users.password_hash IS 'bcrypt-хеш пароля (crypt + gen_salt)';


--
-- Name: app_users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.app_users ALTER COLUMN user_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.app_users_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: attendance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendance (
    attendance_id integer NOT NULL,
    lesson_id integer NOT NULL,
    student_id integer NOT NULL,
    status character varying(25) NOT NULL,
    CONSTRAINT attendance_status_check CHECK (((status)::text = ANY ((ARRAY['Присутствовал'::character varying, 'Отсутствовал'::character varying, 'Опоздал'::character varying, 'Уважительная причина'::character varying])::text[])))
);


--
-- Name: TABLE attendance; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.attendance IS 'Посещаемость занятий';


--
-- Name: attendance_attendance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.attendance ALTER COLUMN attendance_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.attendance_attendance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    log_id bigint NOT NULL,
    table_name character varying(63) NOT NULL,
    operation character(1) NOT NULL,
    record_id text,
    old_data jsonb,
    new_data jsonb,
    changed_by text NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_log_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: TABLE audit_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.audit_log IS 'Журнал аудита изменений данных';


--
-- Name: audit_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN log_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: classrooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.classrooms (
    classroom_id integer NOT NULL,
    number character varying(10) NOT NULL,
    capacity smallint NOT NULL,
    room_type character varying(30) NOT NULL,
    CONSTRAINT classrooms_capacity_check CHECK (((capacity >= 1) AND (capacity <= 300))),
    CONSTRAINT classrooms_room_type_check CHECK (((room_type)::text = ANY ((ARRAY['Лекционная'::character varying, 'Компьютерный класс'::character varying, 'Лаборатория'::character varying, 'Спортзал'::character varying, 'Кабинет'::character varying])::text[])))
);


--
-- Name: classrooms_classroom_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.classrooms ALTER COLUMN classroom_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.classrooms_classroom_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: control_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.control_types (
    control_type_id integer NOT NULL,
    name character varying(40) NOT NULL
);


--
-- Name: control_types_control_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.control_types ALTER COLUMN control_type_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.control_types_control_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: curriculum; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.curriculum (
    curriculum_id integer NOT NULL,
    specialty_id integer NOT NULL,
    discipline_id integer NOT NULL,
    semester smallint NOT NULL,
    hours smallint NOT NULL,
    control_type_id integer NOT NULL,
    CONSTRAINT curriculum_hours_check CHECK (((hours > 0) AND (hours <= 1500))),
    CONSTRAINT curriculum_semester_check CHECK (((semester >= 1) AND (semester <= 8)))
);


--
-- Name: TABLE curriculum; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.curriculum IS 'Учебный план: дисциплины специальности';


--
-- Name: curriculum_curriculum_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.curriculum ALTER COLUMN curriculum_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.curriculum_curriculum_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: disciplines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.disciplines (
    discipline_id integer NOT NULL,
    name character varying(120) NOT NULL,
    cycle character varying(10) NOT NULL,
    CONSTRAINT disciplines_cycle_check CHECK (((cycle)::text = ANY ((ARRAY['ОГСЭ'::character varying, 'ЕН'::character varying, 'ОП'::character varying, 'ПМ'::character varying])::text[])))
);


--
-- Name: TABLE disciplines; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.disciplines IS 'Учебные дисциплины и профессиональные модули';


--
-- Name: disciplines_discipline_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.disciplines ALTER COLUMN discipline_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.disciplines_discipline_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: grades; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grades (
    grade_id integer NOT NULL,
    student_id integer NOT NULL,
    lesson_id integer NOT NULL,
    grade_value smallint NOT NULL,
    grade_kind character varying(20) DEFAULT 'Текущая'::character varying NOT NULL,
    graded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT grades_grade_kind_check CHECK (((grade_kind)::text = ANY ((ARRAY['Текущая'::character varying, 'Контрольная'::character varying, 'Зачётная'::character varying])::text[]))),
    CONSTRAINT grades_grade_value_check CHECK (((grade_value >= 2) AND (grade_value <= 5)))
);


--
-- Name: TABLE grades; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.grades IS 'Оценки студентов за занятия';


--
-- Name: COLUMN grades.grade_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.grades.grade_value IS 'Оценка по пятибалльной шкале (2–5)';


--
-- Name: grades_grade_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.grades ALTER COLUMN grade_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.grades_grade_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lessons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lessons (
    lesson_id integer NOT NULL,
    load_id integer NOT NULL,
    classroom_id integer NOT NULL,
    lesson_date date NOT NULL,
    pair_number smallint NOT NULL,
    lesson_type character varying(20) NOT NULL,
    topic character varying(200),
    CONSTRAINT lessons_lesson_type_check CHECK (((lesson_type)::text = ANY ((ARRAY['Лекция'::character varying, 'Практика'::character varying, 'Лабораторная'::character varying, 'Контроль'::character varying])::text[]))),
    CONSTRAINT lessons_pair_number_check CHECK (((pair_number >= 1) AND (pair_number <= 7)))
);


--
-- Name: TABLE lessons; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.lessons IS 'Проведённые и запланированные занятия (расписание)';


--
-- Name: COLUMN lessons.pair_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lessons.pair_number IS 'Номер пары в расписании (1–7)';


--
-- Name: lessons_lesson_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lessons ALTER COLUMN lesson_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.lessons_lesson_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: positions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.positions (
    position_id integer NOT NULL,
    name character varying(80) NOT NULL
);


--
-- Name: positions_position_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.positions ALTER COLUMN position_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.positions_position_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: specialties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.specialties (
    specialty_id integer NOT NULL,
    code character varying(10) NOT NULL,
    name character varying(150) NOT NULL,
    qualification character varying(150) NOT NULL,
    duration_months smallint NOT NULL,
    CONSTRAINT specialties_duration_months_check CHECK (((duration_months >= 10) AND (duration_months <= 72)))
);


--
-- Name: TABLE specialties; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.specialties IS 'Специальности колледжа (ФГОС СПО)';


--
-- Name: specialties_specialty_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.specialties ALTER COLUMN specialty_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.specialties_specialty_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: student_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_groups (
    group_id integer NOT NULL,
    name character varying(20) NOT NULL,
    specialty_id integer NOT NULL,
    admission_year smallint NOT NULL,
    curator_id integer,
    CONSTRAINT student_groups_admission_year_check CHECK (((admission_year >= 2000) AND (admission_year <= 2100)))
);


--
-- Name: TABLE student_groups; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.student_groups IS 'Учебные группы';


--
-- Name: student_groups_group_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.student_groups ALTER COLUMN group_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.student_groups_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: student_private; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_private (
    student_id integer NOT NULL,
    snils_enc bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE student_private; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.student_private IS 'Персональные данные студентов в зашифрованном виде (pgcrypto)';


--
-- Name: student_statuses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_statuses (
    status_id integer NOT NULL,
    name character varying(40) NOT NULL
);


--
-- Name: student_statuses_status_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.student_statuses ALTER COLUMN status_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.student_statuses_status_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: students; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.students (
    student_id integer NOT NULL,
    last_name character varying(50) NOT NULL,
    first_name character varying(50) NOT NULL,
    middle_name character varying(50),
    birth_date date NOT NULL,
    gender character(1) NOT NULL,
    phone character varying(20),
    email character varying(100) NOT NULL,
    address character varying(200),
    group_id integer NOT NULL,
    status_id integer DEFAULT 1 NOT NULL,
    enrollment_date date NOT NULL,
    expelled_date date,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT students_birth_date_check CHECK (((birth_date >= '1980-01-01'::date) AND (birth_date <= '2015-12-31'::date))),
    CONSTRAINT students_check CHECK (((expelled_date IS NULL) OR (expelled_date >= enrollment_date))),
    CONSTRAINT students_email_check CHECK (((email)::text ~* '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]+$'::text)),
    CONSTRAINT students_gender_check CHECK ((gender = ANY (ARRAY['М'::bpchar, 'Ж'::bpchar])))
);


--
-- Name: TABLE students; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.students IS 'Студенты колледжа';


--
-- Name: COLUMN students.status_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.students.status_id IS 'Статус обучения: 1 — учится, 2 — академический отпуск, 3 — отчислен, 4 — выпускник';


--
-- Name: students_student_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.students ALTER COLUMN student_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.students_student_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: teachers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teachers (
    teacher_id integer NOT NULL,
    last_name character varying(50) NOT NULL,
    first_name character varying(50) NOT NULL,
    middle_name character varying(50),
    position_id integer NOT NULL,
    hire_date date NOT NULL,
    email character varying(100) NOT NULL,
    phone character varying(20),
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT teachers_email_check CHECK (((email)::text ~* '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]+$'::text)),
    CONSTRAINT teachers_hire_date_check CHECK ((hire_date >= '1970-01-01'::date))
);


--
-- Name: TABLE teachers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.teachers IS 'Преподаватели';


--
-- Name: teachers_teacher_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.teachers ALTER COLUMN teacher_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.teachers_teacher_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: teaching_load; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teaching_load (
    load_id integer NOT NULL,
    group_id integer NOT NULL,
    discipline_id integer NOT NULL,
    teacher_id integer NOT NULL
);


--
-- Name: TABLE teaching_load; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.teaching_load IS 'Педагогическая нагрузка: преподаватель ведёт дисциплину в группе';


--
-- Name: teaching_load_load_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.teaching_load ALTER COLUMN load_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.teaching_load_load_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: v_student_performance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_student_performance AS
 SELECT s.student_id,
    (((s.last_name)::text || ' '::text) || (s.first_name)::text) AS full_name,
    g.name AS group_name,
    ( SELECT round(avg(gr.grade_value), 2) AS round
           FROM public.grades gr
          WHERE (gr.student_id = s.student_id)) AS avg_grade,
    ( SELECT count(*) AS count
           FROM public.grades gr
          WHERE (gr.student_id = s.student_id)) AS grades_count,
    ( SELECT count(*) AS count
           FROM public.attendance a
          WHERE ((a.student_id = s.student_id) AND ((a.status)::text = 'Отсутствовал'::text))) AS absences
   FROM (public.students s
     JOIN public.student_groups g ON ((g.group_id = s.group_id)))
  WHERE (s.status_id = 1);


--
-- Name: v_at_risk_students; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_at_risk_students AS
 SELECT student_id,
    full_name,
    group_name,
    avg_grade,
    grades_count,
    absences
   FROM public.v_student_performance
  WHERE (((avg_grade < 3.5) AND (grades_count >= 2)) OR (absences >= 3));


--
-- Name: v_group_performance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_group_performance AS
 SELECT g.group_id,
    g.name AS group_name,
    sp.code AS specialty_code,
    count(DISTINCT s.student_id) AS students_count,
    round(avg(gr.grade_value), 2) AS avg_grade,
    count(gr.grade_id) AS grades_count
   FROM (((public.student_groups g
     JOIN public.specialties sp ON ((sp.specialty_id = g.specialty_id)))
     LEFT JOIN public.students s ON (((s.group_id = g.group_id) AND (s.status_id = 1))))
     LEFT JOIN public.grades gr ON ((gr.student_id = s.student_id)))
  GROUP BY g.group_id, g.name, sp.code;


--
-- Name: v_schedule; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_schedule AS
 SELECT l.lesson_id,
    l.lesson_date,
    l.pair_number,
    g.name AS group_name,
    d.name AS discipline,
    l.lesson_type,
    ((((t.last_name)::text || ' '::text) || "left"((t.first_name)::text, 1)) || '.'::text) AS teacher,
    c.number AS room
   FROM (((((public.lessons l
     JOIN public.teaching_load tl ON ((tl.load_id = l.load_id)))
     JOIN public.student_groups g ON ((g.group_id = tl.group_id)))
     JOIN public.disciplines d ON ((d.discipline_id = tl.discipline_id)))
     JOIN public.teachers t ON ((t.teacher_id = tl.teacher_id)))
     JOIN public.classrooms c ON ((c.classroom_id = l.classroom_id)));


--
-- Name: v_student_card; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_student_card AS
 SELECT s.student_id,
    ((((s.last_name)::text || ' '::text) || (s.first_name)::text) || COALESCE((' '::text || (s.middle_name)::text), ''::text)) AS full_name,
    g.name AS group_name,
    sp.code AS specialty_code,
    sp.name AS specialty_name,
    st.name AS status,
    s.enrollment_date
   FROM (((public.students s
     JOIN public.student_groups g ON ((g.group_id = s.group_id)))
     JOIN public.specialties sp ON ((sp.specialty_id = g.specialty_id)))
     JOIN public.student_statuses st ON ((st.status_id = s.status_id)));


--
-- Name: v_teacher_workload; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_teacher_workload AS
 SELECT t.teacher_id,
    (((t.last_name)::text || ' '::text) || (t.first_name)::text) AS teacher,
    p.name AS "position",
    count(DISTINCT tl.group_id) AS groups_count,
    count(DISTINCT tl.discipline_id) AS disciplines_count,
    count(l.lesson_id) AS lessons_count
   FROM (((public.teachers t
     JOIN public.positions p ON ((p.position_id = t.position_id)))
     LEFT JOIN public.teaching_load tl ON ((tl.teacher_id = t.teacher_id)))
     LEFT JOIN public.lessons l ON ((l.load_id = tl.load_id)))
  GROUP BY t.teacher_id, t.last_name, t.first_name, p.name;


--
-- Name: app_users app_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_pkey PRIMARY KEY (user_id);


--
-- Name: app_users app_users_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_username_key UNIQUE (username);


--
-- Name: attendance attendance_lesson_id_student_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_lesson_id_student_id_key UNIQUE (lesson_id, student_id);


--
-- Name: attendance attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_pkey PRIMARY KEY (attendance_id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (log_id);


--
-- Name: classrooms classrooms_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.classrooms
    ADD CONSTRAINT classrooms_number_key UNIQUE (number);


--
-- Name: classrooms classrooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.classrooms
    ADD CONSTRAINT classrooms_pkey PRIMARY KEY (classroom_id);


--
-- Name: control_types control_types_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.control_types
    ADD CONSTRAINT control_types_name_key UNIQUE (name);


--
-- Name: control_types control_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.control_types
    ADD CONSTRAINT control_types_pkey PRIMARY KEY (control_type_id);


--
-- Name: curriculum curriculum_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum
    ADD CONSTRAINT curriculum_pkey PRIMARY KEY (curriculum_id);


--
-- Name: curriculum curriculum_specialty_id_discipline_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum
    ADD CONSTRAINT curriculum_specialty_id_discipline_id_key UNIQUE (specialty_id, discipline_id);


--
-- Name: disciplines disciplines_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disciplines
    ADD CONSTRAINT disciplines_name_key UNIQUE (name);


--
-- Name: disciplines disciplines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disciplines
    ADD CONSTRAINT disciplines_pkey PRIMARY KEY (discipline_id);


--
-- Name: grades grades_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_pkey PRIMARY KEY (grade_id);


--
-- Name: grades grades_student_id_lesson_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_student_id_lesson_id_key UNIQUE (student_id, lesson_id);


--
-- Name: lessons lessons_classroom_id_lesson_date_pair_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_classroom_id_lesson_date_pair_number_key UNIQUE (classroom_id, lesson_date, pair_number);


--
-- Name: lessons lessons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_pkey PRIMARY KEY (lesson_id);


--
-- Name: positions positions_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_name_key UNIQUE (name);


--
-- Name: positions positions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_pkey PRIMARY KEY (position_id);


--
-- Name: specialties specialties_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.specialties
    ADD CONSTRAINT specialties_code_key UNIQUE (code);


--
-- Name: specialties specialties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.specialties
    ADD CONSTRAINT specialties_pkey PRIMARY KEY (specialty_id);


--
-- Name: student_groups student_groups_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_groups
    ADD CONSTRAINT student_groups_name_key UNIQUE (name);


--
-- Name: student_groups student_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_groups
    ADD CONSTRAINT student_groups_pkey PRIMARY KEY (group_id);


--
-- Name: student_private student_private_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_private
    ADD CONSTRAINT student_private_pkey PRIMARY KEY (student_id);


--
-- Name: student_statuses student_statuses_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_statuses
    ADD CONSTRAINT student_statuses_name_key UNIQUE (name);


--
-- Name: student_statuses student_statuses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_statuses
    ADD CONSTRAINT student_statuses_pkey PRIMARY KEY (status_id);


--
-- Name: students students_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_email_key UNIQUE (email);


--
-- Name: students students_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_pkey PRIMARY KEY (student_id);


--
-- Name: teachers teachers_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teachers
    ADD CONSTRAINT teachers_email_key UNIQUE (email);


--
-- Name: teachers teachers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teachers
    ADD CONSTRAINT teachers_pkey PRIMARY KEY (teacher_id);


--
-- Name: teaching_load teaching_load_group_id_discipline_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teaching_load
    ADD CONSTRAINT teaching_load_group_id_discipline_id_key UNIQUE (group_id, discipline_id);


--
-- Name: teaching_load teaching_load_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teaching_load
    ADD CONSTRAINT teaching_load_pkey PRIMARY KEY (load_id);


--
-- Name: idx_attendance_student; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attendance_student ON public.attendance USING btree (student_id);


--
-- Name: idx_audit_table_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_table_time ON public.audit_log USING btree (table_name, changed_at DESC);


--
-- Name: idx_grades_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_grades_lesson ON public.grades USING btree (lesson_id);


--
-- Name: idx_lessons_date_pair; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lessons_date_pair ON public.lessons USING btree (lesson_date, pair_number);


--
-- Name: idx_lessons_load; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lessons_load ON public.lessons USING btree (load_id);


--
-- Name: idx_load_discipline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_load_discipline ON public.teaching_load USING btree (discipline_id);


--
-- Name: idx_load_teacher; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_load_teacher ON public.teaching_load USING btree (teacher_id);


--
-- Name: idx_students_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_students_active ON public.students USING btree (group_id) WHERE (expelled_date IS NULL);


--
-- Name: idx_students_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_students_group ON public.students USING btree (group_id);


--
-- Name: idx_students_lastname; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_students_lastname ON public.students USING btree (lower((last_name)::text) text_pattern_ops);


--
-- Name: attendance trg_attendance_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_attendance_check BEFORE INSERT OR UPDATE OF student_id, lesson_id ON public.attendance FOR EACH ROW EXECUTE FUNCTION public.fn_check_student_lesson();


--
-- Name: grades trg_audit_grades; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_grades AFTER INSERT OR DELETE OR UPDATE ON public.grades FOR EACH ROW EXECUTE FUNCTION public.fn_audit('grade_id');


--
-- Name: lessons trg_audit_lessons; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_lessons AFTER INSERT OR DELETE OR UPDATE ON public.lessons FOR EACH ROW EXECUTE FUNCTION public.fn_audit('lesson_id');


--
-- Name: students trg_audit_students; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_students AFTER INSERT OR DELETE OR UPDATE ON public.students FOR EACH ROW EXECUTE FUNCTION public.fn_audit('student_id');


--
-- Name: grades trg_grades_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_grades_check BEFORE INSERT OR UPDATE OF student_id, lesson_id ON public.grades FOR EACH ROW EXECUTE FUNCTION public.fn_check_student_lesson();


--
-- Name: lessons trg_lessons_conflict; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_lessons_conflict BEFORE INSERT OR UPDATE OF load_id, lesson_date, pair_number ON public.lessons FOR EACH ROW EXECUTE FUNCTION public.fn_check_lesson_conflict();


--
-- Name: students trg_students_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_students_status BEFORE INSERT OR UPDATE ON public.students FOR EACH ROW EXECUTE FUNCTION public.fn_student_status();


--
-- Name: app_users app_users_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.teachers(teacher_id) ON DELETE SET NULL;


--
-- Name: attendance attendance_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(lesson_id) ON DELETE CASCADE;


--
-- Name: attendance attendance_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id);


--
-- Name: curriculum curriculum_control_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum
    ADD CONSTRAINT curriculum_control_type_id_fkey FOREIGN KEY (control_type_id) REFERENCES public.control_types(control_type_id);


--
-- Name: curriculum curriculum_discipline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum
    ADD CONSTRAINT curriculum_discipline_id_fkey FOREIGN KEY (discipline_id) REFERENCES public.disciplines(discipline_id);


--
-- Name: curriculum curriculum_specialty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum
    ADD CONSTRAINT curriculum_specialty_id_fkey FOREIGN KEY (specialty_id) REFERENCES public.specialties(specialty_id) ON DELETE CASCADE;


--
-- Name: grades grades_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(lesson_id) ON DELETE CASCADE;


--
-- Name: grades grades_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id);


--
-- Name: lessons lessons_classroom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_classroom_id_fkey FOREIGN KEY (classroom_id) REFERENCES public.classrooms(classroom_id);


--
-- Name: lessons lessons_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.teaching_load(load_id) ON DELETE CASCADE;


--
-- Name: student_groups student_groups_curator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_groups
    ADD CONSTRAINT student_groups_curator_id_fkey FOREIGN KEY (curator_id) REFERENCES public.teachers(teacher_id) ON DELETE SET NULL;


--
-- Name: student_groups student_groups_specialty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_groups
    ADD CONSTRAINT student_groups_specialty_id_fkey FOREIGN KEY (specialty_id) REFERENCES public.specialties(specialty_id);


--
-- Name: student_private student_private_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_private
    ADD CONSTRAINT student_private_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id) ON DELETE CASCADE;


--
-- Name: students students_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.student_groups(group_id);


--
-- Name: students students_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.student_statuses(status_id);


--
-- Name: teachers teachers_position_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teachers
    ADD CONSTRAINT teachers_position_id_fkey FOREIGN KEY (position_id) REFERENCES public.positions(position_id);


--
-- Name: teaching_load teaching_load_discipline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teaching_load
    ADD CONSTRAINT teaching_load_discipline_id_fkey FOREIGN KEY (discipline_id) REFERENCES public.disciplines(discipline_id);


--
-- Name: teaching_load teaching_load_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teaching_load
    ADD CONSTRAINT teaching_load_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.student_groups(group_id) ON DELETE CASCADE;


--
-- Name: teaching_load teaching_load_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teaching_load
    ADD CONSTRAINT teaching_load_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.teachers(teacher_id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO role_admin;
GRANT USAGE ON SCHEMA public TO role_methodist;
GRANT USAGE ON SCHEMA public TO role_teacher;
GRANT USAGE ON SCHEMA public TO role_analyst;
GRANT USAGE ON SCHEMA public TO college_app;


--
-- Name: FUNCTION armor(bytea); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.armor(bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION public.armor(bytea) TO role_admin;


--
-- Name: FUNCTION armor(bytea, text[], text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.armor(bytea, text[], text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.armor(bytea, text[], text[]) TO role_admin;


--
-- Name: FUNCTION crypt(text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.crypt(text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.crypt(text, text) TO role_admin;


--
-- Name: FUNCTION dearmor(text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dearmor(text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dearmor(text) TO role_admin;


--
-- Name: FUNCTION decrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.decrypt(bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.decrypt(bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION decrypt_iv(bytea, bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.decrypt_iv(bytea, bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.decrypt_iv(bytea, bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION digest(bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.digest(bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.digest(bytea, text) TO role_admin;


--
-- Name: FUNCTION digest(text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.digest(text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.digest(text, text) TO role_admin;


--
-- Name: FUNCTION encrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.encrypt(bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.encrypt(bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION encrypt_iv(bytea, bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.encrypt_iv(bytea, bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.encrypt_iv(bytea, bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION fn_attendance_rate(p_student_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_attendance_rate(p_student_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_attendance_rate(p_student_id integer) TO role_admin;
GRANT ALL ON FUNCTION public.fn_attendance_rate(p_student_id integer) TO role_methodist;
GRANT ALL ON FUNCTION public.fn_attendance_rate(p_student_id integer) TO role_teacher;


--
-- Name: FUNCTION fn_audit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_audit() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_audit() TO role_admin;


--
-- Name: FUNCTION fn_authenticate(p_username character varying, p_password text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_authenticate(p_username character varying, p_password text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_authenticate(p_username character varying, p_password text) TO role_admin;
GRANT ALL ON FUNCTION public.fn_authenticate(p_username character varying, p_password text) TO college_app;


--
-- Name: FUNCTION fn_check_lesson_conflict(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_check_lesson_conflict() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_check_lesson_conflict() TO role_admin;


--
-- Name: FUNCTION fn_check_student_lesson(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_check_student_lesson() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_check_student_lesson() TO role_admin;


--
-- Name: FUNCTION fn_decrypt_snils(p_student_id integer, p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_decrypt_snils(p_student_id integer, p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_decrypt_snils(p_student_id integer, p_key text) TO role_admin;


--
-- Name: FUNCTION fn_group_report(p_group_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_group_report(p_group_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_group_report(p_group_id integer) TO role_admin;
GRANT ALL ON FUNCTION public.fn_group_report(p_group_id integer) TO role_methodist;
GRANT ALL ON FUNCTION public.fn_group_report(p_group_id integer) TO role_teacher;


--
-- Name: FUNCTION fn_student_average(p_student_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_student_average(p_student_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_student_average(p_student_id integer) TO role_admin;
GRANT ALL ON FUNCTION public.fn_student_average(p_student_id integer) TO role_methodist;
GRANT ALL ON FUNCTION public.fn_student_average(p_student_id integer) TO role_teacher;


--
-- Name: FUNCTION fn_student_status(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_student_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_student_status() TO role_admin;


--
-- Name: FUNCTION gen_random_bytes(integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gen_random_bytes(integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gen_random_bytes(integer) TO role_admin;


--
-- Name: FUNCTION gen_random_uuid(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gen_random_uuid() FROM PUBLIC;
GRANT ALL ON FUNCTION public.gen_random_uuid() TO role_admin;


--
-- Name: FUNCTION gen_salt(text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gen_salt(text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gen_salt(text) TO role_admin;


--
-- Name: FUNCTION gen_salt(text, integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gen_salt(text, integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gen_salt(text, integer) TO role_admin;


--
-- Name: FUNCTION hmac(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.hmac(bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.hmac(bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION hmac(text, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.hmac(text, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.hmac(text, text, text) TO role_admin;


--
-- Name: FUNCTION pgp_armor_headers(text, OUT key text, OUT value text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_armor_headers(text, OUT key text, OUT value text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_armor_headers(text, OUT key text, OUT value text) TO role_admin;


--
-- Name: FUNCTION pgp_key_id(bytea); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_key_id(bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_key_id(bytea) TO role_admin;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea) TO role_admin;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text, text) TO role_admin;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea) TO role_admin;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text, text) TO role_admin;


--
-- Name: FUNCTION pgp_pub_encrypt(text, bytea); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea) TO role_admin;


--
-- Name: FUNCTION pgp_pub_encrypt(text, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_pub_encrypt_bytea(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea) TO role_admin;


--
-- Name: FUNCTION pgp_pub_encrypt_bytea(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_decrypt(bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_decrypt(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_decrypt_bytea(bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_decrypt_bytea(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_encrypt(text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_encrypt(text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_encrypt(text, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_encrypt(text, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_encrypt(text, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_encrypt(text, text, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_encrypt_bytea(bytea, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text) TO role_admin;


--
-- Name: FUNCTION pgp_sym_encrypt_bytea(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text, text) TO role_admin;


--
-- Name: PROCEDURE sp_add_grade(IN p_student_id integer, IN p_lesson_id integer, IN p_value integer, IN p_kind character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_add_grade(IN p_student_id integer, IN p_lesson_id integer, IN p_value integer, IN p_kind character varying) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_add_grade(IN p_student_id integer, IN p_lesson_id integer, IN p_value integer, IN p_kind character varying) TO role_admin;
GRANT ALL ON PROCEDURE public.sp_add_grade(IN p_student_id integer, IN p_lesson_id integer, IN p_value integer, IN p_kind character varying) TO role_teacher;


--
-- Name: PROCEDURE sp_change_student_status(IN p_student_id integer, IN p_status_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_change_student_status(IN p_student_id integer, IN p_status_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_change_student_status(IN p_student_id integer, IN p_status_id integer) TO role_admin;
GRANT ALL ON PROCEDURE public.sp_change_student_status(IN p_student_id integer, IN p_status_id integer) TO role_methodist;


--
-- Name: PROCEDURE sp_mark_attendance(IN p_lesson_id integer, IN p_student_id integer, IN p_status character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_mark_attendance(IN p_lesson_id integer, IN p_student_id integer, IN p_status character varying) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_mark_attendance(IN p_lesson_id integer, IN p_student_id integer, IN p_status character varying) TO role_admin;
GRANT ALL ON PROCEDURE public.sp_mark_attendance(IN p_lesson_id integer, IN p_student_id integer, IN p_status character varying) TO role_teacher;


--
-- Name: PROCEDURE sp_register_user(IN p_username character varying, IN p_password text, IN p_role character varying, IN p_teacher_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_register_user(IN p_username character varying, IN p_password text, IN p_role character varying, IN p_teacher_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_register_user(IN p_username character varying, IN p_password text, IN p_role character varying, IN p_teacher_id integer) TO role_admin;


--
-- Name: PROCEDURE sp_transfer_student(IN p_student_id integer, IN p_new_group_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_transfer_student(IN p_student_id integer, IN p_new_group_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_transfer_student(IN p_student_id integer, IN p_new_group_id integer) TO role_admin;
GRANT ALL ON PROCEDURE public.sp_transfer_student(IN p_student_id integer, IN p_new_group_id integer) TO role_methodist;


--
-- Name: TABLE app_users; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_users TO role_admin;


--
-- Name: TABLE attendance; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.attendance TO role_admin;
GRANT SELECT ON TABLE public.attendance TO role_methodist;
GRANT SELECT,INSERT,UPDATE ON TABLE public.attendance TO role_teacher;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.audit_log TO role_admin;


--
-- Name: TABLE classrooms; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.classrooms TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.classrooms TO role_methodist;
GRANT SELECT ON TABLE public.classrooms TO role_teacher;


--
-- Name: TABLE control_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.control_types TO role_admin;
GRANT SELECT ON TABLE public.control_types TO role_methodist;
GRANT SELECT ON TABLE public.control_types TO role_teacher;


--
-- Name: TABLE curriculum; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.curriculum TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.curriculum TO role_methodist;
GRANT SELECT ON TABLE public.curriculum TO role_teacher;


--
-- Name: TABLE disciplines; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.disciplines TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.disciplines TO role_methodist;
GRANT SELECT ON TABLE public.disciplines TO role_teacher;


--
-- Name: TABLE grades; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.grades TO role_admin;
GRANT SELECT ON TABLE public.grades TO role_methodist;
GRANT SELECT,INSERT,UPDATE ON TABLE public.grades TO role_teacher;


--
-- Name: TABLE lessons; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lessons TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lessons TO role_methodist;
GRANT SELECT ON TABLE public.lessons TO role_teacher;


--
-- Name: TABLE positions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.positions TO role_admin;
GRANT SELECT ON TABLE public.positions TO role_methodist;


--
-- Name: TABLE specialties; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.specialties TO role_admin;
GRANT SELECT ON TABLE public.specialties TO role_methodist;
GRANT SELECT ON TABLE public.specialties TO role_teacher;


--
-- Name: TABLE student_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_groups TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.student_groups TO role_methodist;
GRANT SELECT ON TABLE public.student_groups TO role_teacher;


--
-- Name: TABLE student_private; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_private TO role_admin;


--
-- Name: TABLE student_statuses; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_statuses TO role_admin;
GRANT SELECT ON TABLE public.student_statuses TO role_methodist;
GRANT SELECT ON TABLE public.student_statuses TO role_teacher;


--
-- Name: TABLE students; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.students TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.students TO role_methodist;


--
-- Name: COLUMN students.student_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(student_id) ON TABLE public.students TO role_teacher;


--
-- Name: COLUMN students.last_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(last_name) ON TABLE public.students TO role_teacher;


--
-- Name: COLUMN students.first_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(first_name) ON TABLE public.students TO role_teacher;


--
-- Name: COLUMN students.middle_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(middle_name) ON TABLE public.students TO role_teacher;


--
-- Name: COLUMN students.group_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(group_id) ON TABLE public.students TO role_teacher;


--
-- Name: COLUMN students.status_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(status_id) ON TABLE public.students TO role_teacher;


--
-- Name: TABLE teachers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.teachers TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.teachers TO role_methodist;


--
-- Name: COLUMN teachers.teacher_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(teacher_id) ON TABLE public.teachers TO role_teacher;


--
-- Name: COLUMN teachers.last_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(last_name) ON TABLE public.teachers TO role_teacher;


--
-- Name: COLUMN teachers.first_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(first_name) ON TABLE public.teachers TO role_teacher;


--
-- Name: COLUMN teachers.middle_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(middle_name) ON TABLE public.teachers TO role_teacher;


--
-- Name: COLUMN teachers.position_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(position_id) ON TABLE public.teachers TO role_teacher;


--
-- Name: TABLE teaching_load; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.teaching_load TO role_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.teaching_load TO role_methodist;
GRANT SELECT ON TABLE public.teaching_load TO role_teacher;


--
-- Name: TABLE v_student_performance; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_student_performance TO role_admin;
GRANT SELECT ON TABLE public.v_student_performance TO role_methodist;
GRANT SELECT ON TABLE public.v_student_performance TO role_teacher;
GRANT SELECT ON TABLE public.v_student_performance TO role_analyst;


--
-- Name: TABLE v_at_risk_students; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_at_risk_students TO role_admin;
GRANT SELECT ON TABLE public.v_at_risk_students TO role_methodist;
GRANT SELECT ON TABLE public.v_at_risk_students TO role_analyst;


--
-- Name: TABLE v_group_performance; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_group_performance TO role_admin;
GRANT SELECT ON TABLE public.v_group_performance TO role_methodist;
GRANT SELECT ON TABLE public.v_group_performance TO role_teacher;
GRANT SELECT ON TABLE public.v_group_performance TO role_analyst;


--
-- Name: TABLE v_schedule; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_schedule TO role_admin;
GRANT SELECT ON TABLE public.v_schedule TO role_methodist;
GRANT SELECT ON TABLE public.v_schedule TO role_teacher;
GRANT SELECT ON TABLE public.v_schedule TO role_analyst;


--
-- Name: TABLE v_student_card; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_student_card TO role_admin;
GRANT SELECT ON TABLE public.v_student_card TO role_methodist;


--
-- Name: TABLE v_teacher_workload; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_teacher_workload TO role_admin;
GRANT SELECT ON TABLE public.v_teacher_workload TO role_methodist;
GRANT SELECT ON TABLE public.v_teacher_workload TO role_analyst;


--
-- PostgreSQL database dump complete
--

\unrestrict jCHXs2bq5wlsNrMFYvCe1wW2xosUXRFcIVW5yEHD0lHk1SpKPKQ9O4pVZKHoBC0

