-- =====================================================================
-- 03_data.sql — загрузка тестовых данных (все данные вымышленные)
-- Итого около 4300 записей. Генерация детерминирована (setseed).
-- =====================================================================
\set ON_ERROR_STOP on
SELECT setseed(0.2026);

-- На время массовой загрузки отключаем только триггеры аудита
ALTER TABLE students DISABLE TRIGGER trg_audit_students;
ALTER TABLE grades   DISABLE TRIGGER trg_audit_grades;
ALTER TABLE lessons  DISABLE TRIGGER trg_audit_lessons;

CREATE FUNCTION pg_temp.fake_phone() RETURNS text LANGUAGE sql VOLATILE AS $$
    SELECT '+7 9' || lpad(floor(random() * 100)::int::text, 2, '0')
           || ' ' || lpad(floor(random() * 1000)::int::text, 3, '0')
           || '-' || lpad(floor(random() * 100)::int::text, 2, '0')
           || '-' || lpad(floor(random() * 100)::int::text, 2, '0')
$$;

-- ---------- Справочники ----------------------------------------------

INSERT INTO specialties (code, name, qualification, duration_months) VALUES
 ('09.02.07', 'Информационные системы и программирование', 'Программист', 46),
 ('09.02.06', 'Сетевое и системное администрирование', 'Сетевой и системный администратор', 46),
 ('38.02.01', 'Экономика и бухгалтерский учёт (по отраслям)', 'Бухгалтер', 34),
 ('40.02.04', 'Юриспруденция', 'Юрист', 34),
 ('43.02.15', 'Поварское и кондитерское дело', 'Специалист по поварскому и кондитерскому делу', 34);

INSERT INTO positions (name) VALUES
 ('Преподаватель'), ('Старший преподаватель'), ('Преподаватель высшей категории'),
 ('Заведующий отделением'), ('Методист'), ('Мастер производственного обучения');

INSERT INTO student_statuses (name) VALUES
 ('Учится'), ('Академический отпуск'), ('Отчислен'), ('Выпускник');

INSERT INTO control_types (name) VALUES
 ('Зачёт'), ('Дифференцированный зачёт'), ('Экзамен'), ('Курсовая работа');

INSERT INTO disciplines (name, cycle) VALUES
 ('Русский язык и культура речи', 'ОГСЭ'),
 ('Иностранный язык', 'ОГСЭ'),
 ('История', 'ОГСЭ'),
 ('Физическая культура', 'ОГСЭ'),
 ('Математика', 'ЕН'),
 ('Информатика', 'ЕН'),
 ('Основы программирования', 'ОП'),
 ('Базы данных', 'ОП'),
 ('Операционные системы', 'ОП'),
 ('Компьютерные сети', 'ОП'),
 ('Архитектура компьютерных систем', 'ОП'),
 ('Web-разработка', 'ПМ'),
 ('Основы алгоритмизации', 'ОП'),
 ('Информационная безопасность', 'ОП'),
 ('Администрирование сетевых служб', 'ПМ'),
 ('Бухгалтерский учёт', 'ПМ'),
 ('Экономика организации', 'ОП'),
 ('Налоги и налогообложение', 'ПМ'),
 ('Финансы и кредит', 'ОП'),
 ('Статистика', 'ЕН'),
 ('Теория государства и права', 'ОП'),
 ('Гражданское право', 'ПМ'),
 ('Уголовное право', 'ПМ'),
 ('Конституционное право', 'ОП'),
 ('Технология приготовления блюд', 'ПМ'),
 ('Санитария и гигиена', 'ОП'),
 ('Товароведение', 'ОП'),
 ('Организация производства', 'ПМ'),
 ('Менеджмент', 'ОП'),
 ('Безопасность жизнедеятельности', 'ОП');

