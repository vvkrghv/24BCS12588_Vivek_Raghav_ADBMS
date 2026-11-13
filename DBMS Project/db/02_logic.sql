-- =====================================================================
--  HOSTEL MANAGEMENT SYSTEM  —  02_logic.sql
--  Triggers, functions, stored procedures and views
-- =====================================================================
SET search_path = hostel, public;

-- =====================================================================
-- A. TRIGGERS
-- =====================================================================

-- A1. Validate a new allocation: room exists, not under maintenance,
--     not full, student active, and student gender matches block gender.
CREATE OR REPLACE FUNCTION trg_allocation_validate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity     SMALLINT;
    v_occupancy    SMALLINT;
    v_room_status  TEXT;
    v_block_gender CHAR(1);
    v_stu_gender   CHAR(1);
    v_stu_active   BOOLEAN;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    -- lock the room row so two concurrent allocations cannot both take the last bed
    SELECT rt.capacity, r.current_occupancy, r.status, b.gender
      INTO v_capacity, v_occupancy, v_room_status, v_block_gender
      FROM room r
      JOIN room_type    rt ON rt.type_code = r.type_code
      JOIN hostel_block b  ON b.block_id   = r.block_id
     WHERE r.room_id = NEW.room_id
       FOR UPDATE OF r;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', NEW.room_id;
    END IF;
    IF v_room_status = 'MAINTENANCE' THEN
        RAISE EXCEPTION 'This room is under maintenance and cannot be allocated';
    END IF;
    IF v_occupancy >= v_capacity THEN
        RAISE EXCEPTION 'Room is already full (capacity %)', v_capacity;
    END IF;

    SELECT gender, is_active INTO v_stu_gender, v_stu_active
      FROM student WHERE student_id = NEW.student_id;

    IF NOT v_stu_active THEN
        RAISE EXCEPTION 'Student is inactive and cannot be allocated a room';
    END IF;
    IF v_stu_gender <> v_block_gender THEN
        RAISE EXCEPTION 'Gender mismatch: this block is reserved for % students',
            CASE v_block_gender WHEN 'M' THEN 'male' ELSE 'female' END;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER allocation_validate
    BEFORE INSERT ON allocation
    FOR EACH ROW EXECUTE FUNCTION trg_allocation_validate();


-- A2. Guard updates on allocation: only ACTIVE -> VACATED is allowed.
CREATE OR REPLACE FUNCTION trg_allocation_guard_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'VACATED' AND NEW.status = 'ACTIVE' THEN
        RAISE EXCEPTION 'A vacated room record cannot be re-activated; allocate a room again instead';
    END IF;
    IF NEW.room_id <> OLD.room_id OR NEW.student_id <> OLD.student_id THEN
        RAISE EXCEPTION 'Use the Move option to shift a student to another room';
    END IF;
    IF NEW.status = 'VACATED' AND NEW.vacated_on IS NULL THEN
        NEW.vacated_on := GREATEST(CURRENT_DATE, NEW.allocated_on);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER allocation_guard_update
    BEFORE UPDATE ON allocation
    FOR EACH ROW EXECUTE FUNCTION trg_allocation_guard_update();


-- A3. Keep room.current_occupancy in sync with allocations.
CREATE OR REPLACE FUNCTION trg_allocation_occupancy() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status = 'ACTIVE' THEN
        UPDATE room SET current_occupancy = current_occupancy + 1 WHERE room_id = NEW.room_id;
    ELSIF TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE' AND NEW.status = 'VACATED' THEN
        UPDATE room SET current_occupancy = current_occupancy - 1 WHERE room_id = OLD.room_id;
    ELSIF TG_OP = 'DELETE' AND OLD.status = 'ACTIVE' THEN
        UPDATE room SET current_occupancy = current_occupancy - 1 WHERE room_id = OLD.room_id;
    END IF;
    RETURN NULL;   -- AFTER trigger: return value ignored
END $$;

CREATE TRIGGER allocation_occupancy
    AFTER INSERT OR UPDATE OR DELETE ON allocation
    FOR EACH ROW EXECUTE FUNCTION trg_allocation_occupancy();


-- A4. Every new student automatically gets a login (username = password = roll_no).
CREATE OR REPLACE FUNCTION trg_student_create_user() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO app_user (username, password_hash, role, student_id)
    VALUES (NEW.roll_no, crypt(NEW.roll_no, gen_salt('bf', 8)), 'STUDENT', NEW.student_id);
    RETURN NULL;
