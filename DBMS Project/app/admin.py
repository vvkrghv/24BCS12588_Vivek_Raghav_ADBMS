import psycopg
from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for

from .auth import login_required
from .db import db_error, execute, query, scalar

bp = Blueprint("admin", __name__, url_prefix="/admin")


@bp.before_request
@login_required("ADMIN")
def _guard():
    return None


def attempt(success_msg, sql, params=None):
    """Execute a write; flash success or the database's own error message."""
    try:
        cur = execute(sql, params)
        flash(success_msg, "success")
        return cur
    except psycopg.Error as e:
        flash(db_error(e), "danger")
        return None


def back(default="admin.dashboard", **kw):
    return redirect(request.form.get("next") or request.referrer or url_for(default, **kw))


# ======================================================================
# Dashboard
# ======================================================================
@bp.route("/")
def dashboard():
    stats = query("""
        SELECT (SELECT COUNT(*) FROM student WHERE is_active)                     AS students,
               (SELECT COUNT(*) FROM allocation WHERE status = 'ACTIVE')          AS residents,
               (SELECT SUM(capacity) FROM v_room_status)                          AS beds,
               (SELECT COALESCE(SUM(vacancies), 0) FROM v_vacant_rooms)           AS free_beds,
               (SELECT COALESCE(SUM(balance), 0) FROM v_student_dues WHERE balance > 0) AS dues,
               (SELECT COUNT(*) FROM v_student_dues WHERE balance > 0)            AS defaulters,
               (SELECT COALESCE(SUM(amount), 0) FROM payment)                     AS collected,
               (SELECT COUNT(*) FROM complaint WHERE status <> 'RESOLVED')        AS open_complaints,
               (SELECT COUNT(*) FROM leave_request WHERE status = 'PENDING')      AS pending_leaves,
               (SELECT COUNT(*) FROM visitor WHERE out_time IS NULL)              AS visitors_inside
    """, one=True)
    blocks = query("SELECT * FROM v_block_occupancy ORDER BY block_code")
    room_states = query("""
        SELECT occupancy_state, COUNT(*) AS n FROM v_room_status
         GROUP BY occupancy_state ORDER BY occupancy_state
    """)
    complaints_by_cat = query("""
        SELECT category, COUNT(*) FILTER (WHERE status <> 'RESOLVED') AS open,
               COUNT(*) FILTER (WHERE status = 'RESOLVED') AS resolved
          FROM complaint GROUP BY category ORDER BY category
    """)
    recent_complaints = query("""
        SELECT * FROM v_complaints WHERE status <> 'RESOLVED'
         ORDER BY priority = 'HIGH' DESC, created_at DESC LIMIT 6
    """)
    pending_leaves = query("""
        SELECT l.*, s.roll_no, s.name FROM leave_request l
          JOIN student s ON s.student_id = l.student_id
         WHERE l.status = 'PENDING' ORDER BY l.from_date LIMIT 6
    """)
    return render_template("admin/dashboard.html", stats=stats, blocks=blocks,
                           room_states=room_states, complaints_by_cat=complaints_by_cat,
                           recent_complaints=recent_complaints, pending_leaves=pending_leaves)


# ======================================================================
# Rooms
# ======================================================================
@bp.route("/rooms")
def rooms():
    block = request.args.get("block", "")
    rtype = request.args.get("type", "")
    rooms = query("""
        SELECT * FROM v_room_status
         WHERE (%(block)s = '' OR block_code = %(block)s)
           AND (%(type)s  = '' OR type_code  = %(type)s)
         ORDER BY block_code, floor, room_no
    """, {"block": block, "type": rtype})
    # group: block -> floor -> [rooms]
    grouped = {}
    for r in rooms:
        grouped.setdefault((r["block_code"], r["block_name"], r["gender"]), {}) \
               .setdefault(r["floor"], []).append(r)
    return render_template("admin/rooms.html", grouped=grouped,
                           blocks=query("SELECT * FROM hostel_block ORDER BY block_code"),
                           types=query("SELECT * FROM room_type ORDER BY capacity, type_code"),
                           block=block, rtype=rtype)


@bp.route("/rooms/add", methods=["POST"])
def room_add():
    f = request.form
    attempt("Room added.", """
        INSERT INTO room (block_id, room_no, floor, type_code) VALUES (%s, %s, %s, %s)
    """, (f["block_id"], f["room_no"].strip(), f["floor"], f["type_code"]))
    return back("admin.rooms")


