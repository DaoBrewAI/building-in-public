#!/usr/bin/env python3
"""
Validation test suite for bazi-reader.

Runs compute_bazi.py against a set of historically verified charts and
flags any mismatch. Run this before shipping.

Usage:
    python tests/validate.py

Exit code 0 = all pass, 1 = any fail.
"""

import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "scripts" / "compute_bazi.py"

# Historical/known charts.
# Sources: each has a note on where the "expected" value comes from.
# When expected values disagree across sources, we prefer Sect 1 (classical).
TESTS = [
    {
        "name": "PRC Founding (well-documented)",
        "input": {"year": 1949, "month": 10, "day": 1, "hour": 15, "minute": 0},
        "expected": {"year": "己丑", "month": "癸酉", "day": "甲子"},
        "source": "Widely cited historical chart",
    },
    {
        "name": "Sun Yat-sen birth",
        "input": {"year": 1866, "month": 11, "day": 12, "hour": 6, "minute": 0},
        "expected": {"year": "丙寅", "month": "己亥", "day": "辛卯"},
        "source": "Public biographical records",
    },
    {
        "name": "Mao Zedong birth (noon, timezone approx)",
        "input": {"year": 1893, "month": 12, "day": 26, "hour": 12, "minute": 0},
        "expected": {"year": "癸巳", "month": "甲子", "day": "丁酉"},
        "source": "Biographical records",
    },
    {
        "name": "Neo — Sep 20, 1994, 23:23 (晚子时, Sect 1 classical)",
        "input": {"year": 1994, "month": 9, "day": 20, "hour": 23, "minute": 23},
        "expected": {"year": "甲戌", "month": "癸酉", "day": "庚戌", "hour_pillar": "丙子"},
        "source": "User-verified",
    },
    # Boundary / edge case tests
    {
        "name": "Solar term boundary — just before 立春 2000",
        # 立春 2000 was Feb 4 at 20:40 UTC+8 approximately
        "input": {"year": 2000, "month": 2, "day": 4, "hour": 12, "minute": 0},
        "expected": {"year": "己卯"},  # Still 己卯年 (1999 lunar year) before 立春
        "source": "节气 boundary test — day OF 立春 but BEFORE the exact time",
        "note": "If this fails, the library isn't handling 立春 precision correctly",
    },
    {
        "name": "Solar term boundary — just after 立春 2000",
        "input": {"year": 2000, "month": 2, "day": 5, "hour": 12, "minute": 0},
        "expected": {"year": "庚辰"},  # New year已switched
        "source": "节气 boundary test — day after 立春",
    },
    {
        "name": "Sect 1 convention — 23:00+ rolls day forward (classical)",
        "input": {"year": 1990, "month": 6, "day": 15, "hour": 23, "minute": 30},
        # Under Sect 1, 23:30 on Jun 15 should use Jun 16's day pillar
        "expected": {"day": "壬子"},  # Jun 16's day pillar
        "source": "Sect convention test — classical 23:00 day-rollover",
        "note": "Sect 1: 23:30 on Jun 15 uses Jun 16's day pillar (壬子)",
    },
]


def run_compute(test_input, sect=1):
    """Run compute_bazi.py and return parsed JSON."""
    cmd = [
        "python3", str(SCRIPT),
        "--year", str(test_input["year"]),
        "--month", str(test_input["month"]),
        "--day", str(test_input["day"]),
        "--hour", str(test_input["hour"]),
        "--minute", str(test_input.get("minute", 0)),
        "--sect", str(sect),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr
    return json.loads(result.stdout), None


def test_chart(test):
    """Run one test case and return (pass/fail, message)."""
    chart, err = run_compute(test["input"])
    if err:
        return False, f"Script error: {err}"

    expected = test.get("expected", {})
    actual = {
        "year": chart["pillars"]["year"]["full"],
        "month": chart["pillars"]["month"]["full"],
        "day": chart["pillars"]["day"]["full"],
        "hour_pillar": chart["pillars"]["hour"]["full"],
    }

    mismatches = []
    for key, exp_val in expected.items():
        if key in actual and actual[key] != exp_val:
            mismatches.append(f"{key}: expected {exp_val}, got {actual[key]}")

    if mismatches:
        return False, "; ".join(mismatches)

    return True, "OK"


def main():
    print(f"Running {len(TESTS)} validation tests against {SCRIPT}\n")
    results = []
    for test in TESTS:
        ok, msg = test_chart(test)
        results.append((test["name"], ok, msg))
        status = "✓" if ok else "✗"
        print(f"  {status}  {test['name']}")
        if not ok:
            print(f"      → {msg}")
            if "note" in test:
                print(f"      note: {test['note']}")

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print(f"\n{passed}/{total} passed")

    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