END $$;

CREATE TRIGGER student_create_user
    AFTER INSERT ON student
    FOR EACH ROW EXECUTE FUNCTION trg_student_create_user();


-- A5. Deactivating a student automatically vacates their room;
--     changing the roll number renames their login.
CREATE OR REPLACE FUNCTION trg_student_after_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.is_active AND NOT NEW.is_active THEN
        UPDATE allocation SET status = 'VACATED', remarks = 'Auto-vacated: student deactivated'
         WHERE student_id = NEW.student_id AND status = 'ACTIVE';
    END IF;
    IF NEW.roll_no <> OLD.roll_no THEN
        UPDATE app_user SET username = NEW.roll_no WHERE student_id = NEW.student_id;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER student_after_update
    AFTER UPDATE ON student
    FOR EACH ROW EXECUTE FUNCTION trg_student_after_update();


-- A6. Complaint housekeeping: auto-fill room, auto status on assignment, resolved timestamp.
CREATE OR REPLACE FUNCTION trg_complaint_before() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.room_id IS NULL THEN
        SELECT room_id INTO NEW.room_id
          FROM allocation WHERE student_id = NEW.student_id AND status = 'ACTIVE';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.assigned_staff_id IS NOT NULL AND OLD.assigned_staff_id IS NULL
           AND NEW.status = 'OPEN' THEN
            NEW.status := 'IN_PROGRESS';
        END IF;
    END IF;

    IF NEW.status = 'RESOLVED' AND NEW.resolved_at IS NULL THEN
        NEW.resolved_at := GREATEST(now(), NEW.created_at);
    ELSIF NEW.status <> 'RESOLVED' THEN
        NEW.resolved_at := NULL;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER complaint_before
    BEFORE INSERT OR UPDATE ON complaint
    FOR EACH ROW EXECUTE FUNCTION trg_complaint_before();


-- A7. Payment validation: cannot pay more than the outstanding balance.
CREATE OR REPLACE FUNCTION trg_payment_validate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_due  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT amount + fine INTO v_due FROM invoice WHERE invoice_id = NEW.invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % does not exist', NEW.invoice_id;
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payment WHERE invoice_id = NEW.invoice_id;

    IF v_paid >= v_due THEN
        RAISE EXCEPTION 'Invoice % is already fully paid', NEW.invoice_id;
    END IF;
    IF NEW.amount > v_due - v_paid THEN
        RAISE EXCEPTION 'Payment of Rs % exceeds the outstanding balance of Rs %', NEW.amount, v_due - v_paid;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER payment_validate
    BEFORE INSERT ON payment
    FOR EACH ROW EXECUTE FUNCTION trg_payment_validate();


-- A8. After a payment changes, recompute the invoice status.
CREATE OR REPLACE FUNCTION refresh_invoice_status(p_invoice_id INT) RETURNS VOID
LANGUAGE sql AS $$
    UPDATE invoice i
       SET status = CASE
                      WHEN s.paid >= i.amount + i.fine THEN 'PAID'
                      WHEN s.paid > 0                  THEN 'PARTIAL'
                      ELSE 'UNPAID'
                    END
      FROM (SELECT COALESCE(SUM(amount), 0) AS paid FROM payment WHERE invoice_id = p_invoice_id) s
     WHERE i.invoice_id = p_invoice_id;
$$;

CREATE OR REPLACE FUNCTION trg_payment_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM refresh_invoice_status(COALESCE(NEW.invoice_id, OLD.invoice_id));
    RETURN NULL;
END $$;

CREATE TRIGGER payment_after
    AFTER INSERT OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION trg_payment_after();


-- A9. Generic audit trigger — records who changed what.
--     The web app sets the session variable app.current_user on each connection.
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, row_data, changed_by)
    VALUES (TG_TABLE_NAME,
            TG_OP,
            CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END,
            COALESCE(NULLIF(current_setting('app.current_user', true), ''), session_user));
    RETURN NULL;
END $$;

CREATE TRIGGER audit_allocation AFTER INSERT OR UPDATE OR DELETE ON allocation    FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_payment    AFTER INSERT OR UPDATE OR DELETE ON payment       FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_student    AFTER INSERT OR UPDATE OR DELETE ON student       FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_leave      AFTER UPDATE                     ON leave_request FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_room       AFTER UPDATE OF status           ON room          FOR EACH ROW EXECUTE FUNCTION trg_audit();