@bp.route("/rooms/<int:room_id>")
def room_detail(room_id):
    room = query("SELECT * FROM v_room_status WHERE room_id = %s", (room_id,), one=True) or abort(404)
    history = query("""
        SELECT a.*, s.roll_no, s.name FROM allocation a
          JOIN student s ON s.student_id = a.student_id
         WHERE a.room_id = %s ORDER BY a.status, a.allocated_on DESC, a.alloc_id DESC
    """, (room_id,))
    complaints = query("SELECT * FROM v_complaints WHERE room_id = %s ORDER BY created_at DESC", (room_id,))
    candidates = query("""
        SELECT s.student_id, s.roll_no, s.name FROM student s
         WHERE s.is_active AND s.gender = %s
           AND NOT EXISTS (SELECT 1 FROM allocation a WHERE a.student_id = s.student_id AND a.status = 'ACTIVE')
         ORDER BY s.name
    """, (room["gender"],))
    return render_template("admin/room_detail.html", room=room, history=history,
                           complaints=complaints, candidates=candidates)


@bp.route("/rooms/<int:room_id>/status", methods=["POST"])
def room_status(room_id):
    new = request.form["status"]
    attempt(f"Room marked {new.lower()}.",
            "UPDATE room SET status = %s WHERE room_id = %s", (new, room_id))
    return back()


# ======================================================================
# Students
# ======================================================================
STUDENT_FILTERS = {
    "": "TRUE",
    "allocated": "s.is_active AND cr.room_id IS NOT NULL",
    "unallocated": "s.is_active AND cr.room_id IS NULL",
    "dues": "sd.balance > 0",
    "inactive": "NOT s.is_active",
}


@bp.route("/students")
def students():
    q = request.args.get("q", "").strip()
    flt = request.args.get("filter", "")
    dept = request.args.get("dept", "")
    where = STUDENT_FILTERS.get(flt, "TRUE")       # chosen from a fixed whitelist — never user text
    rows = query(f"""
        SELECT s.*, d.dept_code, cr.room_id, cr.room_label, sd.balance
          FROM student s
          JOIN department d            ON d.dept_id = s.dept_id
          LEFT JOIN v_current_residents cr ON cr.student_id = s.student_id
          LEFT JOIN v_student_dues sd      ON sd.student_id = s.student_id
         WHERE {where}
           AND (%(q)s = '' OR s.roll_no ILIKE %(like)s OR lower(s.name) LIKE lower(%(like)s))
           AND (%(dept)s = '' OR d.dept_code = %(dept)s)
         ORDER BY s.roll_no
    """, {"q": q, "like": f"%{q}%", "dept": dept})
    return render_template("admin/students.html", students=rows, q=q, flt=flt, dept=dept,
                           departments=query("SELECT * FROM department ORDER BY dept_code"))


STUDENT_FIELDS = ["roll_no", "name", "gender", "dob", "phone", "email", "dept_id", "year_of_study",
                  "guardian_name", "guardian_phone", "address"]


def _student_params(form):
    return {k: (form.get(k, "").strip() or None) for k in STUDENT_FIELDS}


@bp.route("/students/new", methods=["GET", "POST"])
def student_new():
    if request.method == "POST":
        p = _student_params(request.form)
        try:
            sid = scalar("""
                INSERT INTO student (roll_no, name, gender, dob, phone, email, dept_id, year_of_study,
                                     guardian_name, guardian_phone, address)
                VALUES (%(roll_no)s, %(name)s, %(gender)s, %(dob)s, %(phone)s, %(email)s, %(dept_id)s,
                        %(year_of_study)s, %(guardian_name)s, %(guardian_phone)s, %(address)s)
                RETURNING student_id
            """, p)
            flash(f"Student registered. Login: {p['roll_no']} / {p['roll_no']}", "success")
            return redirect(url_for("admin.student_detail", student_id=sid))
        except psycopg.Error as e:
            flash(db_error(e), "danger")
            return render_template("admin/student_form.html", s=p, departments=_depts(), new=True)
    return render_template("admin/student_form.html", s={}, departments=_depts(), new=True)