-- Аудитории: 5 этажей × 5 кабинетов = 25
INSERT INTO classrooms (number, capacity, room_type)
SELECT (100 * f + k)::text,
       20 + ((f * 7 + k * 5) % 5) * 10,
       CASE WHEN f = 5 AND k = 5 THEN 'Спортзал'
            WHEN k = 1 THEN 'Лекционная'
            WHEN k IN (2, 3) THEN 'Компьютерный класс'
            WHEN k = 4 THEN 'Лаборатория'
            ELSE 'Кабинет' END
FROM generate_series(1, 5) f, generate_series(1, 5) k;

-- ---------- Преподаватели --------------------------------------------

INSERT INTO teachers (last_name, first_name, middle_name, position_id, hire_date, email, phone)
SELECT CASE WHEN r.male THEN nm.sn[r.a] ELSE nm.sn[r.a] || 'а' END,
       CASE WHEN r.male THEN nm.mf[r.b] ELSE nm.ff[r.b] END,
       CASE WHEN r.male THEN nm.mp[r.c] ELSE nm.fp[r.c] END,
       1 + floor(random() * 6)::int,
       DATE '2005-09-01' + floor(random() * 7000)::int,
       't' || lpad(r.n::text, 3, '0') || '@college.example',
       pg_temp.fake_phone()
FROM (SELECT n,
             random() < 0.5 AS male,
             1 + floor(random() * 25)::int AS a,
             1 + floor(random() * 15)::int AS b,
             1 + floor(random() * 10)::int AS c
      FROM generate_series(1, 30) n) r
CROSS JOIN (SELECT
    ARRAY['Иванов','Петров','Сидоров','Смирнов','Кузнецов','Попов','Васильев','Соколов','Михайлов',
          'Новиков','Фёдоров','Морозов','Волков','Алексеев','Лебедев','Семёнов','Егоров','Павлов',
          'Козлов','Степанов','Николаев','Орлов','Андреев','Макаров','Никитин'] AS sn,
    ARRAY['Александр','Дмитрий','Максим','Иван','Артём','Михаил','Никита','Андрей','Егор','Кирилл',
          'Илья','Сергей','Владимир','Павел','Роман'] AS mf,
    ARRAY['Анна','Мария','Екатерина','Дарья','Анастасия','Виктория','Полина','Елена','Ольга','Софья',
          'Алина','Ксения','Юлия','Татьяна','Наталья'] AS ff,
    ARRAY['Александрович','Сергеевич','Андреевич','Дмитриевич','Иванович','Михайлович','Николаевич',
          'Павлович','Владимирович','Алексеевич'] AS mp,
    ARRAY['Александровна','Сергеевна','Андреевна','Дмитриевна','Ивановна','Михайловна','Николаевна',
          'Павловна','Владимировна','Алексеевна'] AS fp) nm;

-- ---------- Группы ----------------------------------------------------

INSERT INTO student_groups (name, specialty_id, admission_year, curator_id) VALUES
 ('П1-23', 1, 2023, 1),  ('П1-24', 1, 2024, 2),  ('П2-24', 1, 2024, 3),
 ('П1-25', 1, 2025, 4),  ('П1-26', 1, 2026, 5),
 ('С1-24', 2, 2024, 6),  ('С1-25', 2, 2025, 7),  ('С1-26', 2, 2026, 8),
 ('Б1-24', 3, 2024, 9),  ('Б1-25', 3, 2025, 10), ('Б1-26', 3, 2026, 11),
 ('Ю1-24', 4, 2024, 12), ('Ю1-25', 4, 2025, 13), ('Ю1-26', 4, 2026, 14),
 ('К1-25', 5, 2025, 15), ('К1-26', 5, 2026, 16);

-- ---------- Студенты (300) -------------------------------------------

INSERT INTO students (last_name, first_name, middle_name, birth_date, gender, phone, email, address,
                      group_id, status_id, enrollment_date, expelled_date)