-- =====================================================================
-- B. STORED PROCEDURES  (CALL ...) — each call runs atomically
-- =====================================================================

-- B1. Allocate a room to a student who has none.
CREATE OR REPLACE PROCEDURE allocate_room(
    p_student_id INT,
    p_room_id    INT,
    p_date       DATE DEFAULT CURRENT_DATE,
    p_remarks    TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM allocation WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student already has a room. Use the Move option instead';
    END IF;
    INSERT INTO allocation (student_id, room_id, allocated_on, remarks)
    VALUES (p_student_id, p_room_id, p_date, p_remarks);
END $$;

-- B2. Vacate the student's current room.
CREATE OR REPLACE PROCEDURE vacate_room(p_student_id INT, p_remarks TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE allocation
       SET status = 'VACATED', remarks = COALESCE(p_remarks, remarks)
     WHERE student_id = p_student_id AND status = 'ACTIVE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student has no active room to vacate';
    END IF;
END $$;

-- B3. Move a student to another room.  TRANSACTION DEMO:
--     vacate + allocate happen together; if the new room is full / wrong gender /
--     under maintenance, the exception rolls back the vacate as well.
CREATE OR REPLACE PROCEDURE change_room(p_student_id INT, p_new_room_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_old_room INT;
    v_old_label TEXT;
BEGIN
    SELECT a.room_id, b.block_code || '-' || r.room_no
      INTO v_old_room, v_old_label
      FROM allocation a
      JOIN room r ON r.room_id = a.room_id
      JOIN hostel_block b ON b.block_id = r.block_id
     WHERE a.student_id = p_student_id AND a.status = 'ACTIVE';

    IF v_old_room IS NULL THEN
        RAISE EXCEPTION 'Student has no room yet. Allocate a room first';
    END IF;
    IF v_old_room = p_new_room_id THEN
        RAISE EXCEPTION 'Student is already in this room';
    END IF;

    CALL vacate_room(p_student_id, 'Room change');
    INSERT INTO allocation (student_id, room_id, remarks)
    VALUES (p_student_id, p_new_room_id, 'Moved from ' || v_old_label);
END $$;


-- =====================================================================
-- C. FUNCTIONS
-- =====================================================================

-- C1. Bill every resident for a semester according to their room type.
CREATE OR REPLACE FUNCTION generate_invoices(p_year VARCHAR, p_semester INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM fee_structure WHERE academic_year = p_year AND semester = p_semester) THEN
        RAISE EXCEPTION 'No fee structure defined for % semester %', p_year, p_semester;
    END IF;

    INSERT INTO invoice (student_id, fee_id, amount)
    SELECT a.student_id, f.fee_id, f.amount
      FROM allocation a
      JOIN room r          ON r.room_id = a.room_id
      JOIN fee_structure f ON f.type_code = r.type_code
                          AND f.academic_year = p_year
                          AND f.semester = p_semester
     WHERE a.status = 'ACTIVE'
    ON CONFLICT (student_id, fee_id) DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;

-- C2. Apply late fines on overdue unpaid invoices (Rs 50/day, capped).
CREATE OR REPLACE FUNCTION apply_late_fines(p_per_day NUMERIC DEFAULT 50, p_cap NUMERIC DEFAULT 2000)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_count INT;
BEGIN
    UPDATE invoice i
       SET fine = LEAST((CURRENT_DATE - f.due_date) * p_per_day, p_cap)
      FROM fee_structure f
     WHERE f.fee_id = i.fee_id
       AND i.status <> 'PAID'
       AND CURRENT_DATE > f.due_date
       AND i.fine <> LEAST((CURRENT_DATE - f.due_date) * p_per_day, p_cap);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;

-- C3. Outstanding balance of one student.
CREATE OR REPLACE FUNCTION student_dues(p_student_id INT)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(i.amount + i.fine), 0)
         - COALESCE((SELECT SUM(p.amount)
                       FROM payment p
                       JOIN invoice i2 ON i2.invoice_id = p.invoice_id
                      WHERE i2.student_id = p_student_id), 0)
      FROM invoice i
     WHERE i.student_id = p_student_id;
$$;

-- C4. Login check using bcrypt (password never leaves the database un-hashed comparison).
CREATE OR REPLACE FUNCTION authenticate(p_username TEXT, p_password TEXT)
RETURNS TABLE (user_id INT, username VARCHAR, role VARCHAR, student_id INT)
LANGUAGE sql AS $$
    UPDATE app_user u
       SET last_login = now()
     WHERE u.username = p_username
       AND u.password_hash = crypt(p_password, u.password_hash)
       AND (u.student_id IS NULL OR EXISTS (SELECT 1 FROM student s
                                             WHERE s.student_id = u.student_id AND s.is_active))
    RETURNING u.user_id, u.username, u.role, u.student_id;
$$;


-- =====================================================================
-- D. VIEWS
-- =====================================================================

CREATE OR REPLACE VIEW v_room_status AS
SELECT r.room_id,
       b.block_id, b.block_code, b.block_name, b.gender,
       b.block_code || '-' || r.room_no                 AS room_label,
       r.room_no, r.floor, r.type_code, rt.capacity, rt.has_ac,
       r.current_occupancy,
       rt.capacity - r.current_occupancy                AS vacancies,
       r.status,
       CASE
         WHEN r.status = 'MAINTENANCE'           THEN 'MAINTENANCE'
         WHEN r.current_occupancy = 0            THEN 'EMPTY'
         WHEN r.current_occupancy < rt.capacity  THEN 'PARTIAL'
         ELSE 'FULL'
       END                                              AS occupancy_state
  FROM room r
  JOIN room_type    rt ON rt.type_code = r.type_code
  JOIN hostel_block b  ON b.block_id   = r.block_id;

CREATE OR REPLACE VIEW v_vacant_rooms AS
SELECT * FROM v_room_status
 WHERE status = 'AVAILABLE' AND vacancies > 0;

CREATE OR REPLACE VIEW v_current_residents AS
SELECT s.student_id, s.roll_no, s.name, s.gender, s.phone, s.year_of_study,
       d.dept_code,
       rs.room_id, rs.room_label, rs.block_name, rs.type_code,
       a.allocated_on
  FROM allocation a
  JOIN student s        ON s.student_id = a.student_id
  JOIN department d     ON d.dept_id    = s.dept_id
  JOIN v_room_status rs ON rs.room_id   = a.room_id
 WHERE a.status = 'ACTIVE';

CREATE OR REPLACE VIEW v_student_dues AS
WITH billed AS (
    SELECT student_id, SUM(amount + fine) AS total_billed
      FROM invoice GROUP BY student_id
), paid AS (
    SELECT i.student_id, SUM(p.amount) AS total_paid
      FROM payment p JOIN invoice i ON i.invoice_id = p.invoice_id
     GROUP BY i.student_id
)
SELECT s.student_id, s.roll_no, s.name, s.phone, s.guardian_phone,
       COALESCE(b.total_billed, 0)                               AS total_billed,
       COALESCE(p.total_paid, 0)                                 AS total_paid,
       COALESCE(b.total_billed, 0) - COALESCE(p.total_paid, 0)   AS balance
  FROM student s
  LEFT JOIN billed b ON b.student_id = s.student_id
  LEFT JOIN paid   p ON p.student_id = s.student_id;

CREATE OR REPLACE VIEW v_block_occupancy AS
SELECT b.block_id, b.block_code, b.block_name, b.gender,
       COUNT(r.room_id)                                          AS total_rooms,
       COALESCE(SUM(rt.capacity), 0)                             AS total_beds,
       COALESCE(SUM(r.current_occupancy), 0)                     AS occupied_beds,
       ROUND(100.0 * COALESCE(SUM(r.current_occupancy), 0)
             / NULLIF(SUM(rt.capacity), 0), 1)                   AS occupancy_pct,
       COUNT(*) FILTER (WHERE r.status = 'MAINTENANCE')          AS rooms_in_maintenance,
       w.name                                                    AS warden_name
  FROM hostel_block b
  LEFT JOIN room r       ON r.block_id = b.block_id
  LEFT JOIN room_type rt ON rt.type_code = r.type_code
  LEFT JOIN staff w      ON w.staff_id = b.warden_id
 GROUP BY b.block_id, b.block_code, b.block_name, b.gender, w.name;

CREATE OR REPLACE VIEW v_complaints AS
SELECT c.*, s.roll_no, s.name AS student_name,
       rs.room_label, st.name AS staff_name, st.role AS staff_role,
       COALESCE(c.resolved_at, now()) - c.created_at AS age
  FROM complaint c
  JOIN student s             ON s.student_id = c.student_id
  LEFT JOIN v_room_status rs ON rs.room_id   = c.room_id
  LEFT JOIN staff st         ON st.staff_id  = c.assigned_staff_id;