@bp.route("/students/<int:student_id>/edit", methods=["GET", "POST"])
def student_edit(student_id):
    if request.method == "POST":
        p = _student_params(request.form) | {"student_id": student_id}
        try:
            execute("""
                UPDATE student SET roll_no=%(roll_no)s, name=%(name)s, gender=%(gender)s, dob=%(dob)s,
                       phone=%(phone)s, email=%(email)s, dept_id=%(dept_id)s, year_of_study=%(year_of_study)s,
                       guardian_name=%(guardian_name)s, guardian_phone=%(guardian_phone)s, address=%(address)s
                 WHERE student_id = %(student_id)s
            """, p)
            flash("Student updated.", "success")
            return redirect(url_for("admin.student_detail", student_id=student_id))
        except psycopg.Error as e:
            flash(db_error(e), "danger")
            return render_template("admin/student_form.html", s=p, departments=_depts(), new=False)
    s = query("SELECT * FROM student WHERE student_id = %s", (student_id,), one=True) or abort(404)
    return render_template("admin/student_form.html", s=s, departments=_depts(), new=False)


def _depts():
    return query("SELECT * FROM department ORDER BY dept_code")


@bp.route("/students/<int:student_id>")
def student_detail(student_id):
    s = query("""
        SELECT s.*, d.dept_name, d.dept_code, student_dues(s.student_id) AS balance
          FROM student s JOIN department d ON d.dept_id = s.dept_id
         WHERE s.student_id = %s
    """, (student_id,), one=True) or abort(404)
    current = query("SELECT * FROM v_current_residents WHERE student_id = %s", (student_id,), one=True)
    history = query("""
        SELECT a.*, rs.room_label, rs.type_code FROM allocation a
          JOIN v_room_status rs ON rs.room_id = a.room_id
         WHERE a.student_id = %s ORDER BY a.alloc_id DESC
    """, (student_id,))
    invoices = query("""
        SELECT i.*, f.academic_year, f.semester, f.due_date, f.type_code,
               COALESCE((SELECT SUM(amount) FROM payment p WHERE p.invoice_id = i.invoice_id), 0) AS paid
          FROM invoice i JOIN fee_structure f ON f.fee_id = i.fee_id
         WHERE i.student_id = %s ORDER BY f.academic_year DESC, f.semester DESC
    """, (student_id,))
    vacant = query("""
        SELECT * FROM v_vacant_rooms WHERE gender = %s
         ORDER BY block_code, floor, room_no
    """, (s["gender"],))
    complaints = query("SELECT * FROM v_complaints WHERE student_id = %s ORDER BY created_at DESC", (student_id,))
    leaves = query("SELECT * FROM leave_request WHERE student_id = %s ORDER BY from_date DESC", (student_id,))
    return render_template("admin/student_detail.html", s=s, current=current, history=history,
                           invoices=invoices, vacant=vacant, complaints=complaints, leaves=leaves)


@bp.route("/students/<int:student_id>/allocate", methods=["POST"])
def student_allocate(student_id):
    attempt("Room allocated.", "CALL allocate_room(%s, %s)", (student_id, int(request.form["room_id"])))
    return back()


@bp.route("/students/<int:student_id>/change-room", methods=["POST"])
def student_change_room(student_id):
    attempt("Room changed.", "CALL change_room(%s, %s)", (student_id, int(request.form["room_id"])))
    return back()


@bp.route("/students/<int:student_id>/vacate", methods=["POST"])
def student_vacate(student_id):
    attempt("Room vacated.", "CALL vacate_room(%s, %s)", (student_id, request.form.get("remarks") or None))
    return back()


@bp.route("/students/<int:student_id>/toggle-active", methods=["POST"])
def student_toggle(student_id):
    attempt("Student status updated.",
            "UPDATE student SET is_active = NOT is_active WHERE student_id = %s", (student_id,))
    return back()


@bp.route("/students/<int:student_id>/reset-password", methods=["POST"])
def student_reset_password(student_id):
    attempt("Password reset to the roll number.", """
        UPDATE app_user u SET password_hash = crypt(s.roll_no, gen_salt('bf', 8))
          FROM student s WHERE s.student_id = u.student_id AND u.student_id = %s
    """, (student_id,))
    return back()


