import os
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, redirect, session, url_for

from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
IST = ZoneInfo("Asia/Kolkata")
load_dotenv(ROOT / ".env")


def create_app():
    # static files live in /public so Vercel's CDN serves them; Flask serves the same folder locally
    app = Flask(__name__, static_folder=str(ROOT / "public" / "static"), static_url_path="/static")
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret-change-me")

    from . import db
    app.teardown_appcontext(db.close_db)

    from .auth import bp as auth_bp
    from .admin import bp as admin_bp
    from .student import bp as student_bp
    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(student_bp)

    @app.route("/")
    def index():
        if session.get("role") == "ADMIN":
            return redirect(url_for("admin.dashboard"))
        if session.get("role") == "STUDENT":
            return redirect(url_for("student.dashboard"))
        return redirect(url_for("auth.login"))

    # ---------- template filters ----------
    @app.template_filter("inr")
    def inr(value):
        if value is None:
            return "—"
        value = Decimal(value)
        sign = "-" if value < 0 else ""
        value = abs(value)
        whole, frac = f"{value:.2f}".split(".")
        # Indian digit grouping: 12,34,567.00
        if len(whole) > 3:
            head, tail = whole[:-3], whole[-3:]
            groups = []
            while len(head) > 2:
                groups.insert(0, head[-2:])
                head = head[:-2]
            if head:
                groups.insert(0, head)
            whole = ",".join(groups) + "," + tail
        return f"{sign}₹{whole}" + ("" if frac == "00" else f".{frac}")

    @app.template_filter("dt")
    def dt(value, fmt="%d %b %Y, %I:%M %p"):
        if value is None:
            return "—"
        if isinstance(value, datetime):
            return value.astimezone(IST).strftime(fmt)   # server may run in UTC (e.g. on Vercel)
        if isinstance(value, date):
            return value.strftime("%d %b %Y")
        return value

    @app.template_filter("d")
    def d(value):
        return value.strftime("%d %b %Y") if value else "—"

    @app.template_filter("hours")
    def hours(td):
        if td is None:
            return "—"
        h = td.total_seconds() / 3600
        return f"{h:.0f} h" if h < 48 else f"{h / 24:.1f} days"

    @app.context_processor
    def inject_today():
        return {"today": datetime.now(IST).date()}

    return app
