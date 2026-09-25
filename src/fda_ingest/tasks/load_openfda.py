"""
Task: load all openFDA 510(k) records into <prefix>bronze_openfda_510k.

Idempotent: each openFDA export is identified by its export_date. If that
export is already in the table, the task exits without doing anything.

Grain: one row per K-number per export.
"""

from __future__ import annotations

from pathlib import Path

from fda_ingest.openfda import download_file, get_510k_export, iter_records_from_zip, write_jsonl
from fda_ingest.pdf_source import http_session
from fda_ingest.tasks.common import base_parser, ensure_volume, target_from


def main() -> None:
    from pyspark.sql import SparkSession
    from pyspark.sql import functions as F

    args = base_parser("Load openFDA 510(k) metadata").parse_args()
    target = target_from(args)
    spark = SparkSession.builder.getOrCreate()
    table = target.table("bronze_openfda_510k")

    session = http_session()
    export_date, files = get_510k_export(session)
    print(f"openFDA 510(k) export {export_date}: {len(files)} file(s)")

    if spark.catalog.tableExists(table) and spark.table(table).where(F.col("export_date") == export_date).limit(1).count():
        print(f"Export {export_date} already loaded into {table}, nothing to do.")
        return

    ensure_volume(spark, target)
    landing = Path(target.volume_path) / "openfda" / "510k" / export_date
    landing.mkdir(parents=True, exist_ok=True)

    total = 0
    for url in files:
        zip_path = landing / url.rsplit("/", 1)[-1]
        download_file(session, url, zip_path)
        n = write_jsonl(iter_records_from_zip(zip_path), zip_path.with_suffix(".jsonl"))
        print(f"  {zip_path.name}: {n} records")
        total += n

    # Read as text so Spark does not infer a schema; keep the full record as VARIANT.
    df = (
        spark.read.text(str(landing / "*.jsonl"))
        .select(
            F.get_json_object("value", "$.k_number").alias("k_number"),
            F.expr("parse_json(value)").alias("raw"),
            F.lit(export_date).alias("export_date"),
            F.current_timestamp().alias("ingested_at"),
        )
    )
    df.write.mode("append").saveAsTable(table)
    print(f"Appended {total} records to {table}")


if __name__ == "__main__":
    main()