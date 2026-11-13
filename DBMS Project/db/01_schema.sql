-- =====================================================================
--  HOSTEL MANAGEMENT SYSTEM  —  01_schema.sql
--  DDL: schema, tables, constraints, indexes
--  Normalised to 3NF / BCNF (see README for the normalisation notes)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- crypt()/gen_salt() for bcrypt password hashes
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- lets us mix "=" and "&&" in an EXCLUDE constraint

DROP SCHEMA IF EXISTS hostel CASCADE;
CREATE SCHEMA hostel;
SET search_path = hostel, public;

-- every new connection to this database should see the hostel schema first
DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET search_path = hostel, public', current_database());
END $$;

-- ---------------------------------------------------------------------
-- 1. Lookup / master tables
-- ---------------------------------------------------------------------
CREATE TABLE department (
    dept_id     SERIAL PRIMARY KEY,
    dept_code   VARCHAR(10)  NOT NULL UNIQUE,
    dept_name   VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE room_type (
    type_code   VARCHAR(12) PRIMARY KEY,                 -- SINGLE, DOUBLE, DOUBLE-AC, TRIPLE
    capacity    SMALLINT    NOT NULL CHECK (capacity BETWEEN 1 AND 6),
    has_ac      BOOLEAN     NOT NULL DEFAULT FALSE,
    description TEXT
);

-- ---------------------------------------------------------------------
-- 2. Blocks and staff  (circular FK: block.warden_id <-> staff.block_id)
-- ---------------------------------------------------------------------
CREATE TABLE hostel_block (
    block_id     SERIAL PRIMARY KEY,
    block_code   CHAR(1)     NOT NULL UNIQUE CHECK (block_code ~ '^[A-Z]$'),
    block_name   VARCHAR(50) NOT NULL UNIQUE,
    gender       CHAR(1)     NOT NULL CHECK (gender IN ('M', 'F')),
    total_floors SMALLINT    NOT NULL CHECK (total_floors BETWEEN 1 AND 20),
    warden_id    INT                                     -- FK added after staff exists
);

CREATE TABLE staff (
    staff_id   SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    role       VARCHAR(20)  NOT NULL
               CHECK (role IN ('WARDEN','SECURITY','CLEANER','ELECTRICIAN','PLUMBER','CARPENTER','MESS')),
    phone      VARCHAR(10)  NOT NULL UNIQUE CHECK (phone ~ '^[0-9]{10}$'),
    block_id   INT REFERENCES hostel_block(block_id) ON DELETE SET NULL,
    salary     NUMERIC(10,2) CHECK (salary > 0),
    joined_on  DATE    NOT NULL DEFAULT CURRENT_DATE,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE
);

ALTER TABLE hostel_block
    ADD CONSTRAINT fk_block_warden
    FOREIGN KEY (warden_id) REFERENCES staff(staff_id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------
-- 3. Rooms
-- ---------------------------------------------------------------------
CREATE TABLE room (
    room_id           SERIAL PRIMARY KEY,
    block_id          INT         NOT NULL REFERENCES hostel_block(block_id) ON DELETE CASCADE,
    room_no           VARCHAR(10) NOT NULL,
    floor             SMALLINT    NOT NULL CHECK (floor >= 0),
    type_code         VARCHAR(12) NOT NULL REFERENCES room_type(type_code),
    -- derived value kept in sync by triggers (controlled denormalisation for fast lookups)
    current_occupancy SMALLINT    NOT NULL DEFAULT 0 CHECK (current_occupancy >= 0),
    status            VARCHAR(12) NOT NULL DEFAULT 'AVAILABLE'
                      CHECK (status IN ('AVAILABLE', 'MAINTENANCE')),
    CONSTRAINT uq_room_per_block UNIQUE (block_id, room_no)
);

-- ---------------------------------------------------------------------
-- 4. Students and login accounts
-- ---------------------------------------------------------------------
CREATE TABLE student (
    student_id     SERIAL PRIMARY KEY,
    roll_no        VARCHAR(20)  NOT NULL UNIQUE,
    name           VARCHAR(100) NOT NULL,
    gender         CHAR(1)      NOT NULL CHECK (gender IN ('M', 'F')),
    dob            DATE         CHECK (dob > DATE '1980-01-01'),
    phone          VARCHAR(10)  NOT NULL CHECK (phone ~ '^[0-9]{10}$'),
    email          VARCHAR(120) UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    dept_id        INT          NOT NULL REFERENCES department(dept_id),
    year_of_study  SMALLINT     NOT NULL CHECK (year_of_study BETWEEN 1 AND 5),
    guardian_name  VARCHAR(100),
    guardian_phone VARCHAR(10)  CHECK (guardian_phone ~ '^[0-9]{10}$'),
    address        TEXT,
    admitted_on    DATE    NOT NULL DEFAULT CURRENT_DATE,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE app_user (
    user_id       SERIAL PRIMARY KEY,
    username      VARCHAR(50) NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,                   -- bcrypt via pgcrypto
    role          VARCHAR(10) NOT NULL CHECK (role IN ('ADMIN', 'STUDENT')),
    student_id    INT UNIQUE REFERENCES student(student_id) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login    TIMESTAMPTZ,
    -- a STUDENT account must point to a student; an ADMIN account must not
    CONSTRAINT chk_user_role_student CHECK ((role = 'STUDENT') = (student_id IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 5. Room allocation (history is kept; one ACTIVE row per student)
-- ---------------------------------------------------------------------
CREATE TABLE allocation (
    alloc_id     SERIAL PRIMARY KEY,
    student_id   INT  NOT NULL REFERENCES student(student_id) ON DELETE CASCADE,
    room_id      INT  NOT NULL REFERENCES room(room_id),
    allocated_on DATE NOT NULL DEFAULT CURRENT_DATE,
    vacated_on   DATE,
    status       VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'VACATED')),
    remarks      TEXT,
    CONSTRAINT chk_alloc_dates  CHECK (vacated_on IS NULL OR vacated_on >= allocated_on),
    CONSTRAINT chk_alloc_status CHECK ((status = 'ACTIVE') = (vacated_on IS NULL))
);
-- partial unique index: a student can hold at most ONE active allocation
CREATE UNIQUE INDEX uq_one_active_alloc ON allocation(student_id) WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- 6. Fees: structure -> invoice -> payment
-- ---------------------------------------------------------------------
CREATE TABLE fee_structure (
    fee_id        SERIAL PRIMARY KEY,
    type_code     VARCHAR(12)   NOT NULL REFERENCES room_type(type_code),
    academic_year VARCHAR(7)    NOT NULL CHECK (academic_year ~ '^[0-9]{4}-[0-9]{2}$'),  -- e.g. 2026-27
    semester      SMALLINT      NOT NULL CHECK (semester IN (1, 2)),
    amount        NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    due_date      DATE          NOT NULL,
    CONSTRAINT uq_fee UNIQUE (type_code, academic_year, semester)
);

CREATE TABLE invoice (
    invoice_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES student(student_id) ON DELETE CASCADE,
    fee_id     INT NOT NULL REFERENCES fee_structure(fee_id),
    amount     NUMERIC(10,2) NOT NULL CHECK (amount > 0),   -- price snapshot at billing time
    fine       NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine >= 0),
    issued_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    status     VARCHAR(10) NOT NULL DEFAULT 'UNPAID' CHECK (status IN ('UNPAID', 'PARTIAL', 'PAID')),
    CONSTRAINT uq_invoice UNIQUE (student_id, fee_id)
);

CREATE TABLE payment (
    payment_id SERIAL PRIMARY KEY,
    invoice_id INT NOT NULL REFERENCES invoice(invoice_id) ON DELETE CASCADE,
    amount     NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    paid_on    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    mode       VARCHAR(12)   NOT NULL CHECK (mode IN ('CASH','UPI','CARD','NETBANKING','DD')),
    txn_ref    VARCHAR(40)   UNIQUE
);

-- ---------------------------------------------------------------------
-- 7. Complaints, leave, visitors
-- ---------------------------------------------------------------------
CREATE TABLE complaint (
    complaint_id      SERIAL PRIMARY KEY,
    student_id        INT NOT NULL REFERENCES student(student_id) ON DELETE CASCADE,
    room_id           INT REFERENCES room(room_id),
    category          VARCHAR(15) NOT NULL
                      CHECK (category IN ('ELECTRICAL','PLUMBING','CLEANING','FURNITURE','INTERNET','MESS','OTHER')),
    description       TEXT NOT NULL CHECK (length(trim(description)) >= 5),
    priority          VARCHAR(6)  NOT NULL DEFAULT 'MEDIUM' CHECK (priority IN ('LOW','MEDIUM','HIGH')),
    status            VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','RESOLVED')),
    assigned_staff_id INT REFERENCES staff(staff_id) ON DELETE SET NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at       TIMESTAMPTZ,
    CONSTRAINT chk_resolved CHECK (resolved_at IS NULL OR resolved_at >= created_at)
);

CREATE TABLE leave_request (
    leave_id    SERIAL PRIMARY KEY,
    student_id  INT  NOT NULL REFERENCES student(student_id) ON DELETE CASCADE,
    from_date   DATE NOT NULL,
    to_date     DATE NOT NULL,
    reason      TEXT NOT NULL,
    destination VARCHAR(100),
    status      VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    reviewed_by INT REFERENCES app_user(user_id) ON DELETE SET NULL,
    applied_on  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_leave_dates CHECK (to_date >= from_date),
    -- EXCLUSION constraint: the same student cannot have two overlapping (non-rejected) leaves
    CONSTRAINT no_overlapping_leave EXCLUDE USING gist (
        student_id WITH =,
        daterange(from_date, to_date, '[]') WITH &&
    ) WHERE (status <> 'REJECTED')
);

CREATE TABLE visitor (
    visitor_id   SERIAL PRIMARY KEY,
    student_id   INT NOT NULL REFERENCES student(student_id) ON DELETE CASCADE,
    visitor_name VARCHAR(100) NOT NULL,
    relation     VARCHAR(30)  NOT NULL,
    phone        VARCHAR(10)  CHECK (phone ~ '^[0-9]{10}$'),
    in_time      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    out_time     TIMESTAMPTZ,
    CONSTRAINT chk_visit_time CHECK (out_time IS NULL OR out_time >= in_time)
);

-- ---------------------------------------------------------------------
-- 8. Audit log (filled by triggers)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id     BIGSERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    operation  TEXT NOT NULL,
    row_data   JSONB,
    changed_by TEXT,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 9. Indexes (beyond the ones created automatically for PK / UNIQUE)
-- ---------------------------------------------------------------------
CREATE INDEX idx_student_name_lower  ON student (lower(name));          -- expression index for search
CREATE INDEX idx_student_dept        ON student (dept_id);
CREATE INDEX idx_room_block          ON room (block_id);
CREATE INDEX idx_alloc_room_active   ON allocation (room_id) WHERE status = 'ACTIVE';
CREATE INDEX idx_invoice_student     ON invoice (student_id);
CREATE INDEX idx_payment_invoice     ON payment (invoice_id);
CREATE INDEX idx_complaint_status    ON complaint (status);
CREATE INDEX idx_complaint_student   ON complaint (student_id);
CREATE INDEX idx_leave_student       ON leave_request (student_id);
CREATE INDEX idx_visitor_open        ON visitor (student_id) WHERE out_time IS NULL;
CREATE INDEX idx_audit_time          ON audit_log (changed_at DESC);
