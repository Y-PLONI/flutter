"""Compare the JSON reports produced by paragraph_style_lookup_probe.dart."""

import argparse
import json
from math import isfinite
from pathlib import Path


_DIMENSIONS = ("height", "longestLine", "minIntrinsicWidth", "maxIntrinsicWidth")
_BOX_LISTS = ("selectionBoxes", "placeholderBoxes")
_SCALE_FIELDS = ("groups", "characters", "letterSpacing", "lineCount")


def _is_number(value):
    return type(value) is int or (type(value) is float and isfinite(value))


def _geometry_cases(report, label):
    cases = report.get("geometry")
    if not isinstance(cases, list) or len(cases) != 3:
        raise ValueError(f"{label} report must contain the three geometry cases.")
    for index, case in enumerate(cases):
        name = f"{label} geometry[{index}]"
        if not isinstance(case, dict):
            raise ValueError(f"{name} is not an object.")
        for field in _DIMENSIONS:
            if not _is_number(case.get(field)):
                raise ValueError(f"{name}.{field} must be a finite number.")
        lines = case.get("lines")
        if not isinstance(lines, list) or not lines or any(
            not isinstance(line, list)
            or len(line) != 7
            or type(line[0]) is not bool
            or not all(map(_is_number, line[1:]))
            for line in lines
        ):
            raise ValueError(f"{name}.lines must contain line metrics.")
        ellipsis_case = index == 2
        if case.get("exceededMaxLines") is not ellipsis_case or (
            ellipsis_case and len(lines) != 1
        ):
            raise ValueError(f"{name} does not exercise the expected line limit.")
        for field in _BOX_LISTS:
            boxes = case.get(field)
            if not isinstance(boxes, list) or any(
                not isinstance(box, list)
                or len(box) != 5
                or not all(map(_is_number, box[:4]))
                or box[4] not in ("ltr", "rtl")
                for box in boxes
            ):
                raise ValueError(f"{name}.{field} must contain text boxes.")
            if not boxes and (field == "selectionBoxes" or not ellipsis_case):
                raise ValueError(f"{name}.{field} is empty.")
    return cases


def _scaling_cases(report, label):
    cases = report.get("scaling")
    if not isinstance(cases, list) or len(cases) != 6:
        raise ValueError(f"{label} report must contain the six scaling cases.")
    for index, case in enumerate(cases):
        name = f"{label} scaling[{index}]"
        if not isinstance(case, dict):
            raise ValueError(f"{name} is not an object.")
        for field in ("groups", "characters", "lineCount", "layoutMicros"):
            value = case.get(field)
            if type(value) is not int or value <= 0:
                raise ValueError(f"{name}.{field} must be a positive integer.")
        if not _is_number(case.get("letterSpacing")):
            raise ValueError(f"{name}.letterSpacing must be a finite number.")
    return cases


def compare_reports(baseline, patched):
    if not isinstance(baseline, dict) or not isinstance(patched, dict):
        raise ValueError("Both reports must be JSON objects.")

    baseline_geometry = _geometry_cases(baseline, "Baseline")
    patched_geometry = _geometry_cases(patched, "Patched")
    for index, (before, after) in enumerate(zip(baseline_geometry, patched_geometry)):
        if before.keys() != after.keys():
            raise ValueError(f"geometry[{index}] fields differ.")
        for field in before:
            if before[field] != after[field]:
                raise ValueError(f"geometry[{index}].{field} differs.")

    baseline_scaling = _scaling_cases(baseline, "Baseline")
    patched_scaling = _scaling_cases(patched, "Patched")
    timings = []
    for index, (before, after) in enumerate(zip(baseline_scaling, patched_scaling)):
        for field in _SCALE_FIELDS:
            if before[field] != after[field]:
                raise ValueError(f"scaling[{index}].{field} differs.")
        timings.append({
            **{field: before[field] for field in _SCALE_FIELDS},
            "baselineLayoutMicros": before["layoutMicros"],
            "patchedLayoutMicros": after["layoutMicros"],
        })
    return {"geometryCases": len(baseline_geometry), "scaling": timings}


def main():
    parser = argparse.ArgumentParser(
        description="Check identical paragraph geometry and report both layout timings."
    )
    parser.add_argument("baseline", type=Path, help="Probe report from the baseline engine")
    parser.add_argument("patched", type=Path, help="Probe report from the patched engine")
    args = parser.parse_args()

    try:
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        patched = json.loads(args.patched.read_text(encoding="utf-8"))
        comparison = compare_reports(baseline, patched)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
    print(json.dumps(comparison, indent=2))


if __name__ == "__main__":
    main()
