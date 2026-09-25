import pytest

from fda_ingest.pdf_source import (
    PDF_BASE,
    candidate_urls,
    download_pdf,
    is_pdf,
    normalize_k_number,
    parse_product_codes,
)


# --- URL rule (from the feasibility check) ---------------------------------

@pytest.mark.parametrize(
    "k_number, folder",
    [
        ("K123598", "pdf12"),   # 2012
        ("K022044", "pdf2"),    # 2002, no leading zero in the folder
        ("K240267", "pdf24"),   # 2024
        ("K983861", "pdf"),     # 1998, before the per-year folders
        ("K011616", "pdf"),     # 2001
    ],
)
def test_candidate_urls_folder(k_number, folder):
    urls = candidate_urls(k_number)
    assert urls[0] == f"{PDF_BASE}/{folder}/{k_number}.pdf"
    assert urls[1] == f"{PDF_BASE}/{folder}/{k_number.lower()}.pdf"


def test_normalize_k_number_uppercases():
    assert normalize_k_number(" k123598 ") == "K123598"


@pytest.mark.parametrize("bad", ["K9903690", "K12359", "P123456", ""])
def test_normalize_k_number_rejects_malformed(bad):
    # K9903690 is printed in K123598 with 7 digits: a typo in the source document.
    with pytest.raises(ValueError):
        normalize_k_number(bad)


# --- Validation ------------------------------------------------------------

def test_is_pdf():
    assert is_pdf(b"%PDF-1.4 ...")
    assert not is_pdf(b"<html>error</html>")
    assert not is_pdf(b"")


def test_parse_product_codes():
    assert parse_product_codes("JDI, lph ,LZO") == ["JDI", "LPH", "LZO"]


@pytest.mark.parametrize("bad", ["", "JD", "JDI,12X"])
def test_parse_product_codes_rejects_invalid(bad):
    with pytest.raises(ValueError):
        parse_product_codes(bad)


# --- Download logic with a fake session (no network) -----------------------

class FakeResponse:
    def __init__(self, status_code, content):
        self.status_code = status_code
        self.content = content


class FakeSession:
    def __init__(self, responses):
        self.responses = responses  # url -> FakeResponse
        self.calls = []

    def get(self, url, timeout=None):
        self.calls.append(url)
        return self.responses.get(url, FakeResponse(404, b""))


def test_download_falls_back_to_lowercase_name():
    upper, lower = candidate_urls("K123598")
    session = FakeSession({lower: FakeResponse(200, b"%PDF-1.7 content")})
    result = download_pdf(session, "K123598")
    assert result.status == "ok"
    assert result.url == lower
    assert result.content.startswith(b"%PDF-")
    assert session.calls == [upper, lower]


def test_download_html_with_200_is_not_a_pdf():
    upper, lower = candidate_urls("K123598")
    html = FakeResponse(200, b"<html>Page not found</html>")
    result = download_pdf(FakeSession({upper: html, lower: html}), "K123598")
    assert result.status == "not_pdf"
    assert result.content is None


def test_download_not_found():
    result = download_pdf(FakeSession({}), "K001788")
    assert result.status == "http_404"
    assert result.content is None