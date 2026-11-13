from datetime import datetime

import psycopg
from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for

from .auth import login_required
from .db import db_error, execute, query

bp = Blueprint("student", __name__, url_prefix="/me")


@bp.before_request
@login_required("STUDENT")
def _guard():
    return None


def sid():
    return session["student_id"]


@bp.route("/")
def dashboard():
    me = query("""
        SELECT s.*, d.dept_name, student_dues(s.student_id) AS balance
          FROM student s JOIN department d ON d.dept_id = s.dept_id
         WHERE s.student_id = %s
    """, (sid(),), one=True)
    room = query("""
        SELECT cr.*, rs.floor, rs.capacity, rs.has_ac, w.name AS warden_name, w.phone AS warden_phone
          FROM v_current_residents cr
          JOIN v_room_status rs ON rs.room_id = cr.room_id
          JOIN hostel_block b   ON b.block_id = rs.block_id
          LEFT JOIN staff w     ON w.staff_id = b.warden_id
         WHERE cr.student_id = %s
    """, (sid(),), one=True)
    roommates = []
    if room:
        roommates = query("""
            SELECT name, roll_no, dept_code, year_of_study, phone FROM v_current_residents
             WHERE room_id = %s AND student_id <> %s ORDER BY name
        """, (room["room_id"], sid()))
    complaints = query("SELECT * FROM v_complaints WHERE student_id = %s ORDER BY created_at DESC LIMIT 5", (sid(),))
    leaves = query("SELECT * FROM leave_request WHERE student_id = %s ORDER BY from_date DESC LIMIT 5", (sid(),))
    return render_template("student/dashboard.html", me=me, room=room, roommates=roommates,
                           complaints=complaints, leaves=leaves)


@bp.route("/fees", methods=["GET", "POST"])
def fees():
    if request.method == "POST":
        inv_id = int(request.form["invoice_id"])
        owner = query("SELECT 1 FROM invoice WHERE invoice_id = %s AND student_id = %s", (inv_id, sid()), one=True)
        if not owner:
            abort(403)
        try:
            execute("INSERT INTO payment (invoice_id, amount, mode, txn_ref) VALUES (%s, %s, %s, %s)",
                    (inv_id, request.form["amount"], request.form["mode"],
                     f"ONL{datetime.now():%Y%m%d%H%M%S}{inv_id}"))
            flash("Payment successful (simulated).", "success")
        except psycopg.Error as e:
            flash(db_error(e), "danger")
        return redirect(url_for("student.fees"))
    invoices = query("""
        SELECT i.*, f.academic_year, f.semester, f.due_date, f.type_code,
               COALESCE((SELECT SUM(amount) FROM payment p WHERE p.invoice_id = i.invoice_id), 0) AS paid
          FROM invoice i JOIN fee_structure f ON f.fee_id = i.fee_id
         WHERE i.student_id = %s ORDER BY f.academic_year DESC, f.semester DESC
    """, (sid(),))
    payments = query("""
        SELECT p.*, f.academic_year, f.semester FROM payment p
          JOIN invoice i ON i.invoice_id = p.invoice_id
          JOIN fee_structure f ON f.fee_id = i.fee_id
         WHERE i.student_id = %s ORDER BY p.paid_on DESC
    """, (sid(),))
    return render_template("student/fees.html", invoices=invoices, payments=payments)


@bp.route("/complaints", methods=["GET", "POST"])
def complaints():
    if request.method == "POST":
        f = request.form
        try:
            execute("INSERT INTO complaint (student_id, category, description, priority) VALUES (%s, %s, %s, %s)",
                    (sid(), f["category"], f["description"].strip(), f["priority"]))
            flash("Complaint submitted.", "success")
        except psycopg.Error as e:
            flash(db_error(e), "danger")
        return redirect(url_for("student.complaints"))
    rows = query("SELECT * FROM v_complaints WHERE student_id = %s ORDER BY created_at DESC", (sid(),))
    return render_template("student/complaints.html", complaints=rows)


@bp.route("/leaves", methods=["GET", "POST"])
def leaves():
    if request.method == "POST":
        f = request.form
        try:
            execute("""
                INSERT INTO leave_request (student_id, from_date, to_date, reason, destination)
                VALUES (%s, %s, %s, %s, %s)
            """, (sid(), f["from_date"], f["to_date"], f["reason"].strip(), f.get("destination") or None))
            flash("Leave request submitted.", "success")
        except psycopg.Error as e:
            flash(db_error(e), "danger")
        return redirect(url_for("student.leaves"))
    rows = query("""
        SELECT l.*, u.username AS reviewer FROM leave_request l
          LEFT JOIN app_user u ON u.user_id = l.reviewed_by
         WHERE l.student_id = %s ORDER BY l.from_date DESC
    """, (sid(),))
    return render_template("student/leaves.html", leaves=rows)


@bp.route("/leaves/<int:leave_id>/cancel", methods=["POST"])
def leave_cancel(leave_id):
    cur = execute("DELETE FROM leave_request WHERE leave_id = %s AND student_id = %s AND status = 'PENDING'",
                  (leave_id, sid()))
    flash("Leave request withdrawn." if cur.rowcount else "Only pending requests can be withdrawn.",
          "success" if cur.rowcount else "warning")
    return redirect(url_for("student.leaves"))


@bp.route("/visitors")
def visitors():
    rows = query("SELECT * FROM visitor WHERE student_id = %s ORDER BY in_time DESC", (sid(),))
    return render_template("student/visitors.html", visitors=rows)
