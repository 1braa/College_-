-- =====================================================================
-- 05_queries.sql — базовые запросы (SELECT, JOIN, GROUP BY, HAVING, подзапросы)
-- Формат заголовка: -- Qnn | описание
-- =====================================================================

-- Q01 | Список студентов группы П1-24
SELECT s.student_id, s.last_name, s.first_name, s.birth_date
FROM students s
JOIN student_groups g ON g.group_id = s.group_id
WHERE g.name = 'П1-24'
ORDER BY s.last_name, s.first_name
LIMIT 5;

-- Q02 | Поиск студентов по началу фамилии (LIKE)
SELECT student_id, last_name, first_name, group_id
FROM students
WHERE last_name LIKE 'Иван%'
ORDER BY last_name, first_name
LIMIT 5;

-- Q03 | Численность студентов по группам (GROUP BY)
SELECT g.name AS group_name, count(s.student_id) AS students_count
FROM student_groups g
LEFT JOIN students s ON s.group_id = g.group_id
GROUP BY g.name
ORDER BY g.name
LIMIT 8;

-- Q04 | Группы, в которых более 18 студентов (HAVING)
SELECT g.name AS group_name, count(*) AS students_count
FROM student_groups g
JOIN students s ON s.group_id = g.group_id
GROUP BY g.name
HAVING count(*) > 18
ORDER BY students_count DESC, g.name;

-- Q05 | Студенты со специальностью и статусом (JOIN трёх таблиц)
SELECT s.last_name, s.first_name, g.name AS group_name, sp.code, st.name AS status
FROM students s
JOIN student_groups g    ON g.group_id = s.group_id
JOIN specialties sp      ON sp.specialty_id = g.specialty_id
JOIN student_statuses st ON st.status_id = s.status_id
ORDER BY sp.code, g.name, s.last_name
LIMIT 5;

-- Q06 | Средний балл по группам
SELECT g.name AS group_name, round(avg(gr.grade_value), 2) AS avg_grade, count(*) AS grades_count
FROM grades gr
JOIN students s       ON s.student_id = gr.student_id
JOIN student_groups g ON g.group_id = s.group_id
GROUP BY g.name
ORDER BY avg_grade DESC
LIMIT 5;

-- Q07 | Средний балл по дисциплинам
SELECT d.name AS discipline, round(avg(gr.grade_value), 2) AS avg_grade, count(*) AS grades_count
FROM grades gr
JOIN lessons l         ON l.lesson_id = gr.lesson_id
JOIN teaching_load tl  ON tl.load_id = l.load_id
JOIN disciplines d     ON d.discipline_id = tl.discipline_id
GROUP BY d.name
ORDER BY avg_grade DESC
LIMIT 5;

-- Q08 | Десять лучших студентов по среднему баллу (не менее 3 оценок)
SELECT s.last_name, s.first_name, g.name AS group_name,
       round(avg(gr.grade_value), 2) AS avg_grade, count(*) AS grades_count
FROM students s
JOIN student_groups g ON g.group_id = s.group_id
JOIN grades gr        ON gr.student_id = s.student_id
GROUP BY s.student_id, s.last_name, s.first_name, g.name
HAVING count(*) >= 3
ORDER BY avg_grade DESC, grades_count DESC, s.last_name
LIMIT 10;

-- Q09 | Распределение оценок в процентах (скалярный подзапрос)
SELECT grade_value, count(*) AS cnt,
       round(100.0 * count(*) / (SELECT count(*) FROM grades), 1) AS percent
FROM grades
GROUP BY grade_value
ORDER BY grade_value;

-- Q10 | Преподаватели и число проведённых ими занятий (LEFT JOIN)
SELECT t.last_name, t.first_name, count(l.lesson_id) AS lessons_count
FROM teachers t
LEFT JOIN teaching_load tl ON tl.teacher_id = t.teacher_id
LEFT JOIN lessons l        ON l.load_id = tl.load_id
GROUP BY t.teacher_id, t.last_name, t.first_name
ORDER BY lessons_count DESC, t.last_name
LIMIT 5;

-- Q11 | Преподаватели, у которых нет занятий 14.09.2026 (NOT EXISTS)
SELECT t.teacher_id, t.last_name, t.first_name
FROM teachers t
WHERE NOT EXISTS (SELECT 1
                  FROM lessons l
                  JOIN teaching_load tl ON tl.load_id = l.load_id
                  WHERE tl.teacher_id = t.teacher_id
                    AND l.lesson_date = DATE '2026-09-14')
ORDER BY t.last_name, t.first_name
LIMIT 5;

-- Q12 | Расписание группы П1-24 на неделю 14–18 сентября 2026
SELECT l.lesson_date, l.pair_number, d.name AS discipline, l.lesson_type,
       t.last_name AS teacher, c.number AS room
FROM lessons l
JOIN teaching_load tl ON tl.load_id = l.load_id
JOIN student_groups g ON g.group_id = tl.group_id
JOIN disciplines d    ON d.discipline_id = tl.discipline_id
JOIN teachers t       ON t.teacher_id = tl.teacher_id
JOIN classrooms c     ON c.classroom_id = l.classroom_id
WHERE g.name = 'П1-24'
  AND l.lesson_date BETWEEN DATE '2026-09-14' AND DATE '2026-09-18'
