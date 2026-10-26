-- =====================================================================
-- 06_views_advanced.sql — представления, оконные функции, CTE
-- Формат заголовка запросов: -- Ann | описание
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------- Представления --------------------------------------------

-- V1. Карточка студента (без контактных данных)
CREATE OR REPLACE VIEW v_student_card AS
SELECT s.student_id,
       s.last_name || ' ' || s.first_name || COALESCE(' ' || s.middle_name, '') AS full_name,
       g.name  AS group_name,
       sp.code AS specialty_code,
       sp.name AS specialty_name,
       st.name AS status,
       s.enrollment_date
FROM students s
JOIN student_groups g    ON g.group_id = s.group_id
JOIN specialties sp      ON sp.specialty_id = g.specialty_id
JOIN student_statuses st ON st.status_id = s.status_id;

-- V2. Расписание занятий
CREATE OR REPLACE VIEW v_schedule AS
SELECT l.lesson_id, l.lesson_date, l.pair_number,
       g.name AS group_name, d.name AS discipline, l.lesson_type,
       t.last_name || ' ' || left(t.first_name, 1) || '.' AS teacher,
       c.number AS room
FROM lessons l
JOIN teaching_load tl ON tl.load_id = l.load_id
JOIN student_groups g ON g.group_id = tl.group_id
JOIN disciplines d    ON d.discipline_id = tl.discipline_id
JOIN teachers t       ON t.teacher_id = tl.teacher_id
JOIN classrooms c     ON c.classroom_id = l.classroom_id;

-- V3. Успеваемость студентов: средний балл, число оценок, пропуски
CREATE OR REPLACE VIEW v_student_performance AS
SELECT s.student_id,
       s.last_name || ' ' || s.first_name AS full_name,
       g.name AS group_name,
       (SELECT round(avg(gr.grade_value), 2) FROM grades gr WHERE gr.student_id = s.student_id) AS avg_grade,
       (SELECT count(*) FROM grades gr WHERE gr.student_id = s.student_id) AS grades_count,
       (SELECT count(*) FROM attendance a
         WHERE a.student_id = s.student_id AND a.status = 'Отсутствовал') AS absences
FROM students s
JOIN student_groups g ON g.group_id = s.group_id
WHERE s.status_id = 1;

-- V4. Успеваемость по группам
CREATE OR REPLACE VIEW v_group_performance AS
SELECT g.group_id, g.name AS group_name, sp.code AS specialty_code,
       count(DISTINCT s.student_id) AS students_count,
       round(avg(gr.grade_value), 2) AS avg_grade,
       count(gr.grade_id) AS grades_count
FROM student_groups g
JOIN specialties sp ON sp.specialty_id = g.specialty_id
LEFT JOIN students s ON s.group_id = g.group_id AND s.status_id = 1
LEFT JOIN grades gr  ON gr.student_id = s.student_id
GROUP BY g.group_id, g.name, sp.code;

-- V5. Нагрузка преподавателей
CREATE OR REPLACE VIEW v_teacher_workload AS
SELECT t.teacher_id,
       t.last_name || ' ' || t.first_name AS teacher,
       p.name AS position,
       count(DISTINCT tl.group_id)        AS groups_count,
       count(DISTINCT tl.discipline_id)   AS disciplines_count,
       count(l.lesson_id)                 AS lessons_count
FROM teachers t
JOIN positions p           ON p.position_id = t.position_id
LEFT JOIN teaching_load tl ON tl.teacher_id = t.teacher_id
LEFT JOIN lessons l        ON l.load_id = tl.load_id
GROUP BY t.teacher_id, t.last_name, t.first_name, p.name;

-- V6. Студенты группы риска: низкий балл или много пропусков
CREATE OR REPLACE VIEW v_at_risk_students AS
SELECT student_id, full_name, group_name, avg_grade, grades_count, absences
FROM v_student_performance
WHERE (avg_grade < 3.5 AND grades_count >= 2) OR absences >= 3;

-- ---------- Продвинутые запросы --------------------------------------

-- A01 | Рейтинг студентов группы П1-24 по среднему баллу (RANK)
WITH st AS (
    SELECT s.student_id, s.last_name, s.first_name, g.name AS grp,
           round(avg(gr.grade_value), 2) AS avg_grade, count(*) AS cnt
    FROM students s
    JOIN student_groups g ON g.group_id = s.group_id
    JOIN grades gr        ON gr.student_id = s.student_id
    GROUP BY s.student_id, s.last_name, s.first_name, g.name
)
SELECT last_name, first_name, avg_grade, cnt,
       RANK() OVER (PARTITION BY grp ORDER BY avg_grade DESC) AS rnk