# ======================================================================
# Fees
# ======================================================================
@bp.route("/fees")
def fees():
    status = request.args.get("status", "")
    term = request.args.get("term", "")
    structure = query("""
        SELECT f.*, (SELECT COUNT(*) FROM invoice i WHERE i.fee_id = f.fee_id) AS invoices
          FROM fee_structure f ORDER BY academic_year DESC, semester DESC, amount DESC
    """)
    terms = query("SELECT DISTINCT academic_year, semester FROM fee_structure ORDER BY 1 DESC, 2 DESC")
    invoices = query("""
        SELECT i.*, s.roll_no, s.name, f.academic_year, f.semester, f.due_date, f.type_code,
               COALESCE(p.paid, 0) AS paid,
               i.amount + i.fine - COALESCE(p.paid, 0) AS balance
          FROM invoice i
          JOIN student s       ON s.student_id = i.student_id
          JOIN fee_structure f ON f.fee_id = i.fee_id
          LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM payment GROUP BY invoice_id) p
                 ON p.invoice_id = i.invoice_id
         WHERE (%(status)s = '' OR i.status = %(status)s)
           AND (%(term)s = '' OR f.academic_year || '/' || f.semester = %(term)s)
         ORDER BY i.status = 'PAID', balance DESC, s.roll_no
    """, {"status": status, "term": term})
    summary = query("""
        SELECT COALESCE(SUM(i.amount + i.fine), 0) AS billed,
               COALESCE((SELECT SUM(amount) FROM payment), 0) AS collected,
               COALESCE(SUM(i.fine), 0) AS fines
          FROM invoice i
    """, one=True)
    return render_template("admin/fees.html", structure=structure, terms=terms, invoices=invoices,
                           summary=summary, status=status, term=term,
                           types=query("SELECT * FROM room_type ORDER BY capacity"))


@bp.route("/fees/structure", methods=["POST"])
def fee_add():
    f = request.form
    attempt("Fee added.", """
        INSERT INTO fee_structure (type_code, academic_year, semester, amount, due_date)
        VALUES (%s, %s, %s, %s, %s)
    """, (f["type_code"], f["academic_year"].strip(), f["semester"], f["amount"], f["due_date"]))
    return back("admin.fees")


@bp.route("/fees/generate", methods=["POST"])
def fee_generate():
    year, sem = request.form["term"].split("/")
    try:
        n = scalar("SELECT generate_invoices(%s, %s)", (year, int(sem)))
        flash(f"{n} new invoice(s) generated for {year} semester {sem}.", "success" if n else "info")
    except psycopg.Error as e:
        flash(db_error(e), "danger")
    return back("admin.fees")


@bp.route("/fees/fines", methods=["POST"])
def fee_fines():
    n = scalar("SELECT apply_late_fines()")
    flash(f"Late fines updated on {n} invoice(s).", "success" if n else "info")
    return back("admin.fees")


@bp.route("/invoices/<int:invoice_id>", methods=["GET", "POST"])
def invoice(invoice_id):
    if request.method == "POST":
        f = request.form
        attempt("Payment recorded.", """
            INSERT INTO payment (invoice_id, amount, mode, txn_ref) VALUES (%s, %s, %s, %s)
        """, (invoice_id, f["amount"], f["mode"], f.get("txn_ref", "").strip() or None))
        return redirect(url_for("admin.invoice", invoice_id=invoice_id))
    inv = query("""
        SELECT i.*, s.student_id, s.roll_no, s.name, f.academic_year, f.semester, f.due_date, f.type_code,
               COALESCE((SELECT SUM(amount) FROM payment p WHERE p.invoice_id = i.invoice_id), 0) AS paid
          FROM invoice i
          JOIN student s ON s.student_id = i.student_id
          JOIN fee_structure f ON f.fee_id = i.fee_id
         WHERE i.invoice_id = %s
    """, (invoice_id,), one=True) or abort(404)
    payments = query("SELECT * FROM payment WHERE invoice_id = %s ORDER BY paid_on", (invoice_id,))
    return render_template("admin/invoice.html", inv=inv, payments=payments)


# ======================================================================
# Complaints
# ======================================================================
@bp.route("/complaints")
def complaints():
    status = request.args.get("status", "active")
    rows = query("""
        SELECT * FROM v_complaints
         WHERE (%(s)s = 'all') OR (%(s)s = 'active' AND status <> 'RESOLVED') OR status = %(s)s
         ORDER BY status = 'RESOLVED', CASE priority WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END,
                  created_at DESC
    """, {"s": status})
    staff = query("""
        SELECT staff_id, name, role FROM staff
         WHERE is_active AND role <> 'WARDEN' AND role <> 'SECURITY' ORDER BY role, name
    """)
    return render_template("admin/complaints.html", complaints=rows, staff=staff, status=status)


