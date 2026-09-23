"""
Feasibility check for the FDA 510(k) document AI project.

What it answers:
  1. Can we pull 510(k) records from the openFDA API reliably?
  2. Can we download the matching summary PDFs by script (no browser)?
  3. How "broken" are the PDFs per era (no text layer, garbled OCR, clean)?
  4. Which URL pattern works per era (so bronze ingestion can be built on it)?

Outputs (in --out-dir):
  records.jsonl   raw openFDA records, one per line (future bronze input)
  pdfs/           downloaded PDFs
  manifest.csv    one row per record: download status, URL pattern, PDF profile

Usage:
  pip install requests pypdf
  python fda_510k_check.py --per-era 5
  # optional: export OPENFDA_API_KEY=... (free key, higher daily limit)
"""

import argparse
import csv
import json
import logging
import os
import random
import re
import time
from pathlib import Path

import requests
from pypdf import PdfReader

# pypdf logs noisy font-parsing warnings (fontTools) that don't affect the results.
logging.getLogger("pypdf").setLevel(logging.ERROR)

OPENFDA_URL = "https://api.fda.gov/device/510k.json"
PDF_BASE = "https://www.accessdata.fda.gov/cdrh_docs"
HEADERS = {"User-Agent": "fda-510k-feasibility-check/0.1 (portfolio project)"}

# Eras chosen to cover scanned (old) through born-digital (recent) documents.
ERAS = {
    "1996-2001": ("1996-01-01", "2001-12-31"),
    "2002-2009": ("2002-01-01", "2009-12-31"),
    "2010-2016": ("2010-01-01", "2016-12-31"),
    "2017-2026": ("2017-01-01", "2026-12-31"),
}

WORD_RE = re.compile(r"[A-Za-z]{3,}")
TOKEN_RE = re.compile(r"\S+")


def openfda_get(params: dict, retries: int = 3) -> dict:
    """GET openFDA with simple retry on 429/5xx."""
    api_key = os.getenv("OPENFDA_API_KEY")
    if api_key:
        params = {**params, "api_key": api_key}
    for attempt in range(retries):
        resp = requests.get(OPENFDA_URL, params=params, headers=HEADERS, timeout=30)
        if resp.status_code == 200:
            return resp.json()
        if resp.status_code == 404:  # openFDA returns 404 for "no matches"
            return {"meta": {"results": {"total": 0}}, "results": []}
        if resp.status_code in (429, 500, 502, 503):
            time.sleep(2 ** attempt)
            continue
        resp.raise_for_status()
    raise RuntimeError(f"openFDA failed after {retries} retries: {params}")


def sample_era(start: str, end: str, n: int) -> list[dict]:
    """Random sample of 510(k) records with a Summary document in a date range."""
    # Spaces are encoded as '+' by requests, which is what openFDA expects.
    search = f"decision_date:[{start} TO {end}] AND statement_or_summary:Summary"
    total = openfda_get({"search": search, "limit": 1})["meta"]["results"]["total"]
    if total == 0:
        return []
    page = 100
    # openFDA caps skip at 25000, so sample from a random window within that range.
    skip = random.randint(0, max(0, min(total - page, 25000)))
    results = openfda_get({"search": search, "limit": page, "skip": skip})["results"]
    return random.sample(results, min(n, len(results)))


def candidate_urls(k_number: str) -> list[tuple[str, str]]:
    """
    Build candidate PDF URLs for a K number, most likely first.
    Observed pattern: K083145 -> /pdf8/K083145.pdf, K102839 -> /pdf10/K102839.pdf.
    Pre-2002 folders are NOT confirmed; the script tries several and logs the winner.
    Returns (pattern_label, url) pairs.
    """
    k = k_number.upper()
    yy = int(k[1:3])
    folders = [f"pdf{yy}"] if 2 <= yy <= 60 else ["pdf", f"pdf{yy}", f"pdf{yy:02d}"]
    urls = []
    for folder in folders:
        urls.append((f"{folder}/UPPER", f"{PDF_BASE}/{folder}/{k}.pdf"))
        urls.append((f"{folder}/lower", f"{PDF_BASE}/{folder}/{k.lower()}.pdf"))
    return urls


