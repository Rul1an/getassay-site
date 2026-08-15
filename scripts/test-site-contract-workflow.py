#!/usr/bin/env python3
"""Pin the PR-time installer provenance workflow contract."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/site-contract.yml"
CHECKOUT = "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"


def job_body(raw: str, job: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(job)}:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)", raw
    )
    assert match, f"missing workflow job: {job}"
    return match.group("body")


def main() -> None:
    raw = WORKFLOW.read_text(encoding="utf-8")

    assert re.search(r"(?m)^  pull_request:\s*$", raw), "PR trigger is required"
    assert re.search(r"(?m)^  push:\s*$", raw), "main push trigger is required"
    assert "schedule:" not in raw, "live/scheduled drift is outside this PR-time gate"
    assert "|| true" not in raw, "provenance failures must not be masked"

    headers = job_body(raw, "headers")
    provenance = job_body(raw, "installer_provenance")
    for name, body in (("headers", headers), ("installer_provenance", provenance)):
        assert CHECKOUT in body, f"{name} must use the reviewed immutable checkout pin"
        assert "timeout-minutes: 5" in body, f"{name} needs a bounded timeout"

    assert "python3 scripts/test-site-contract-workflow.py" in headers, (
        "the existing required headers check must witness workflow wiring"
    )
    assert "bash scripts/test-installer-provenance-contract.sh" in provenance
    assert "bash scripts/check-installer-provenance.sh" in provenance

    lowered = provenance.lower()
    assert "getassay.dev/install.sh" not in lowered, (
        "PR-time provenance must not claim live deployment drift"
    )
    assert "pages.dev" not in lowered, "PR-time provenance must not fetch deployment aliases"

    print("site contract workflow: pass")


if __name__ == "__main__":
    main()
