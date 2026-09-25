"""
Where 510(k) summary PDFs live on accessdata.fda.gov, and how to download them safely.

Pure functions (URL rule, validation) are kept separate from network code so they
can be unit tested without the internet.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

PDF_BASE = "https://www.accessdata.fda.gov/cdrh_docs"
USER_AGENT = "fda-510k-predicate-lineage/0.1 (portfolio project)"
K_NUMBER_RE = re.compile(r"^K\d{6}$")
PRODUCT_CODE_RE = re.compile(r"^[A-Z]{3}$")


def normalize_k_number(value: str) -> str:
    """Uppercase and strip a K-number, and reject anything that is not K + 6 digits."""
    k = value.strip().upper()
    if not K_NUMBER_RE.match(k):
        raise ValueError(f"Not a valid K-number: {value!r}")
    return k


def candidate_urls(k_number: str) -> list[str]:
    """
    Candidate PDF URLs for a K-number, most likely first.

    Rule found in the feasibility check: the folder comes from the K-number's
    two-digit year, not from the decision date. 2002 onward: /pdf{yy}/
    (K022044 -> /pdf2/, K123598 -> /pdf12/). Before 2002: /pdf/.
    Uppercase file names are the norm; lowercase is a fallback.
    """
    k = normalize_k_number(k_number)
    yy = int(k[1:3])
    folder = f"pdf{yy}" if 2 <= yy < 76 else "pdf"
    return [f"{PDF_BASE}/{folder}/{k}.pdf", f"{PDF_BASE}/{folder}/{k.lower()}.pdf"]


def is_pdf(content: bytes) -> bool:
    """FDA sometimes returns an HTML error page with HTTP 200, so check the magic bytes."""
    return content[:5] == b"%PDF-"


def sha256_hex(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def parse_product_codes(value: str) -> list[str]:
    """'JDI, lph' -> ['JDI', 'LPH']. Product codes are three letters."""
    codes = [c.strip().upper() for c in value.split(",") if c.strip()]
    bad = [c for c in codes if not PRODUCT_CODE_RE.match(c)]
    if not codes or bad:
        raise ValueError(f"Invalid product codes: {value!r}")
    return codes


def http_session() -> requests.Session:
    """Session with retries on rate limits and server errors."""
    retry = Retry(
        total=3,
        backoff_factor=2,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET",),
    )
    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


@dataclass(frozen=True)
class DownloadResult:
    k_number: str
    status: str            # "ok", "not_pdf", "http_404", "error:<Type>", ...
    url: str | None        # URL that returned the PDF, or the last one tried
    content: bytes | None  # None unless status == "ok"


def download_pdf(session: requests.Session, k_number: str, timeout: int = 60) -> DownloadResult:
    """Try each candidate URL until one returns a real PDF."""
    status, last_url = "not_found", None
    for url in candidate_urls(k_number):
        last_url = url
        try:
            resp = session.get(url, timeout=timeout)
        except requests.RequestException as exc:
            status = f"error:{type(exc).__name__}"
            continue
        if resp.status_code == 200 and is_pdf(resp.content):
            return DownloadResult(k_number, "ok", url, resp.content)
        status = "not_pdf" if resp.status_code == 200 else f"http_{resp.status_code}"
    return DownloadResult(k_number, status, last_url, None)