FROM st
WHERE grp = 'П1-24'
ORDER BY rnk, last_name
LIMIT 6;

-- A02 | Лучшие три студента каждой группы (ROW_NUMBER в подзапросе)
SELECT group_name, full_name, avg_grade, pos
FROM (SELECT group_name, full_name, avg_grade,
             ROW_NUMBER() OVER (PARTITION BY group_name ORDER BY avg_grade DESC, grades_count DESC) AS pos
      FROM v_student_performance
      WHERE avg_grade IS NOT NULL) t
WHERE pos <= 3
ORDER BY group_name, pos
LIMIT 6;

-- A03 | Накопительное число занятий по дням (SUM OVER)
SELECT lesson_date, count(*) AS lessons_per_day,
       sum(count(*)) OVER (ORDER BY lesson_date) AS running_total
FROM lessons
GROUP BY lesson_date
ORDER BY lesson_date
LIMIT 6;

-- A04 | Изменение числа занятий по сравнению с предыдущим днём (LAG)
SELECT lesson_date, lessons_per_day,
       lessons_per_day - LAG(lessons_per_day) OVER (ORDER BY lesson_date) AS diff_prev_day
FROM (SELECT lesson_date, count(*) AS lessons_per_day FROM lessons GROUP BY lesson_date) d
ORDER BY lesson_date
LIMIT 6;

-- A05 | Разбиение студентов на квартили по среднему баллу (NTILE)
SELECT quartile, count(*) AS students_count,
       min(avg_grade) AS min_avg, max(avg_grade) AS max_avg
FROM (SELECT avg_grade, NTILE(4) OVER (ORDER BY avg_grade DESC) AS quartile
      FROM v_student_performance
      WHERE avg_grade IS NOT NULL) q
GROUP BY quartile
ORDER BY quartile;

-- A06 | Группа риска через CTE: причины (низкий балл, пропуски) собираются вместе
WITH low_grade AS (
    SELECT student_id, 'низкий балл' AS reason
    FROM v_student_performance WHERE avg_grade < 3.5 AND grades_count >= 2
), many_absences AS (
    SELECT student_id, 'пропуски' AS reason
    FROM v_student_performance WHERE absences >= 2
), risk AS (
    SELECT * FROM low_grade UNION ALL SELECT * FROM many_absences
)
SELECT p.full_name, p.group_name, p.avg_grade, p.absences,
       string_agg(r.reason, ' + ' ORDER BY r.reason) AS reasons
FROM risk r
JOIN v_student_performance p ON p.student_id = r.student_id
GROUP BY p.student_id, p.full_name, p.group_name, p.avg_grade, p.absences
ORDER BY count(*) DESC, p.avg_grade, p.full_name
LIMIT 6;

-- A07 | Календарь сентября 2026 с числом занятий — рекурсивный CTE
WITH RECURSIVE cal(d) AS (
    SELECT DATE '2026-09-01'
    UNION ALL
    SELECT d + 1 FROM cal WHERE d < DATE '2026-09-30'
)
SELECT cal.d AS day, count(l.lesson_id) AS lessons_count
FROM cal
LEFT JOIN lessons l ON l.lesson_date = cal.d
WHERE EXTRACT(ISODOW FROM cal.d) <= 5
GROUP BY cal.d
ORDER BY cal.d
LIMIT 6;

-- A08 | Рейтинг дисциплин по среднему баллу (DENSE_RANK)
SELECT discipline, avg_grade, DENSE_RANK() OVER (ORDER BY avg_grade DESC) AS rnk
FROM (SELECT d.name AS discipline, round(avg(gr.grade_value), 2) AS avg_grade
      FROM grades gr
      JOIN lessons l        ON l.lesson_id = gr.lesson_id
      JOIN teaching_load tl ON tl.load_id = l.load_id
      JOIN disciplines d    ON d.discipline_id = tl.discipline_id
      GROUP BY d.name) x
ORDER BY rnk, discipline
LIMIT 6;

-- A09 | Использование представлений: нагрузка преподавателей (V5)
SELECT teacher, position, groups_count, lessons_count
FROM v_teacher_workload
ORDER BY lessons_count DESC, teacher
LIMIT 5;
