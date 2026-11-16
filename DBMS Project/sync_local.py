"""Mirror the live (Neon) database into your local PostgreSQL in real time,
using PostgreSQL LOGICAL REPLICATION (publisher = Neon, subscriber = local).

Usage:
    python sync_local.py            (re)build the local mirror and start syncing
    python sync_local.py --status   show sync status and row counts on both sides
    python sync_local.py --stop     stop syncing; the local DB becomes a normal, editable DB again

Needs: .env        -> local DATABASE_URL (your PC)
       .env.vercel -> Neon credentials (vercel env pull .env.vercel --environment=production)
       "Logical replication" enabled in the Neon project settings.
"""
import sys
from pathlib import Path

import psycopg
import psycopg.conninfo
from psycopg import sql
from dotenv import dotenv_values

ROOT = Path(__file__).parent
PUB, SUB = "hostel_pub", "hostel_local_sub"

local_env = dotenv_values(ROOT / ".env")
cloud_env = dotenv_values(ROOT / ".env.vercel")
LOCAL_URL = local_env["DATABASE_URL"]
CLOUD_URL = cloud_env.get("DATABASE_URL_UNPOOLED") or cloud_env["DATABASE_URL"]


def connect(url):
    return psycopg.connect(url, autocommit=True, options="-c search_path=hostel,public")


def hostel_tables(conn):
    return [r[0] for r in conn.execute("""
        SELECT table_name FROM information_schema.tables
         WHERE table_schema = 'hostel' AND table_type = 'BASE TABLE' ORDER BY table_name""")]


def counts(conn, tables):
    return {t: conn.execute(sql.SQL("SELECT count(*) FROM hostel.{}").format(sql.Identifier(t))).fetchone()[0]
            for t in tables}


def drop_subscription(local, cloud):
    if local.execute("SELECT 1 FROM pg_subscription WHERE subname = %s", (SUB,)).fetchone():
        local.execute(f"ALTER SUBSCRIPTION {SUB} DISABLE")
        local.execute(f"ALTER SUBSCRIPTION {SUB} SET (slot_name = NONE)")   # don't need Neon to drop the slot
        local.execute(f"DROP SUBSCRIPTION {SUB}")
    # remove the replication slot on Neon so it stops keeping WAL for us
    if cloud.execute("SELECT 1 FROM pg_replication_slots WHERE slot_name = %s", (SUB,)).fetchone():
        cloud.execute("SELECT pg_drop_replication_slot(%s)", (SUB,))


# Local edits would clash with IDs created on the live site and break the sync, so block them.
# The replication worker runs with session_replication_role = replica, so these triggers
# never fire for replicated changes — only for someone editing the local copy by hand.
GUARD_FN = """
CREATE OR REPLACE FUNCTION hostel.local_mirror_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'This local database is a read-only mirror of the live site. Make changes on the website.';
END $$;
"""


def add_guards(local, tables):
    local.execute(GUARD_FN)
    for t in tables:
        events = "INSERT OR DELETE OR TRUNCATE OR UPDATE"
        if t == "app_user":   # allow local logins (they only update last_login)
            events = "INSERT OR DELETE OR TRUNCATE OR UPDATE OF username, password_hash, role, student_id"
        local.execute(sql.SQL("CREATE TRIGGER zz_local_mirror_guard BEFORE " + events +
                              " ON hostel.{} FOR EACH STATEMENT EXECUTE FUNCTION hostel.local_mirror_guard()")
                      .format(sql.Identifier(t)))


def remove_guards(local, tables):
    for t in tables:
        local.execute(sql.SQL("DROP TRIGGER IF EXISTS zz_local_mirror_guard ON hostel.{}").format(sql.Identifier(t)))
    local.execute("DROP FUNCTION IF EXISTS hostel.local_mirror_guard()")


def start():
    with connect(CLOUD_URL) as cloud, connect(LOCAL_URL) as local:
        wal = cloud.execute("SHOW wal_level").fetchone()[0]
        if wal != "logical":
            sys.exit("Neon is not ready: wal_level is '%s'. Enable 'Logical replication' in the Neon "
                     "project settings, wait a minute, then run this again." % wal)

        tables = hostel_tables(cloud)

        # 1. Publisher (Neon): publish every table in the hostel schema
        table_list = sql.SQL(", ").join(sql.Identifier("hostel", t) for t in tables)
        if cloud.execute("SELECT 1 FROM pg_publication WHERE pubname = %s", (PUB,)).fetchone():
            cloud.execute(sql.SQL(f"ALTER PUBLICATION {PUB} SET TABLE ") + table_list)
        else:
            cloud.execute(sql.SQL(f"CREATE PUBLICATION {PUB} FOR TABLE ") + table_list)
        print(f"Publication {PUB} on Neon covers {len(tables)} tables")

        # 2. Subscriber (local): fresh empty schema with the same tables, triggers and views
        drop_subscription(local, cloud)
        for f in ("01_schema.sql", "02_logic.sql"):
            local.execute((ROOT / "db" / f).read_text(encoding="utf-8"))
        add_guards(local, hostel_tables(local))
        print("Local schema rebuilt (empty) and protected against local edits")

        # 3. Subscribe: copies existing rows first, then streams every change as it happens
        info = psycopg.conninfo.conninfo_to_dict(CLOUD_URL)
        conninfo = psycopg.conninfo.make_conninfo(
            host=info["host"], port=info.get("port", 5432), dbname=info["dbname"],
            user=info["user"], password=info["password"], sslmode="require")
        local.execute(sql.SQL(f"CREATE SUBSCRIPTION {SUB} CONNECTION {{}} PUBLICATION {PUB} "
                              "WITH (copy_data = true)").format(sql.Literal(conninfo)))
        print(f"Subscription {SUB} created — initial copy running")

        import time
        for _ in range(60):   # wait for the initial copy of every table to finish
            pending = local.execute("""SELECT count(*) FROM pg_subscription_rel sr
                                        JOIN pg_subscription s ON s.oid = sr.srsubid
                                       WHERE s.subname = %s AND sr.srsubstate <> 'r'""", (SUB,)).fetchone()[0]
            if pending == 0:
                break
            time.sleep(2)
        status()


def status():
    with connect(CLOUD_URL) as cloud, connect(LOCAL_URL) as local:
        sub = local.execute("""SELECT s.subenabled, st.latest_end_time
                                 FROM pg_subscription s
                                 LEFT JOIN pg_stat_subscription st ON st.subid = s.oid AND st.relid IS NULL
                                WHERE s.subname = %s""", (SUB,)).fetchone()
        if not sub:
            print("Sync is OFF (no subscription). Run: python sync_local.py")
            return
        print(f"Sync is {'ON' if sub[0] else 'DISABLED'}; last message from Neon: {sub[1]}")
        tables = hostel_tables(cloud)
        c, l = counts(cloud, tables), counts(local, tables)
        print(f"\n{'table':16} {'live':>6} {'local':>6}")
        for t in tables:
            print(f"{t:16} {c[t]:>6} {l.get(t, '-'):>6}  {'' if c[t] == l.get(t) else '<- catching up'}")


def stop():
    with connect(CLOUD_URL) as cloud, connect(LOCAL_URL) as local:
        drop_subscription(local, cloud)
        remove_guards(local, hostel_tables(local))
        cloud.execute(f"DROP PUBLICATION IF EXISTS {PUB}")
    print("Sync stopped. The local database keeps its data and is editable again.")


if __name__ == "__main__":
    if "--status" in sys.argv:
        status()
    elif "--stop" in sys.argv:
        stop()
    else:
        start()
