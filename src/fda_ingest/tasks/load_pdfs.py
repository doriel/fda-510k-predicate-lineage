"""
Task: download summary PDFs for a sample of 510(k)s into the Volume and
<prefix>bronze_pdf_files.

Sample: devices in the given product codes whose openFDA record says a
"Summary" (not a "Statement") exists, picked in a stable pseudo-random order
(hash of the K-number) so every era is represented and reruns pick the same set.

Idempotent: K-numbers already attempted are skipped, including failed ones,
which stay recorded with their status (for example http_404) instead of
being retried forever.

Grain: one row per download attempt of a K-number.
"""

from __future__ import annotations

import time
from pathlib import Path

from fda_ingest.pdf_source import download_pdf, http_session, parse_product_codes, sha256_hex
from fda_ingest.tasks.common import base_parser, ensure_volume, target_from

BATCH_SIZE = 25
SLEEP_SECONDS = 0.5  # be polite to accessdata.fda.gov


def main() -> None:
    from pyspark.sql import SparkSession
    from pyspark.sql import functions as F
    from pyspark.sql import types as T

    parser = base_parser("Download 510(k) summary PDFs for a sample")
    parser.add_argument("--product-codes", required=True, help="Comma-separated, e.g. JDI,LPH,LZO")
    parser.add_argument("--max-pdfs", type=int, default=100)
    args = parser.parse_args()

    target = target_from(args)
    spark = SparkSession.builder.getOrCreate()
    source = target.table("bronze_openfda_510k")
    dest = target.table("bronze_pdf_files")
    codes = parse_product_codes(args.product_codes)

    latest = spark.table(source).agg(F.max("export_date")).first()[0]
    candidates = (
        spark.table(source)
        .where(F.col("export_date") == latest)
        .select(
            "k_number",
            F.expr("raw:product_code::string").alias("product_code"),
            F.expr("raw:statement_or_summary::string").alias("statement_or_summary"),
        )
        .where(F.col("product_code").isin(codes) & (F.col("statement_or_summary") == "Summary"))
    )
    if spark.catalog.tableExists(dest):
        candidates = candidates.join(spark.table(dest).select("k_number").distinct(), "k_number", "left_anti")

    todo = [
        r.k_number
        for r in candidates.orderBy(F.xxhash64("k_number")).limit(args.max_pdfs).select("k_number").collect()
    ]
    print(f"{len(todo)} PDFs to download for product codes {codes}")
    if not todo:
        return

    ensure_volume(spark, target)
    pdf_dir = Path(target.volume_path) / "pdfs"
    pdf_dir.mkdir(parents=True, exist_ok=True)

    schema = T.StructType([
        T.StructField("k_number", T.StringType(), False),
        T.StructField("download_status", T.StringType(), False),
        T.StructField("source_url", T.StringType(), True),
        T.StructField("path", T.StringType(), True),
        T.StructField("content", T.BinaryType(), True),
        T.StructField("content_sha256", T.StringType(), True),
        T.StructField("length", T.LongType(), True),
    ])

    session = http_session()
    ok = 0
    for start in range(0, len(todo), BATCH_SIZE):
        rows = []
        for k in todo[start:start + BATCH_SIZE]:
            result = download_pdf(session, k)
            path = None
            if result.status == "ok":
                path = str(pdf_dir / f"{k}.pdf")
                Path(path).write_bytes(result.content)
                ok += 1
            rows.append((
                k,
                result.status,
                result.url,
                path,
                bytearray(result.content) if result.content else None,
                sha256_hex(result.content) if result.content else None,
                len(result.content) if result.content else None,
            ))
            time.sleep(SLEEP_SECONDS)

        (
            spark.createDataFrame(rows, schema)
            .withColumn("ingested_at", F.current_timestamp())
            .write.mode("append").saveAsTable(dest)
        )
        print(f"  batch {start // BATCH_SIZE + 1}: {len(rows)} attempted, {ok} ok so far")

    print(f"Done: {ok}/{len(todo)} PDFs downloaded into {pdf_dir}")


if __name__ == "__main__":
    main()