SELECT CASE WHEN r.male THEN nm.sn[r.a] ELSE nm.sn[r.a] || 'а' END,
       CASE WHEN r.male THEN nm.mf[r.b] ELSE nm.ff[r.b] END,
       CASE WHEN r.male THEN nm.mp[r.c] ELSE nm.fp[r.c] END,
       make_date(g.admission_year - 17 - floor(random() * 3)::int,
                 1 + floor(random() * 12)::int, 1 + floor(random() * 28)::int),
       CASE WHEN r.male THEN 'М' ELSE 'Ж' END,
       pg_temp.fake_phone(),
       's' || lpad(r.n::text, 4, '0') || '@college.example',
       'г. Москва, ул. ' || nm.st[1 + floor(random() * 10)::int] || ', д. ' || (1 + floor(random() * 150)::int),
       g.group_id,
       CASE WHEN r.st < 0.90 THEN 1 WHEN r.st < 0.95 THEN 2 ELSE 3 END,
       make_date(g.admission_year, 9, 1),
       CASE WHEN r.st >= 0.95
            THEN make_date(g.admission_year, 9, 1) + floor(random() * 40)::int END
FROM (SELECT n,
             random() < 0.5 AS male,
             1 + floor(random() * 25)::int AS a,
             1 + floor(random() * 15)::int AS b,
             1 + floor(random() * 10)::int AS c,
             random() AS st
      FROM generate_series(1, 300) n) r
JOIN student_groups g ON g.group_id = 1 + (r.n % 16)
CROSS JOIN (SELECT
    ARRAY['Иванов','Петров','Сидоров','Смирнов','Кузнецов','Попов','Васильев','Соколов','Михайлов',
          'Новиков','Фёдоров','Морозов','Волков','Алексеев','Лебедев','Семёнов','Егоров','Павлов',
          'Козлов','Степанов','Николаев','Орлов','Андреев','Макаров','Никитин'] AS sn,
    ARRAY['Александр','Дмитрий','Максим','Иван','Артём','Михаил','Никита','Андрей','Егор','Кирилл',
          'Илья','Сергей','Владимир','Павел','Роман'] AS mf,
    ARRAY['Анна','Мария','Екатерина','Дарья','Анастасия','Виктория','Полина','Елена','Ольга','Софья',
          'Алина','Ксения','Юлия','Татьяна','Наталья'] AS ff,
    ARRAY['Александрович','Сергеевич','Андреевич','Дмитриевич','Иванович','Михайлович','Николаевич',
          'Павлович','Владимирович','Алексеевич'] AS mp,
    ARRAY['Александровна','Сергеевна','Андреевна','Дмитриевна','Ивановна','Михайловна','Николаевна',
          'Павловна','Владимировна','Алексеевна'] AS fp,
    ARRAY['Ленина','Мира','Садовая','Школьная','Центральная','Заречная','Парковая','Лесная',
          'Гагарина','Советская'] AS st) nm;

-- ---------- Учебный план: 51 запись ----------------------------------

INSERT INTO curriculum (specialty_id, discipline_id, semester, hours, control_type_id)
SELECT s.sp, d, 1 + (d % 6), 36 + (d * 7 % 12) * 12, 1 + (d % 4)
FROM (VALUES
        (1, ARRAY[1,2,4,5,6,7,8,9,10,12,13,14]),
        (2, ARRAY[2,4,5,6,9,10,11,15,14,30]),
        (3, ARRAY[1,2,3,4,5,16,17,18,19,20,29]),
        (4, ARRAY[1,2,3,4,21,22,23,24,30]),
        (5, ARRAY[1,4,5,25,26,27,28,29,30])
     ) AS s(sp, ds),
     unnest(s.ds) AS d;

-- ---------- Педагогическая нагрузка ----------------------------------
-- каждая группа изучает все дисциплины учебного плана своей специальности

INSERT INTO teaching_load (group_id, discipline_id, teacher_id)
SELECT g.group_id, c.discipline_id, 1 + floor(random() * 30)::int
FROM student_groups g
JOIN curriculum c ON c.specialty_id = g.specialty_id;

-- ---------- Занятия (1000) -------------------------------------------
-- Вставка идёт построчно: при конфликте расписания срабатывает триггер
-- trg_lessons_conflict либо UNIQUE (аудитория, дата, пара); такая попытка
-- пропускается, и подбирается другое сочетание.

