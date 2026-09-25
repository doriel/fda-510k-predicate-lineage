import json
import zipfile

from fda_ingest.openfda import iter_records_from_zip, write_jsonl


def make_export_zip(path, records):
    """Build a zip shaped like an openFDA bulk export."""
    payload = {"meta": {"results": {"total": len(records)}}, "results": records}
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("device-510k-0001-of-0001.json", json.dumps(payload))


def test_iter_records_from_zip(tmp_path):
    records = [
        {"k_number": "K123598", "product_code": "JDI", "statement_or_summary": "Summary"},
        {"k_number": "K960395", "product_code": "HNO", "statement_or_summary": "Summary"},
    ]
    zip_path = tmp_path / "export.zip"
    make_export_zip(zip_path, records)

    assert list(iter_records_from_zip(zip_path)) == records


def test_write_jsonl_round_trip(tmp_path):
    records = [{"k_number": "K123598", "decision_date": "2013-06-28"}, {"k_number": "K121819"}]
    dest = tmp_path / "out.jsonl"

    assert write_jsonl(iter(records), dest) == 2
    lines = dest.read_text(encoding="utf-8").splitlines()
    assert [json.loads(line) for line in lines] == records