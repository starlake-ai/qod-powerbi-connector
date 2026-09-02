#!/usr/bin/env python3
"""Phase 2 acceptance test: the Power BI navigator inherits QoD's RBAC.

Connects as two users of the same tenant and pool and issues the EXACT
metadata queries the connector's navigation levels issue (see src/QoD.pq:
GetDatabases, GetSchemas, GetTables, GetTableType, ApplyPrimaryKeys), with
the same session contract the connector uses (tenant/pool gRPC call headers,
Basic credentials). Different table lists for the two principals prove the
connector inherits QoD's RBAC rather than bypassing it.

Runs against a local `qod demo` instance, whose minimal bootstrap manifest
seeds the two principals on tenant `acme`, pool `bi`:

  - alice / demo-alice          role `analyst`: RO on customer, orders,
                                nation, region only
  - acme-admin / demo-acme-admin  role `tenant_admin`: ALL on *.*.*

Usage: python3 rbac_navigation_test.py  (pip install adbc-driver-flightsql)
Exits 0 when every assertion holds, 1 with a report otherwise.
"""

import sys

from adbc_driver_flightsql import dbapi

HOST = "grpc+tls://localhost:31338"
TENANT, POOL = "acme", "bi"
CATALOG, SCHEMA = "acme_tpch", "tpch1"

ANALYST_TABLES = {"customer", "orders", "nation", "region"}
ALL_TABLES = ANALYST_TABLES | {"lineitem", "part", "partsupp", "supplier"}

# The connector's navigation queries, verbatim from src/QoD.pq.
Q_DATABASE = "SELECT current_database() AS Name"
Q_SCHEMAS = (
    "SELECT schema_name AS Name FROM information_schema.schemata "
    f"WHERE catalog_name = '{CATALOG}' AND schema_name <> 'information_schema'"
)
Q_TABLES = (
    "SELECT table_name AS Name, table_type FROM information_schema.tables "
    f"WHERE table_catalog = '{CATALOG}' AND table_schema = '{SCHEMA}'"
)
Q_COLUMNS = (
    "SELECT column_name, data_type, is_nullable FROM information_schema.columns "
    f"WHERE table_catalog = '{CATALOG}' AND table_schema = '{SCHEMA}' "
    "AND table_name = 'customer' ORDER BY ordinal_position"
)
Q_PRIMARY_KEYS = (
    "SELECT kcu.column_name FROM information_schema.table_constraints tc "
    "JOIN information_schema.key_column_usage kcu "
    "ON tc.constraint_name = kcu.constraint_name "
    "AND tc.table_catalog = kcu.table_catalog "
    "AND tc.table_schema = kcu.table_schema "
    "AND tc.table_name = kcu.table_name "
    "WHERE tc.constraint_type = 'PRIMARY KEY' "
    f"AND tc.table_catalog = '{CATALOG}' AND tc.table_schema = '{SCHEMA}' "
    "AND tc.table_name = 'customer' ORDER BY kcu.ordinal_position"
)


def connect(user: str, password: str):
    return dbapi.connect(
        HOST,
        db_kwargs={
            "username": user,
            "password": password,
            "adbc.flight.sql.client_option.tls_skip_verify": "true",
            "adbc.flight.sql.rpc.call_header.tenant": TENANT,
            "adbc.flight.sql.rpc.call_header.pool": POOL,
        },
        autocommit=True,
    )


def rows(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchall()


def navigate(user: str, password: str) -> dict:
    with connect(user, password) as conn:
        out = {
            "database": {r[0] for r in rows(conn, Q_DATABASE)},
            "schemas": {r[0] for r in rows(conn, Q_SCHEMAS)},
            "tables": {r[0] for r in rows(conn, Q_TABLES)},
            "customer_columns": [r[0] for r in rows(conn, Q_COLUMNS)],
        }
        try:
            rows(conn, Q_PRIMARY_KEYS)
            out["pk_denied"] = False
        except Exception:
            out["pk_denied"] = True
        return out


def main() -> int:
    failures = []

    def check(cond, label):
        print(("PASS" if cond else "FAIL"), label)
        if not cond:
            failures.append(label)

    alice = navigate("alice", "demo-alice")
    admin = navigate("acme-admin", "demo-acme-admin")

    check(alice["database"] == {CATALOG}, "alice: top level is the session catalog only")
    check(admin["database"] == {CATALOG}, "acme-admin: top level is the session catalog only")
    check(alice["schemas"] == {SCHEMA}, "alice: schema listing")
    check(alice["tables"] == ANALYST_TABLES, "alice: table list is exactly her granted set")
    check(admin["tables"] == ALL_TABLES, "acme-admin: table list is the full schema")
    check(
        alice["tables"] < admin["tables"],
        "the two navigators differ: restricted list is a strict subset",
    )
    check(
        "lineitem" not in alice["tables"] and "lineitem" in admin["tables"],
        "the ungranted table is absent for alice, present for acme-admin",
    )
    check(
        len(alice["customer_columns"]) == 8
        and alice["customer_columns"] == admin["customer_columns"],
        "column listing of a granted table is identical for both",
    )
    check(alice["pk_denied"], "alice: constraint-table PK query is denied (no-keys fallback)")
    check(
        not admin["pk_denied"],
        "acme-admin: constraint-table PK query is admitted (wildcard ALL covers it)",
    )

    print()
    if failures:
        print(f"{len(failures)} assertion(s) failed")
        return 1
    print("RBAC navigation acceptance: all assertions hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
