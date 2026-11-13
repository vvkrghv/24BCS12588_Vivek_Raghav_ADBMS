-- =====================================================================
--  HOSTEL MANAGEMENT SYSTEM  —  04_reports.sql
--  Showcase queries for the project report / viva (run them in psql or pgAdmin).
--  Not used by the web application.
-- =====================================================================

-- name: Block-wise occupancy
-- concept: Aggregates (COUNT, SUM), GROUP BY, LEFT JOIN, FILTER clause
SELECT b.block_name,
       b.gender,
       COUNT(r.room_id)                                   AS rooms,
       SUM(rt.capacity)                                   AS beds,
       SUM(r.current_occupancy)                           AS occupied,
       SUM(rt.capacity) - SUM(r.current_occupancy)        AS free_beds,
       ROUND(100.0 * SUM(r.current_occupancy) / SUM(rt.capacity), 1) AS occupancy_pct,
       COUNT(*) FILTER (WHERE r.status = 'MAINTENANCE')   AS under_maintenance
  FROM hostel_block b
  LEFT JOIN room r       ON r.block_id = b.block_id
  LEFT JOIN room_type rt ON rt.type_code = r.type_code
 GROUP BY b.block_id, b.block_name, b.gender
 ORDER BY b.block_name;

-- name: Fee defaulters (balance > 0)
-- concept: View built on CTEs + JOIN to the current allocation, ORDER BY
SELECT d.roll_no, d.name, cr.room_label, d.total_billed, d.total_paid, d.balance, d.guardian_phone
  FROM v_student_dues d
  LEFT JOIN v_current_residents cr ON cr.student_id = d.student_id
 WHERE d.balance > 0
 ORDER BY d.balance DESC;

-- name: Department-wise residents
-- concept: Multi-table JOIN, GROUP BY with HAVING
SELECT d.dept_name,
       COUNT(*)                                    AS residents,
       COUNT(*) FILTER (WHERE s.gender = 'M')      AS male,
       COUNT(*) FILTER (WHERE s.gender = 'F')      AS female,
       ROUND(AVG(s.year_of_study), 2)              AS avg_year
  FROM allocation a
  JOIN student s    ON s.student_id = a.student_id
  JOIN department d ON d.dept_id = s.dept_id
 WHERE a.status = 'ACTIVE'
 GROUP BY d.dept_name
HAVING COUNT(*) >= 1
 ORDER BY residents DESC;

-- name: Top 3 dues per block
-- concept: Window function RANK() OVER (PARTITION BY ...) inside a CTE
WITH ranked AS (
    SELECT cr.block_name, cr.roll_no, cr.name, d.balance,
           RANK() OVER (PARTITION BY cr.block_name ORDER BY d.balance DESC) AS rnk
      FROM v_current_residents cr
      JOIN v_student_dues d ON d.student_id = cr.student_id
     WHERE d.balance > 0
)
SELECT block_name, rnk AS rank, roll_no, name, balance
  FROM ranked
 WHERE rnk <= 3
 ORDER BY block_name, rnk;

-- name: Average complaint resolution time by category
-- concept: Date/time arithmetic, EXTRACT(EPOCH), aggregates on intervals
SELECT category,
       COUNT(*)                                                   AS total,
       COUNT(*) FILTER (WHERE status = 'RESOLVED')                AS resolved,
       COUNT(*) FILTER (WHERE status <> 'RESOLVED')               AS pending,
       ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600)
             FILTER (WHERE status = 'RESOLVED')::numeric, 1)      AS avg_hours_to_resolve
  FROM complaint
 GROUP BY category
 ORDER BY total DESC;

-- name: Students with no room (correlated NOT EXISTS)
-- concept: Correlated subquery with NOT EXISTS
SELECT s.roll_no, s.name, s.gender, d.dept_code, s.year_of_study
  FROM student s
  JOIN department d ON d.dept_id = s.dept_id
 WHERE s.is_active
   AND NOT EXISTS (SELECT 1 FROM allocation a
                    WHERE a.student_id = s.student_id AND a.status = 'ACTIVE');

