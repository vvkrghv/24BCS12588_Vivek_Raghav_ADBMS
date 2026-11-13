# Hostel Management System (DBMS Project)

A hostel management web app built on **PostgreSQL** with a **Flask** front end.
All business rules live in the database as constraints, triggers, stored procedures and views.
The app uses raw SQL (no ORM), so every query is visible.

## Tech stack
| Layer | Tech |
|---|---|
| Database | PostgreSQL 18 (schema `hostel`), extensions `pgcrypto`, `btree_gist` |
| Backend | Python 3.11, Flask 3, psycopg 3 (raw SQL) |
| Frontend | Jinja templates, Bootstrap 5, Chart.js |

## Setup
```bash
pip install -r requirements.txt
copy .env.example .env          # then put your postgres password in .env
python init_db.py               # creates hostel_db, schema, triggers, sample data
python run.py                   # open http://127.0.0.1:5000
```
`python init_db.py` can be re-run at any time to reset to fresh sample data.

**Default logins** (change the admin passwords after first sign-in)
- Admin: `admin` / `admin123` (also `warden` / `warden123`)
- Student: roll number for both username and password, e.g. `23CSE001` / `23CSE001`

## Project structure
```
db/
  01_schema.sql    tables, PK/FK/CHECK/UNIQUE/EXCLUDE constraints, indexes
  02_logic.sql     triggers, stored procedures, functions, views
  03_seed.sql      sample data (36 students, 54 rooms, 3 blocks, fees, complaints, etc.)
  04_reports.sql   14 showcase queries for the report/viva (run in psql/pgAdmin; not part of the app)
app/
  db.py            connection + query helpers, DB-error → friendly message
  auth.py          login (bcrypt check inside PostgreSQL), change password
  admin.py         admin/warden screens
  student.py       student portal
  templates/       Jinja HTML
init_db.py         builds the database
run.py             starts the web server
```

## Features
**Admin / warden:** dashboard with charts · room map per block and floor · register, edit and deactivate students ·
allocate, change and vacate rooms · fee structure, bulk invoice generation, late fines, payment collection ·
complaints with staff assignment · leave approval · visitor check-in/out · staff management

**Student:** room and roommates · fee balance and simulated online payment · raise complaints ·
apply for or withdraw leave · visitor history · change password

## ER overview
```
department 1───* student 1───* allocation *───1 room *───1 room_type
                    │  1                         │ *
                    │  └─1 app_user              └───1 hostel_block 1───* staff
                    ├──* invoice *───1 fee_structure *───1 room_type        (block.warden_id → staff)
                    │       └──* payment
                    ├──* complaint *───1 staff (assigned)
                    ├──* leave_request *───1 app_user (reviewed_by)
                    └──* visitor
audit_log  (written by triggers)
```

## Normalisation notes
- **1NF**: all attributes are atomic (e.g. guardian name and phone are separate columns, with no repeating groups).
- **2NF**: every table has a single-column surrogate PK, so there are no partial dependencies.
  Natural keys are kept as `UNIQUE` (`roll_no`, `(block_id, room_no)`, `(type_code, academic_year, semester)`).
- **3NF / BCNF**: transitive dependencies are split into their own tables.
  - `capacity` and `has_ac` depend on the room *type*, not the room, so they live in `room_type`.
  - Department name depends on the department code, so it lives in `department`.
  - Fee amount depends on (room type, year, semester), so it lives in `fee_structure`.
  - Invoice status and balance come from payments.
- **Deliberate denormalisation** (and why):
  - `room.current_occupancy` is a cached `COUNT` of active allocations, kept correct by triggers, so the
    "is the room full?" check is a single-row lookup and can be locked with `FOR UPDATE`.
  - `invoice.amount` is a snapshot of the fee at billing time, so a later fee change does not rewrite history.

## DBMS concepts and where to find them
| Concept | Where |
|---|---|
| PK, FK (`CASCADE` / `SET NULL`), `UNIQUE`, `NOT NULL` | every table in `01_schema.sql` |
| `CHECK` with regex | phone `^[0-9]{10}$`, email, academic year |
| Multi-column `CHECK` | `chk_alloc_status`: ACTIVE ⇔ `vacated_on IS NULL`; `chk_user_role_student` |
| Circular FK (added with `ALTER TABLE`) | `hostel_block.warden_id` ↔ `staff.block_id` |
| **Partial unique index** | `uq_one_active_alloc`: one ACTIVE allocation per student |
| **Exclusion constraint** | `no_overlapping_leave`: no overlapping leave date ranges (`btree_gist`) |
| Expression / partial indexes | `idx_student_name_lower`, `idx_alloc_room_active`, `idx_visitor_open` |
| **BEFORE triggers** | allocation validation (full / maintenance / gender), payment overflow, complaint auto-status |
| **AFTER triggers** | occupancy counter, invoice status, auto-create login, auto-vacate on deactivation |
| Generic **audit trigger** (`to_jsonb`, `TG_OP`, session variable) | `trg_audit()` → `audit_log` (query it in psql: `SELECT * FROM hostel.audit_log ORDER BY log_id DESC;`) |
| **Stored procedures** (`CALL`) | `allocate_room`, `vacate_room`, `change_room` |
| **Transactions / atomicity** | `change_room`: if the new room is full, the vacate is rolled back too |
| Concurrency control | `SELECT ... FOR UPDATE` on the room row in the allocation trigger |
| Functions | `generate_invoices` (`INSERT ... SELECT ... ON CONFLICT DO NOTHING`), `apply_late_fines`, `student_dues`, `authenticate` |
| **Views** | `v_room_status`, `v_vacant_rooms`, `v_current_residents`, `v_student_dues` (CTEs), `v_block_occupancy`, `v_complaints` |
| Password security | bcrypt with `crypt()` / `gen_salt('bf')`, verified inside the DB |
| Joins, `GROUP BY`/`HAVING`, subqueries, window functions, `UNION`, ranges, `EXPLAIN` | `04_reports.sql` |

Link - https://hostel-management-system-wine-six.vercel.app/login
