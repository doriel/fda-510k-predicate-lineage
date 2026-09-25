"""
openFDA bulk download for 510(k) metadata.

We load ALL 510(k) records (not only the sample), because predicates cited by a
sampled device can come from any product code. Resolving a predicate needs its
openFDA record even if we never download its PDF.

The bulk files are discovered through https://api.fda.gov/download.json, so the
code does not hardcode file names that change with each export.
"""

from __future__ import annotations

import json
import zipfile
from collections.abc import Iterator
from pathlib import Path

import ijson
import requests

DOWNLOAD_INDEX_URL = "https://api.fda.gov/download.json"


def get_510k_export(session: requests.Session) -> tuple[str, list[str]]:
    """Return (export_date, list of partition file URLs) for device/510k."""
    resp = session.get(DOWNLOAD_INDEX_URL, timeout=60)
    resp.raise_for_status()
    node = resp.json()["results"]["device"]["510k"]
    return node["export_date"], [p["file"] for p in node["partitions"]]


def download_file(session: requests.Session, url: str, dest: Path, chunk_size: int = 1 << 20) -> None:
    """Stream a file to disk, so large exports never sit fully in memory."""
    with session.get(url, stream=True, timeout=300) as resp:
        resp.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in resp.iter_content(chunk_size):
                f.write(chunk)


def iter_records_from_zip(zip_path: Path) -> Iterator[dict]:
    """
    Stream records out of an openFDA zip. Each file inside is one JSON object
    {"meta": ..., "results": [...]}; ijson reads the results array item by item.
    """
    with zipfile.ZipFile(zip_path) as zf:
        for name in zf.namelist():
            if not name.endswith(".json"):
                continue
            with zf.open(name) as f:
                yield from ijson.items(f, "results.item", use_float=True)


def write_jsonl(records: Iterator[dict], dest: Path) -> int:
    """Write records as JSON lines (one record per line). Returns the count."""
    n = 0
    with open(dest, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False))
            f.write("\n")
            n += 1
    return n