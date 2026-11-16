"""Fail closed unless both standalone real-input XCTest cases actually passed."""
import json
from pathlib import Path
import sys


def validate(summary):
    if not isinstance(summary, dict):
        raise ValueError("XCTest summary is not an object")
    wanted = {"totalTestCount": 2, "passedTests": 2, "failedTests": 0, "skippedTests": 0}
    for key, value in wanted.items():
        if type(summary.get(key)) is not int or summary[key] != value:
            raise ValueError(f"Expected {key}={value}, received {summary.get(key)!r}")
    if summary.get("result") != "Passed" or summary.get("testFailures", []) != []:
        raise ValueError("XCTest result contains a failure or is not Passed")
    return wanted


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_interaction_result.py xcresult-summary.json")
    try:
        counts = validate(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))
    except (ValueError, OSError) as error:
        raise SystemExit(f"FAILED: {error}")
    print(json.dumps(counts, sort_keys=True))
