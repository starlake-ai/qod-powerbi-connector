#!/usr/bin/env python3
"""Phase 3 baseline: QoD's type surface as the connector consumes it.

The connector types columns from information_schema.columns `data_type` strings
(src/QoD.pq GetColumnType -> SqlGenerator.pqm TypeFacets) and receives values as
Arrow. This test pins both halves of that contract against a live `qod demo`:

  1. every type a DuckLake tenant-db supports produces the expected
     (data_type string, Arrow wire type) pair through the FlightSQL ADBC driver;
  2. the types DuckLake rejects (BIT, VARINT, fixed INTEGER[N] arrays) stay
     rejected, so the connector never sees them.

The `expected_m` column documents the M type each data_type resolves to via
TypeFacets; the M-side evaluation itself needs the Power Query SDK's PQTest
(.pqout baseline, pending SDK install on a Windows host).

Runs as the demo superuser because it creates/drops the fixture table
acme_tpch.tpch1.qod_all_types. Exits 0 when every assertion holds.
"""

import sys

from adbc_driver_flightsql import dbapi

HOST = "grpc+tls://localhost:31338"

# (column, DuckDB DDL type, literal, expected data_type, expected Arrow, M type via TypeFacets)
SUPPORTED = [
    ("c_boolean", "BOOLEAN", "true", "BOOLEAN", "bool", "Logical.Type"),
    ("c_tinyint", "TINYINT", "-8", "TINYINT", "int8", "Int8.Type"),
    ("c_smallint", "SMALLINT", "-16", "SMALLINT", "int16", "Int16.Type"),
    ("c_integer", "INTEGER", "-32", "INTEGER", "int32", "Int32.Type"),
    ("c_bigint", "BIGINT", "-64", "BIGINT", "int64", "Int64.Type"),
    ("c_hugeint", "HUGEINT", "170141183460469231731687303715884105727", "HUGEINT", "decimal128(38, 0)", "Decimal.Type"),
    ("c_utinyint", "UTINYINT", "8", "UTINYINT", "uint8", "Int16.Type"),
    ("c_usmallint", "USMALLINT", "16", "USMALLINT", "uint16", "Int32.Type"),
    ("c_uinteger", "UINTEGER", "32", "UINTEGER", "uint32", "Int64.Type"),
    ("c_ubigint", "UBIGINT", "64", "UBIGINT", "uint64", "Decimal.Type"),
    ("c_uhugeint", "UHUGEINT", "340282366920938463463374607431768211455", "UHUGEINT", "decimal128(38, 0)", "Decimal.Type"),
    ("c_float", "FLOAT", "1.5", "FLOAT", "float", "Single.Type"),
    ("c_real", "REAL", "2.5", "FLOAT", "float", "Single.Type"),
    ("c_double", "DOUBLE", "3.5", "DOUBLE", "double", "Double.Type"),
    ("c_decimal", "DECIMAL(15,2)", "12345.67", "DECIMAL(15,2)", "decimal128(15, 2)", "Decimal.Type"),
    ("c_varchar", "VARCHAR", "'hello'", "VARCHAR", "string", "Text.Type"),
    ("c_blob", "BLOB", "'\\xDE\\xAD'::BLOB", "BLOB", "binary", "Binary.Type"),
    ("c_date", "DATE", "DATE '2026-09-02'", "DATE", "date32[day]", "Date.Type"),
    ("c_time", "TIME", "TIME '12:34:56'", "TIME", "time64[us]", "Time.Type"),
    ("c_timestamp", "TIMESTAMP", "TIMESTAMP '2026-09-02 12:34:56'", "TIMESTAMP", "timestamp[us]", "DateTime.Type"),
    ("c_timestamptz", "TIMESTAMP WITH TIME ZONE", "TIMESTAMPTZ '2026-09-02 12:34:56+02'", "TIMESTAMP WITH TIME ZONE", "timestamp[us, tz=*]", "DateTimeZone.Type"),
    ("c_ts_s", "TIMESTAMP_S", "TIMESTAMP '2026-09-02 12:34:56'", "TIMESTAMP_S", "timestamp[s]", "DateTime.Type"),
    ("c_ts_ms", "TIMESTAMP_MS", "TIMESTAMP '2026-09-02 12:34:56'", "TIMESTAMP_MS", "timestamp[ms]", "DateTime.Type"),
    ("c_ts_ns", "TIMESTAMP_NS", "TIMESTAMP '2026-09-02 12:34:56'", "TIMESTAMP_NS", "timestamp[ns]", "DateTime.Type"),
    ("c_interval", "INTERVAL", "INTERVAL 3 DAY", "INTERVAL", "month_day_nano_interval", "Text.Type"),
    ("c_uuid", "UUID", "'550e8400-e29b-41d4-a716-446655440000'::UUID", "UUID", "string", "Text.Type"),
    ("c_json", "JSON", "'{\"a\":1}'::JSON", "JSON", "string", "Text.Type"),
    ("c_list", "INTEGER[]", "[1,2,3]", "INTEGER[]", "list<l: int32>", "type any (ARRAY facet)"),
    ("c_struct", "STRUCT(a INTEGER, b VARCHAR)", "{'a': 1, 'b': 'x'}", "STRUCT(a INTEGER, b VARCHAR)", "struct<a: int32, b: string>", "type any (STRUCT facet)"),
    ("c_map", "MAP(VARCHAR, INTEGER)", "MAP {'k': 1}", "MAP(VARCHAR, INTEGER)", "map<string, int32>", "Text.Type"),
]

