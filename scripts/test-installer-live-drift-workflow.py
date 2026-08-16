#!/usr/bin/env python3
"""Pin the scheduled/manual live installer drift workflow."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/installer-live-drift.yml"
CHECKOUT = "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"
COMMAND = "bash scripts/check-installer-provenance.sh --verify-live"


def main() -> None:
    raw = WORKFLOW.read_text(encoding="utf-8")

    assert re.search(r"(?m)^  workflow_dispatch:\s*$", raw), (
        "manual recovery dispatch is required"
    )
    assert re.search(r"(?m)^  schedule:\s*$", raw), "bounded schedule is required"
    assert "pull_request:" not in raw and "push:" not in raw, (
        "live deployment proof must not duplicate the PR-time workflow"
    )
    assert re.search(r"(?m)^permissions:\s*\n  contents: read\s*$", raw), (
        "workflow permissions must stay read-only"
    )
    assert re.search(r"(?m)^  live_drift:\s*$", raw), "live_drift job is required"
    assert re.search(r"(?m)^    timeout-minutes: 5\s*$", raw), (
        "live_drift needs a job-level timeout"
    )
    assert "continue-on-error:" not in raw, "live drift must not fail open"
    assert not re.search(r"(?m)^\s+if:\s*", raw), "live drift must not be conditionally skipped"
    assert not re.search(r"\|\|\s*(true|:)|;\s*exit\s+0", raw), (
        "live drift failures must not be shell-masked"
    )

    uses = re.findall(r"(?m)^\s+-?\s*uses:\s*([^\s#]+)", raw)
    assert uses, "workflow must check out the reviewed repository"
    assert all(re.search(r"@[0-9a-f]{40}$", item) for item in uses), (
        "every action must be pinned to an immutable commit"
    )
    assert uses == [CHECKOUT], "only the reviewed checkout action belongs here"
    assert re.search(r"(?m)^\s+persist-credentials: false\s*$", raw), (
        "checkout credentials must not persist"
    )

    commands = re.findall(r"(?m)^\s+run:\s*(.+?)\s*$", raw)
    assert commands == [COMMAND], "live workflow must run the one reviewed command"
    assert "pages.dev" not in raw.lower(), "preview aliases are not production proof"

    print("installer live drift workflow: pass")


if __name__ == "__main__":
    main()
