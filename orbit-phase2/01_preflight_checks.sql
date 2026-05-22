-- Phase 2 — Pre-flight (read-only). Review results before loading data.

-- Duplicate SIS keys (must be 0 rows before UNIQUE enforcement)
SELECT sis_student_id, count(*) AS cnt
FROM public.student_sis_enrollment
GROUP BY sis_student_id
HAVING count(*) > 1;

-- Students without SIS enrollment parent row
SELECT s.id, s.sis_student_id
FROM public.students s
LEFT JOIN public.student_sis_enrollment e ON e.sis_student_id = s.sis_student_id
WHERE e.sis_student_id IS NULL;

-- SIS enrollment without matching students row
SELECT e.sis_student_id
FROM public.student_sis_enrollment e
LEFT JOIN public.students s ON s.sis_student_id = e.sis_student_id
WHERE s.sis_student_id IS NULL;

-- Orphan students (invalid school)
SELECT s.sis_student_id, s.school_id
FROM public.students s
LEFT JOIN public.schools sc ON sc.id = s.school_id
WHERE sc.id IS NULL;