ORDER BY l.lesson_date, l.pair_number;

-- Q13 | Загрузка аудиторий: число занятий в каждой
SELECT c.number, c.room_type, count(l.lesson_id) AS lessons_count
FROM classrooms c
LEFT JOIN lessons l ON l.classroom_id = c.classroom_id
GROUP BY c.classroom_id, c.number, c.room_type
ORDER BY lessons_count DESC, c.number
LIMIT 5;

-- Q14 | Студенты, получившие хотя бы одну «двойку» (EXISTS)
SELECT s.student_id, s.last_name, s.first_name
FROM students s
WHERE EXISTS (SELECT 1 FROM grades gr
              WHERE gr.student_id = s.student_id AND gr.grade_value = 2)
ORDER BY s.last_name, s.first_name
LIMIT 5;

-- Q15 | Студенты со средним баллом выше среднего по колледжу (подзапрос в HAVING)
SELECT s.last_name, s.first_name, round(avg(gr.grade_value), 2) AS avg_grade, count(*) AS cnt
FROM students s
JOIN grades gr ON gr.student_id = s.student_id
GROUP BY s.student_id, s.last_name, s.first_name
HAVING count(*) >= 3 AND avg(gr.grade_value) > (SELECT avg(grade_value) FROM grades)
ORDER BY avg_grade DESC, cnt DESC, s.last_name
LIMIT 5;

-- Q16 | Студенты с наибольшим числом пропусков
SELECT s.last_name, s.first_name, g.name AS group_name, count(*) AS absences
FROM attendance a
JOIN students s       ON s.student_id = a.student_id
JOIN student_groups g ON g.group_id = s.group_id
WHERE a.status = 'Отсутствовал'
GROUP BY s.student_id, s.last_name, s.first_name, g.name
ORDER BY absences DESC, s.last_name
LIMIT 5;

-- Q17 | Количество студентов по статусам обучения
SELECT st.name AS status, count(s.student_id) AS students_count
FROM student_statuses st
LEFT JOIN students s ON s.status_id = st.status_id
GROUP BY st.status_id, st.name
ORDER BY st.status_id;

-- Q18 | Специальности: число групп и студентов
SELECT sp.code, sp.name, count(DISTINCT g.group_id) AS groups_count, count(s.student_id) AS students_count
FROM specialties sp
LEFT JOIN student_groups g ON g.specialty_id = sp.specialty_id
LEFT JOIN students s       ON s.group_id = g.group_id
GROUP BY sp.specialty_id, sp.code, sp.name
ORDER BY sp.code;

-- Q19 | Учебный план специальности 09.02.07
SELECT cu.semester, d.name AS discipline, cu.hours, ct.name AS control
FROM curriculum cu
JOIN specialties sp    ON sp.specialty_id = cu.specialty_id
JOIN disciplines d     ON d.discipline_id = cu.discipline_id
JOIN control_types ct  ON ct.control_type_id = cu.control_type_id
WHERE sp.code = '09.02.07'
ORDER BY cu.semester, d.name
LIMIT 6;

-- Q20 | Обучающиеся студенты, у которых ещё нет ни одной оценки (LEFT JOIN … IS NULL)
SELECT s.student_id, s.last_name, s.first_name, g.name AS group_name
FROM students s
JOIN student_groups g ON g.group_id = s.group_id
LEFT JOIN grades gr   ON gr.student_id = s.student_id
WHERE gr.grade_id IS NULL AND s.status_id = 1
ORDER BY g.name, s.last_name
LIMIT 5;

-- Q21 | Количество занятий по дням недели
SELECT (ARRAY['Пн','Вт','Ср','Чт','Пт','Сб','Вс'])[EXTRACT(ISODOW FROM lesson_date)::int] AS weekday,
       count(*) AS lessons_count
FROM lessons
GROUP BY EXTRACT(ISODOW FROM lesson_date)
ORDER BY EXTRACT(ISODOW FROM lesson_date);

-- Q22 | Средний возраст студентов по специальностям на 16.10.2026
SELECT sp.code, round(avg(date_part('year', age(DATE '2026-10-16', s.birth_date)))::numeric, 1) AS avg_age
FROM students s
JOIN student_groups g ON g.group_id = s.group_id
JOIN specialties sp   ON sp.specialty_id = g.specialty_id
GROUP BY sp.code
ORDER BY sp.code;

-- Q23 | Посещаемость по группам в процентах
SELECT g.name AS group_name,
       count(*) AS marks,
       round(100.0 * count(*) FILTER (WHERE a.status IN ('Присутствовал', 'Опоздал')) / count(*), 1) AS attendance_pct
FROM attendance a
JOIN students s       ON s.student_id = a.student_id
JOIN student_groups g ON g.group_id = s.group_id
GROUP BY g.name
ORDER BY attendance_pct DESC, g.name
LIMIT 5;

-- Q24 | Студенты специальности 09.02.07, получавшие «пятёрки» (IN с подзапросом)
SELECT s.last_name, s.first_name, g.name AS group_name
FROM students s
JOIN student_groups g ON g.group_id = s.group_id
WHERE g.specialty_id = (SELECT specialty_id FROM specialties WHERE code = '09.02.07')
  AND s.student_id IN (SELECT student_id FROM grades WHERE grade_value = 5)
ORDER BY g.name, s.last_name
LIMIT 5;
