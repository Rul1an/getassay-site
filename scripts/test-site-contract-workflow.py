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
    assert "continue-on-error:" not in raw, "site contract jobs must not fail open"
    assert not re.search(r"(?m)^\s+if:\s*", raw), (
        "site contract jobs must not be conditionally skipped"
    )
    assert not re.search(r"\|\|\s*(true|:)|;\s*exit\s+0", raw), (
        "site contract failures must not be shell-masked"
    )

    headers = job_body(raw, "headers")
    provenance = job_body(raw, "installer_provenance")
    for name, body in (("headers", headers), ("installer_provenance", provenance)):
        assert re.search(r"(?m)^    timeout-minutes: 5\s*$", body), (
            f"{name} needs a job-level timeout"
        )
        uses = re.findall(r"(?m)^\s+-?\s*uses:\s*([^\s#]+)", body)
        assert uses == [CHECKOUT], (
            f"{name} must use only the reviewed immutable checkout pin"
        )
        assert re.search(r"(?m)^\s+persist-credentials: false\s*$", body), (
            f"{name} checkout credentials must not persist"
        )

    assert "python3 scripts/test-site-contract-workflow.py" in headers, (
        "the existing required headers check must witness workflow wiring"
    )
    assert "python3 scripts/test-installer-live-drift-workflow.py" in headers, (
        "the required site contract must witness the live-drift workflow"
    )
    assert "bash scripts/test-installer-provenance-contract.sh" in provenance
    assert "bash scripts/check-installer-provenance.sh" in provenance

    header_commands = re.findall(r"(?m)^\s+run:\s*(.+?)\s*$", headers)
    assert header_commands == [
        "python3 scripts/test-site-headers-contract.py",
        "python3 scripts/test-site-contract-workflow.py",
        "python3 scripts/test-installer-live-drift-workflow.py",
    ], "headers job commands must stay exact"
    provenance_commands = re.findall(r"(?m)^\s+run:\s*(.+?)\s*$", provenance)
    assert provenance_commands == [
        "bash scripts/test-installer-provenance-contract.sh",
        "bash scripts/check-installer-provenance.sh",
    ], "provenance job commands must stay exact"

    lowered = provenance.lower()
    assert "getassay.dev/install.sh" not in lowered, (
        "PR-time provenance must not claim live deployment drift"
    )
    assert "pages.dev" not in lowered, "PR-time provenance must not fetch deployment aliases"

    print("site contract workflow: pass")


if __name__ == "__main__":
    main()
