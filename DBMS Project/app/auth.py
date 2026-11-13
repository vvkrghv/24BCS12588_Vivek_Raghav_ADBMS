from functools import wraps

from flask import Blueprint, flash, redirect, render_template, request, session, url_for

from .db import db_error, execute, query

bp = Blueprint("auth", __name__)


def login_required(role):
    def decorator(view):
        @wraps(view)
        def wrapped(*args, **kwargs):
            if session.get("role") != role:
                flash("Please log in to continue.", "warning")
                return redirect(url_for("auth.login", next=request.path))
            return view(*args, **kwargs)
        return wrapped
    return decorator


@bp.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        # password is verified inside PostgreSQL with bcrypt (pgcrypto)
        user = query("SELECT * FROM authenticate(%s, %s)", (username, password), one=True)
        if user:
            session.clear()
            session.update(user_id=user["user_id"], username=user["username"],
                           role=user["role"], student_id=user["student_id"])
            nxt = request.args.get("next")
            if nxt and nxt.startswith("/"):
                return redirect(nxt)
            return redirect(url_for("index"))
        flash("Invalid username or password.", "danger")
    return render_template("login.html")


@bp.route("/logout")
def logout():
    session.clear()
    flash("Logged out.", "info")
    return redirect(url_for("auth.login"))


@bp.route("/password", methods=["GET", "POST"])
def change_password():
    if "user_id" not in session:
        return redirect(url_for("auth.login"))
    if request.method == "POST":
        old, new, confirm = (request.form.get(k, "") for k in ("old", "new", "confirm"))
        if len(new) < 6:
            flash("New password must be at least 6 characters.", "danger")
        elif new != confirm:
            flash("New passwords do not match.", "danger")
        else:
            try:
                cur = execute("""
                    UPDATE app_user SET password_hash = crypt(%s, gen_salt('bf', 8))
                     WHERE user_id = %s AND password_hash = crypt(%s, password_hash)
                """, (new, session["user_id"], old))
                if cur.rowcount:
                    flash("Password changed successfully.", "success")
                    return redirect(url_for("index"))
                flash("Current password is incorrect.", "danger")
            except Exception as e:
                flash(db_error(e), "danger")
    return render_template("change_password.html")