@bp.route("/complaints/<int:cid>", methods=["POST"])
def complaint_update(cid):
    f = request.form
    attempt("Complaint updated.", """
        UPDATE complaint SET status = %s, assigned_staff_id = %s WHERE complaint_id = %s
    """, (f["status"], f.get("staff_id") or None, cid))
    return back("admin.complaints")


# ======================================================================
# Leave requests
# ======================================================================
@bp.route("/leaves")
def leaves():
    status = request.args.get("status", "PENDING")
    rows = query("""
        SELECT l.*, s.roll_no, s.name, s.guardian_phone, cr.room_label, u.username AS reviewer
          FROM leave_request l
          JOIN student s ON s.student_id = l.student_id
          LEFT JOIN v_current_residents cr ON cr.student_id = l.student_id
          LEFT JOIN app_user u ON u.user_id = l.reviewed_by
         WHERE %(s)s = 'ALL' OR l.status = %(s)s
         ORDER BY l.from_date DESC
    """, {"s": status})
    return render_template("admin/leaves.html", leaves=rows, status=status)


@bp.route("/leaves/<int:leave_id>/<decision>", methods=["POST"])
def leave_review(leave_id, decision):
    if decision not in ("APPROVED", "REJECTED"):
        abort(400)
    attempt(f"Leave {decision.lower()}.", """
        UPDATE leave_request SET status = %s, reviewed_by = %s
         WHERE leave_id = %s AND status = 'PENDING'
    """, (decision, session["user_id"], leave_id))
    return back("admin.leaves")


# ======================================================================
# Visitors
# ======================================================================
@bp.route("/visitors", methods=["GET", "POST"])
def visitors():
    if request.method == "POST":
        f = request.form
        attempt("Visitor checked in.", """
            INSERT INTO visitor (student_id, visitor_name, relation, phone) VALUES (%s, %s, %s, %s)
        """, (f["student_id"], f["visitor_name"].strip(), f["relation"].strip(), f.get("phone") or None))
        return redirect(url_for("admin.visitors"))
    rows = query("""
        SELECT v.*, s.roll_no, s.name AS student_name, cr.room_label
          FROM visitor v
          JOIN student s ON s.student_id = v.student_id
          LEFT JOIN v_current_residents cr ON cr.student_id = v.student_id
         ORDER BY v.out_time IS NOT NULL, v.in_time DESC LIMIT 200
    """)
    residents = query("SELECT student_id, roll_no, name, room_label FROM v_current_residents ORDER BY name")
    return render_template("admin/visitors.html", visitors=rows, residents=residents)


@bp.route("/visitors/<int:vid>/checkout", methods=["POST"])
def visitor_checkout(vid):
    attempt("Visitor checked out.", "UPDATE visitor SET out_time = now() WHERE visitor_id = %s AND out_time IS NULL", (vid,))
    return back("admin.visitors")


# ======================================================================
# Staff
# ======================================================================
@bp.route("/staff", methods=["GET", "POST"])
def staff():
    if request.method == "POST":
        f = request.form
        attempt("Staff member added.", """
            INSERT INTO staff (name, role, phone, block_id, salary) VALUES (%s, %s, %s, %s, %s)
        """, (f["name"].strip(), f["role"], f["phone"].strip(), f.get("block_id") or None, f.get("salary") or None))
        return redirect(url_for("admin.staff"))
    rows = query("""
        SELECT st.*, b.block_name,
               (SELECT COUNT(*) FROM complaint c WHERE c.assigned_staff_id = st.staff_id AND c.status <> 'RESOLVED') AS open_jobs,
               EXISTS (SELECT 1 FROM hostel_block hb WHERE hb.warden_id = st.staff_id) AS is_block_warden
          FROM staff st LEFT JOIN hostel_block b ON b.block_id = st.block_id
         ORDER BY st.is_active DESC, st.role, st.name
    """)
    return render_template("admin/staff.html", staff=rows,
                           blocks=query("SELECT * FROM hostel_block ORDER BY block_code"))


@bp.route("/staff/<int:staff_id>/toggle", methods=["POST"])
def staff_toggle(staff_id):
    attempt("Staff status updated.", "UPDATE staff SET is_active = NOT is_active WHERE staff_id = %s", (staff_id,))
    return back("admin.staff")