-- name: Rooms fuller than their block average
-- concept: Correlated subquery in WHERE comparing against a group average
SELECT rs.room_label, rs.type_code, rs.current_occupancy, rs.capacity
  FROM v_room_status rs
 WHERE rs.current_occupancy::numeric / rs.capacity >
       (SELECT AVG(r2.current_occupancy::numeric / rt2.capacity)
          FROM room r2 JOIN room_type rt2 ON rt2.type_code = r2.type_code
         WHERE r2.block_id = rs.block_id)
 ORDER BY rs.room_label;

-- name: Monthly fee collection with running total
-- concept: date_trunc, GROUP BY, window SUM() OVER (ORDER BY) for a cumulative total
SELECT to_char(date_trunc('month', paid_on), 'Mon YYYY')     AS month,
       COUNT(*)                                              AS payments,
       SUM(amount)                                           AS collected,
       SUM(SUM(amount)) OVER (ORDER BY date_trunc('month', paid_on)) AS running_total
  FROM payment
 GROUP BY date_trunc('month', paid_on)
 ORDER BY date_trunc('month', paid_on);

-- name: Payment mode share
-- concept: Aggregate over a window (percentage of grand total)
SELECT mode,
       COUNT(*)                                                    AS payments,
       SUM(amount)                                                 AS amount,
       ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER (), 1)    AS pct_of_total
  FROM payment
 GROUP BY mode
 ORDER BY amount DESC;

-- name: Roommate pairs
-- concept: SELF JOIN on allocation (a1.student_id < a2.student_id avoids duplicates)
SELECT rs.room_label, s1.name AS student_1, s2.name AS student_2
  FROM allocation a1
  JOIN allocation a2 ON a2.room_id = a1.room_id
                    AND a1.student_id < a2.student_id
                    AND a2.status = 'ACTIVE'
  JOIN student s1 ON s1.student_id = a1.student_id
  JOIN student s2 ON s2.student_id = a2.student_id
  JOIN v_room_status rs ON rs.room_id = a1.room_id
 WHERE a1.status = 'ACTIVE'
 ORDER BY rs.room_label;

-- name: Staff workload
-- concept: LEFT JOIN + conditional aggregation; staff with zero complaints still appear
SELECT st.name, st.role,
       COUNT(c.complaint_id)                                   AS assigned,
       COUNT(c.complaint_id) FILTER (WHERE c.status = 'RESOLVED') AS resolved,
       COUNT(c.complaint_id) FILTER (WHERE c.status <> 'RESOLVED') AS pending
  FROM staff st
  LEFT JOIN complaint c ON c.assigned_staff_id = st.staff_id
 WHERE st.role IN ('ELECTRICIAN','PLUMBER','CARPENTER','CLEANER','MESS')
 GROUP BY st.staff_id, st.name, st.role
 ORDER BY assigned DESC, st.name;

-- name: Students currently on approved leave
-- concept: Range operators — daterange @> CURRENT_DATE
SELECT s.roll_no, s.name, l.from_date, l.to_date, l.destination
  FROM leave_request l
  JOIN student s ON s.student_id = l.student_id
 WHERE l.status = 'APPROVED'
   AND daterange(l.from_date, l.to_date, '[]') @> CURRENT_DATE;

-- name: Set operations — every person in the hostel today
-- concept: UNION ALL across different tables
SELECT 'Student' AS type, name, room_label AS detail FROM v_current_residents
UNION ALL
SELECT 'Staff', name, role FROM staff WHERE is_active
UNION ALL
SELECT 'Visitor (inside)', visitor_name, relation FROM visitor WHERE out_time IS NULL
ORDER BY type, name;

-- name: Index usage demo (EXPLAIN)
-- concept: Expression index idx_student_name_lower. With only ~40 rows the planner may still pick a Seq Scan; seq scans are disabled here so the index plan is visible.
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE SELECT * FROM student WHERE lower(name) = 'aarav sharma';
