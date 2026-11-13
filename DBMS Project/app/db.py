"""Thin database layer: one psycopg connection per request, raw SQL only."""
import os

import psycopg
from psycopg.rows import dict_row
from flask import g, session


def get_db() -> psycopg.Connection:
    if "db" not in g:
        g.db = psycopg.connect(
            os.environ["DATABASE_URL"],
            row_factory=dict_row,
            autocommit=True,                       # each statement / CALL is its own transaction
            options="-c search_path=hostel,public",
        )
        # tell the audit trigger who is making changes
        g.db.execute("SELECT set_config('app.current_user', %s, false)",
                     (session.get("username", "anonymous"),))
    return g.db


def close_db(_exc=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def query(sql, params=None, one=False):
    """Run a SELECT and return list of dicts (or one dict / None)."""
    cur = get_db().execute(sql, params)
    rows = cur.fetchall() if cur.description else []
    if one:
        return rows[0] if rows else None
    return rows


def scalar(sql, params=None):
    row = get_db().execute(sql, params).fetchone()
    return None if row is None else next(iter(row.values()))


def execute(sql, params=None):
    """Run INSERT/UPDATE/DELETE/CALL. Returns the cursor (use .rowcount / .fetchone())."""
    return get_db().execute(sql, params)


def db_error(e: Exception) -> str:
    """Turn a PostgreSQL error (often RAISE EXCEPTION from a trigger) into a readable message."""
    if isinstance(e, psycopg.Error) and e.diag and e.diag.message_primary:
        msg = e.diag.message_primary
        friendly = {
            "uq_one_active_alloc": "This student already has an active room.",
            "student_roll_no_key": "A student with this roll number already exists.",
            "student_email_key": "This email is already registered.",
            "no_overlapping_leave": "You already have a leave request overlapping these dates.",
            "uq_room_per_block": "That room number already exists in this block.",
            "uq_fee": "A fee for this room type / year / semester already exists.",
            "staff_phone_key": "A staff member with this phone number already exists.",
            "chk_leave_dates": "End date must be on or after the start date.",
            "student_phone_check": "Phone number must be exactly 10 digits.",
            "student_guardian_phone_check": "Guardian phone must be exactly 10 digits.",
            "staff_phone_check": "Phone number must be exactly 10 digits.",
            "visitor_phone_check": "Phone number must be exactly 10 digits.",
            "student_email_check": "Please enter a valid email address.",
            "student_year_of_study_check": "Year of study must be between 1 and 5.",
            "fee_structure_academic_year_check": "Academic year must look like 2026-27.",
        }
        name = e.diag.constraint_name
        if name in friendly:
            return friendly[name]
        # messages raised on purpose by our own business rules are safe to show
        if e.diag.sqlstate == "P0001":
            return msg
        if e.diag.sqlstate == "23505":
            return "This record already exists."
        if e.diag.sqlstate and e.diag.sqlstate.startswith(("22", "23")):
            return "Some of the entered details are invalid. Please check and try again."
    return "Something went wrong. Please try again."