def download_pdf(k_number: str, dest: Path) -> tuple[str, str, str]:
    """Try candidate URLs. Returns (status, pattern, url)."""
    last_status = "not_found"
    for pattern, url in candidate_urls(k_number):
        try:
            resp = requests.get(url, headers=HEADERS, timeout=60)
        except requests.RequestException as exc:
            last_status = f"error:{type(exc).__name__}"
            continue
        # FDA sometimes returns an HTML error page with 200, so check the magic bytes.
        if resp.status_code == 200 and resp.content[:5] == b"%PDF-":
            dest.write_bytes(resp.content)
            return "ok", pattern, url
        last_status = f"http_{resp.status_code}" if resp.status_code != 200 else "not_pdf"
        time.sleep(0.5)
    return last_status, "", ""


def profile_pdf(path: Path) -> dict:
    """
    Cheap quality profile of a PDF, to estimate how much vision/OCR work is needed.
      no_text   : no text layer, pure scan -> needs vision
      garbled   : text layer exists but looks like bad OCR -> vision likely better
      clean     : usable text layer
    The garble heuristic (share of tokens that look like real words) is rough, treat
    it as a signal to eyeball, not a ground truth.
    """
    try:
        reader = PdfReader(str(path))
        pages = len(reader.pages)
        text = "".join((p.extract_text() or "") for p in reader.pages)
    except Exception as exc:  # corrupted PDFs are a finding too
        return {"pages": 0, "chars_per_page": 0, "word_ratio": 0.0,
                "quality": f"unreadable:{type(exc).__name__}"}

    chars_per_page = len(text.strip()) / max(pages, 1)
    tokens = TOKEN_RE.findall(text)
    word_ratio = (sum(1 for t in tokens if WORD_RE.fullmatch(t.strip(".,;:()"))) /
                  len(tokens)) if tokens else 0.0

    if chars_per_page < 50:
        quality = "no_text"
    elif word_ratio < 0.55:
        quality = "garbled"
    else:
        quality = "clean"
    return {"pages": pages, "chars_per_page": round(chars_per_page),
            "word_ratio": round(word_ratio, 2), "quality": quality}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-era", type=int, default=5, help="records to sample per era")
    parser.add_argument("--out-dir", default="fda_check_out")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    random.seed(args.seed)
    out = Path(args.out_dir)
    (out / "pdfs").mkdir(parents=True, exist_ok=True)

    rows = []
    with open(out / "records.jsonl", "w") as records_file:
        for era, (start, end) in ERAS.items():
            records = sample_era(start, end, args.per_era)
            print(f"[{era}] sampled {len(records)} records")
            for rec in records:
                records_file.write(json.dumps(rec) + "\n")
                k = rec["k_number"]
                dest = out / "pdfs" / f"{k}.pdf"
                status, pattern, url = download_pdf(k, dest)
                prof = profile_pdf(dest) if status == "ok" else {}
                rows.append({
                    "era": era,
                    "k_number": k,
                    "decision_date": rec.get("decision_date"),
                    "applicant": rec.get("applicant"),
                    "device_name": rec.get("device_name"),
                    "product_code": rec.get("product_code"),
                    "download_status": status,
                    "url_pattern": pattern,
                    "url": url,
                    **{key: prof.get(key, "") for key in
                       ("pages", "chars_per_page", "word_ratio", "quality")},
                })
                print(f"  {k}: {status} {pattern} {prof.get('quality', '')}")
                time.sleep(1)  # be polite to accessdata.fda.gov

    with open(out / "manifest.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    # Summary per era: download success rate and quality mix.
    print("\n=== Summary ===")
    for era in ERAS:
        era_rows = [r for r in rows if r["era"] == era]
        ok = [r for r in era_rows if r["download_status"] == "ok"]
        mix = {}
        for r in ok:
            mix[r["quality"]] = mix.get(r["quality"], 0) + 1
        patterns = sorted({r["url_pattern"] for r in ok})
        print(f"{era}: downloaded {len(ok)}/{len(era_rows)} | quality {mix} | patterns {patterns}")
    print(f"\nManifest: {out / 'manifest.csv'}")


if __name__ == "__main__":
    main()