# DuckLake refuses these; the connector never encounters them in a tenant-db.
UNSUPPORTED = ["INTEGER[3]", "BIT", "VARINT"]

TABLE = "acme_tpch.tpch1.qod_all_types"


def connect():
    return dbapi.connect(
        HOST,
        db_kwargs={
            "username": "admin",
            "password": "admin",
            "adbc.flight.sql.client_option.tls_skip_verify": "true",
            "adbc.flight.sql.rpc.call_header.tenant": "acme",
            "adbc.flight.sql.rpc.call_header.pool": "bi",
            "adbc.flight.sql.rpc.call_header.superuser": "true",
        },
        autocommit=True,
    )


def main() -> int:
    failures = []

    def check(cond, label):
        print(("PASS" if cond else "FAIL"), label)
        if not cond:
            failures.append(label)

    conn = connect()

    def exec_(sql):
        with conn.cursor() as cur:
            cur.execute(sql)
            try:
                return cur.fetchall()
            except Exception:
                return None

    exec_(f"DROP TABLE IF EXISTS {TABLE}")
    exec_(f"CREATE TABLE {TABLE} (" + ", ".join(f"{n} {t}" for n, t, *_ in SUPPORTED) + ")")
    exec_(f"INSERT INTO {TABLE} VALUES (" + ", ".join(lit for _, _, lit, *_ in SUPPORTED) + ")")

    info = dict(
        exec_(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_catalog='acme_tpch' AND table_schema='tpch1' "
            "AND table_name='qod_all_types' ORDER BY ordinal_position"
        )
    )
    with conn.cursor() as cur:
        cur.execute(f"SELECT * FROM {TABLE}")
        table = cur.fetch_arrow_table()
    arrow = {f.name: str(f.type) for f in table.schema}

    check(table.num_rows == 1, "fixture row loads through the driver")
    for name, _, _, want_dt, want_arrow, _ in SUPPORTED:
        got_dt, got_arrow = info.get(name), arrow.get(name)
        dt_ok = got_dt == want_dt
        arrow_ok = (
            got_arrow is not None and got_arrow.startswith(want_arrow[: want_arrow.index("*")])
            if "*" in want_arrow
            else got_arrow == want_arrow
        )
        check(dt_ok and arrow_ok, f"{name}: {got_dt} / {got_arrow}")

    for t in UNSUPPORTED:
        rejected = False
        try:
            exec_("DROP TABLE IF EXISTS acme_tpch.tpch1.qod_type_probe")
            exec_(f"CREATE TABLE acme_tpch.tpch1.qod_type_probe (x {t})")
            got = exec_(
                "SELECT count(*) FROM information_schema.columns "
                "WHERE table_catalog='acme_tpch' AND table_schema='tpch1' "
                "AND table_name='qod_type_probe'"
            )
            rejected = not got or got[0][0] == 0
        except Exception:
            rejected = True
        check(rejected, f"{t}: rejected by the DuckLake tenant-db")
    exec_("DROP TABLE IF EXISTS acme_tpch.tpch1.qod_type_probe")

    conn.close()
    print()
    if failures:
        print(f"{len(failures)} assertion(s) failed")
        return 1
    print(f"Type baseline: all {1 + len(SUPPORTED) + len(UNSUPPORTED)} assertions hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