DO $$
DECLARE
    v_inserted INTEGER := 0;
    v_attempts INTEGER := 0;
    v_skipped  INTEGER := 0;
    v_nload    INTEGER;
    v_load     INTEGER;
    v_room     INTEGER;
    v_date     DATE;
    v_types    TEXT[] := ARRAY['Лекция', 'Практика', 'Практика', 'Лабораторная', 'Контроль'];
BEGIN
    SELECT count(*) INTO v_nload FROM teaching_load;
    WHILE v_inserted < 1000 AND v_attempts < 50000 LOOP
        v_attempts := v_attempts + 1;
        v_date := DATE '2026-09-01' + floor(random() * 45)::int;      -- 01.09–15.10.2026
        CONTINUE WHEN EXTRACT(ISODOW FROM v_date) > 5;                -- только будни
        SELECT load_id INTO v_load FROM teaching_load
        ORDER BY load_id OFFSET floor(random() * v_nload)::int LIMIT 1;
        SELECT classroom_id INTO v_room FROM classrooms
        ORDER BY classroom_id OFFSET floor(random() * 25)::int LIMIT 1;
        BEGIN
            INSERT INTO lessons (load_id, classroom_id, lesson_date, pair_number, lesson_type, topic)
            VALUES (v_load, v_room, v_date, 1 + floor(random() * 6)::int,
                    v_types[1 + floor(random() * 5)::int],
                    'Тема занятия №' || (v_inserted + 1));
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN unique_violation OR raise_exception THEN
            v_skipped := v_skipped + 1;
        END;
    END LOOP;
    RAISE NOTICE 'Занятий добавлено: %, отклонено конфликтов: %, попыток: %',
        v_inserted, v_skipped, v_attempts;
END;
$$;

-- ---------- Оценки (1500) --------------------------------------------

INSERT INTO grades (student_id, lesson_id, grade_value, grade_kind, graded_at)
SELECT x.student_id, x.lesson_id,
       CASE WHEN x.r < 0.07 THEN 2 WHEN x.r < 0.30 THEN 3 WHEN x.r < 0.65 THEN 4 ELSE 5 END,
       CASE x.lesson_type WHEN 'Контроль' THEN 'Контрольная' ELSE 'Текущая' END,
       x.lesson_date + TIME '10:00' + (x.pair_number * INTERVAL '1 hour 40 minutes')
FROM (SELECT s.student_id, l.lesson_id, l.lesson_date, l.pair_number, l.lesson_type,
             random() AS r
      FROM lessons l
      JOIN teaching_load tl ON tl.load_id = l.load_id
      JOIN students s ON s.group_id = tl.group_id AND s.status_id = 1
      ORDER BY md5(s.student_id::text || '-' || l.lesson_id::text)   -- псевдослучайный порядок, не связанный с r
      LIMIT 1500) x;

-- ---------- Посещаемость (1200) --------------------------------------

INSERT INTO attendance (lesson_id, student_id, status)
SELECT x.lesson_id, x.student_id,
       CASE WHEN x.r < 0.85 THEN 'Присутствовал'
            WHEN x.r < 0.93 THEN 'Отсутствовал'
            WHEN x.r < 0.97 THEN 'Опоздал'
            ELSE 'Уважительная причина' END
FROM (SELECT s.student_id, l.lesson_id, random() AS r
      FROM lessons l
      JOIN teaching_load tl ON tl.load_id = l.load_id
      JOIN students s ON s.group_id = tl.group_id AND s.status_id = 1
      ORDER BY md5(s.student_id::text || '-' || l.lesson_id::text)   -- псевдослучайный порядок, не связанный с r
      LIMIT 1200) x;

-- Включаем аудит обратно
ALTER TABLE students ENABLE TRIGGER trg_audit_students;
ALTER TABLE grades   ENABLE TRIGGER trg_audit_grades;
ALTER TABLE lessons  ENABLE TRIGGER trg_audit_lessons;

ANALYZE;
