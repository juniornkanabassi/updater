#!/usr/bin/env python3
"""Validate recorded measurements without treating missing evidence as zero."""

import argparse
import math
from pathlib import Path
import re
import sys


COMPLEXITY_BUDGETS = {
    "app_data_store_update_batch": 40,
    "update_result_acceptance_overlap": 40,
    "app_list_snapshot_build_and_lookup": 12,
    "app_list_search_refilter": 160,
    "app_list_search_full_rebuild": 360,
    "version_comparison_repeated_parse": 75,
    "release_notes_markup_parse_and_render": 160,
    "release_notes_persistent_cache_read": 45,
    "update_repository_catalog_decode": 550,
    "update_repository_compact_index_decode": 180,
    "update_repository_entry_metadata_and_matching": 280,
    "update_repository_lazy_metadata_and_matching": 15,
    "bundle_collection_path_filtering": 170,
    # Sleeping child tasks measure scheduler overhead, not network latency.
    "update_check_scheduler_fixture": 120,
}
APP_BUDGETS = {
    "cold_launch_to_populated_sidebar_fixture": ("p50_ms", 65),
    "selection_to_detail": ("p95_ms", 8),
    "selection_to_render_memory": ("p95_ms", 16),
    "selection_to_render_disk": ("p95_ms", 50),
    "selection_to_render_cold": ("p95_ms", 100),
}
COMPARISON_LIMITS = {
    "cold_launch_to_populated_sidebar_fixture": ("p50_ms", 1.15),
    "selection_to_detail": ("p95_ms", 1.20),
}
RUNTIME_WARNINGS = (
    "reentrant operation in its NSTableView delegate",
    "Publishing changes from within view updates",
)


def records(path, prefix):
    result = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        # Existing same-hardware originals remain usable after the suite rename.
        if not fields or fields[0] not in (prefix, prefix.replace("APP_", "MIGRATION_")):
            continue
        values = dict(field.split("=", 1) for field in fields[1:] if "=" in field)
        name = values.get("name")
        if not name or name in result:
            raise ValueError(f"{path}: missing or duplicate {prefix} name: {name}")
        result[name] = values
    return result


def measurement(data, name, statistic, *, allow_negative=False):
    try:
        value = float(data[name][statistic])
    except (KeyError, ValueError):
        raise ValueError(f"missing or invalid measurement: {name}.{statistic}") from None
    if not math.isfinite(value) or (value < 0 and not allow_negative):
        raise ValueError(f"invalid measurement: {name}.{statistic}={value}")
    return value


def runtime_warnings(log):
    # read_text raises when the log is absent; absence never establishes a pass.
    return sum(any(warning in line for warning in RUNTIME_WARNINGS)
               for line in log.read_text().splitlines())


def check(mode, report, *, log=None, baseline=None):
    failures = []

    def ceiling(name, observed, maximum):
        passed = observed <= maximum
        print(f"{mode.upper()} GATE {'PASS' if passed else 'FAIL'} "
              f"name={name} observed={observed:.3f} maximum={maximum:.3f}")
        if not passed:
            failures.append(name)

    data = records(report, "BENCHMARK" if mode == "complexity" else "APP_BENCHMARK")
    if mode == "complexity":
        for name, budget in COMPLEXITY_BUDGETS.items():
            ceiling(name, measurement(data, name, "p95_ms"), budget)
        for candidate, control, ratio in (
            ("app_list_search_refilter", "app_list_search_full_rebuild", 0.70),
            ("update_repository_compact_index_decode", "update_repository_catalog_decode", 0.60),
        ):
            previous = measurement(data, control, "p95_ms")
            if previous <= 0:
                raise ValueError(f"comparison baseline must be positive: {control}.p95_ms")
            ceiling(candidate + "_relative", measurement(data, candidate, "p95_ms"),
                    previous * ratio)
    elif mode == "app":
        for name, (statistic, budget) in APP_BUDGETS.items():
            ceiling(name, measurement(data, name, statistic), budget)
        memory = records(report, "APP_MEMORY")
        deltas = [measurement(memory, name, "delta_bytes", allow_negative=True)
                  for name in memory if re.fullmatch(r"repeated_selection(?:_\d+)?", name)]
        if not deltas:
            raise ValueError("missing repeated_selection memory measurement")
        ceiling("repeated_selection_memory", max(deltas), 24 * 1024 * 1024)
    else:
        control = records(baseline, "APP_BENCHMARK")
        for name, (statistic, ratio) in COMPARISON_LIMITS.items():
            previous = measurement(control, name, statistic)
            if previous <= 0:
                raise ValueError(f"comparison baseline must be positive: {name}.{statistic}")
            ceiling(name + "_ratio", measurement(data, name, statistic) / previous, ratio)
    if mode != "complexity":
        ceiling("runtime_warnings", runtime_warnings(log), 0)
    return not failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    commands.add_parser("complexity").add_argument("report", type=Path)
    app = commands.add_parser("app")
    app.add_argument("report", type=Path)
    app.add_argument("log", type=Path)
    comparison = commands.add_parser("compare")
    comparison.add_argument("baseline", type=Path)
    comparison.add_argument("report", type=Path)
    comparison.add_argument("log", type=Path, nargs="?")
    comparison.add_argument("--report-only", action="store_true")
    args = parser.parse_args()
    log = getattr(args, "log", None)
    if args.mode == "compare" and log is None:
        log = args.report.with_suffix(".log")
    try:
        passed = check(args.mode, args.report, log=log, baseline=getattr(args, "baseline", None))
    except (OSError, ValueError) as error:
        print(f"{args.mode.upper()} GATE UNVERIFIED: {error}", file=sys.stderr)
        # Report-only permits unmet targets, but malformed evidence is still an error.
        return 2
    return 0 if passed or getattr(args, "report_only", False) else 1


if __name__ == "__main__":
    sys.exit(main())
