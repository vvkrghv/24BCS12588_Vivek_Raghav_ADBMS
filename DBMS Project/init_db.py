"""Create the database (if needed) and load schema, logic and seed data.

Usage:  python init_db.py                      -> full reset (schema + logic + sample data)
        python init_db.py --no-seed            -> empty database with schema + logic only
        python init_db.py --env .env.vercel    -> use another env file (e.g. the cloud database)
"""
import os
import sys
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from dotenv import load_dotenv

ROOT = Path(__file__).parent
env_file = ROOT / ".env"
if "--env" in sys.argv:
    env_file = ROOT / sys.argv[sys.argv.index("--env") + 1]
load_dotenv(env_file, override=True)

# prefer a direct (unpooled) connection when the host provides one (e.g. Neon)
DATABASE_URL = os.environ.get("DATABASE_URL_UNPOOLED") or os.environ.get("DATABASE_URL")
if not DATABASE_URL:
    sys.exit("DATABASE_URL is not set. Copy .env.example to .env and fill in your password.")


def ensure_database():
    try:                                        # already exists (always true on hosted Postgres)
        psycopg.connect(DATABASE_URL).close()
        return
    except psycopg.OperationalError:
        pass
    params = conninfo_to_dict(DATABASE_URL)
    dbname = params.get("dbname", "hostel_db")
    admin_dsn = make_conninfo(DATABASE_URL, dbname="postgres")
    with psycopg.connect(admin_dsn, autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)).fetchone()
        if not exists:
            conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(dbname)))
            print(f"Created database {dbname}")


def run_file(conn, name):
    path = ROOT / "db" / name
    print(f"Running {name} ...")
    conn.execute(path.read_text(encoding="utf-8"))


def main():
    ensure_database()
    files = ["01_schema.sql", "02_logic.sql"]
    if "--no-seed" not in sys.argv:
        files.append("03_seed.sql")
    with psycopg.connect(DATABASE_URL) as conn:      # one transaction: all or nothing
        for f in files:
            run_file(conn, f)
        conn.commit()
        conn.execute("SET search_path = hostel, public")
        counts = conn.execute("""
            SELECT (SELECT COUNT(*) FROM student), (SELECT COUNT(*) FROM room),
                   (SELECT COUNT(*) FROM allocation WHERE status = 'ACTIVE'),
                   (SELECT COUNT(*) FROM invoice), (SELECT COUNT(*) FROM payment)
        """).fetchone()
    print("Done. students=%s rooms=%s active_allocations=%s invoices=%s payments=%s" % counts)


if __name__ == "__main__":
    main()
