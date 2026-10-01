#!/usr/bin/env python3
"""Summarize paired diagnostic runs without claiming semantic or meeting acceptance."""
import argparse
import hashlib
import json
from pathlib import Path

CASES = ("timepoint", "necrosis", "numbers-negation", "reversible-control",
         "irreversible-control", "necrosis-samantha", "dual-english-chinese")
PROFILES = ("baseline", "balanced-hints")


def summarize(root):
    reports = {}
    digests = {}
    for profile in PROFILES:
        reports[profile] = {}
        for case in CASES:
            path = root / profile / (case + ".json")
            data = path.read_bytes()
            report = json.loads(data)
            metrics = report["remoteMetrics"]
            if not metrics.get("checkedCriticalTerms") or not report.get("fixtureSHA256"):
                raise ValueError("Unchecked critical terms or missing fixture identity: " + str(path))
            if not report["realtimeInput"]:
                raise ValueError("Expected real-time input: " + str(path))
            uses_hints = bool(report.get("glossaryConditioning"))
            if uses_hints != (profile == "balanced-hints"):
                raise ValueError("Mismatched hint profile: " + str(path))
            reports[profile][case] = report
            digests[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()

    rows = []
    totals = {profile: {"referenceWords": 0, "wordErrors": 0, "checkedCriticalPhrases": 0,
                        "missingCriticalPhrases": 0, "gaps": 0} for profile in PROFILES}
    for case in CASES:
        first, second = (reports[profile][case] for profile in PROFILES)
        for key in ("audio", "reference", "critical-terms", "microphone-audio", "microphone-reference"):
            if first["fixtureSHA256"].get(key) != second["fixtureSHA256"].get(key):
                raise ValueError("Unpaired fixture " + key + ": " + case)
        if first["preparedResources"] != second["preparedResources"]:
            raise ValueError("Unpaired model resources: " + case)
        if first["remoteMetrics"]["checkedCriticalTerms"] != second["remoteMetrics"]["checkedCriticalTerms"]:
            raise ValueError("Unpaired critical labels: " + case)
        row = {"case": case}
        for profile in PROFILES:
            report = reports[profile][case]
            metrics = report["remoteMetrics"]
            row[profile] = {
                "wordErrorRate": metrics["wordErrorRate"],
                "criticalPhrases": len(metrics["checkedCriticalTerms"]),
                "missingCriticalPhrases": metrics["missingCriticalTerms"],
                "text": " ".join(s["text"] for s in report["finalSegments"] if s["track"] == "remote"),
                "firstPartialSeconds": report.get("firstPartialSeconds"),
                "finalDelays": report["finalDelays"],
                "peakRSSMiB": report["processPeakResidentBytes"] / 1048576,
                "gaps": report["gaps"],
                "microphoneCER": report.get("microphoneMetrics", {}).get("characterErrorRate"),
                "promptTokenCounts": sorted(set(t["promptTokenCount"] for t in report["decodeTraces"])),
            }
            if case != "dual-english-chinese":
                total = totals[profile]
                total["referenceWords"] += metrics["referenceWords"]
                total["wordErrors"] += metrics["wordErrors"]
                total["checkedCriticalPhrases"] += len(metrics["checkedCriticalTerms"])
                total["missingCriticalPhrases"] += len(metrics["missingCriticalTerms"])
                total["gaps"] += len(report["gaps"])
        rows.append(row)
    for total in totals.values():
        total["wordErrorRate"] = total["wordErrors"] / total["referenceWords"]
        total["literalPhrasePreservationRate"] = 1 - total["missingCriticalPhrases"] / total["checkedCriticalPhrases"]
    return {"scope": "Synthetic development comparison; literal phrase checks, not semantic or meeting acceptance",
            "singleTrackTotals": totals, "cases": rows, "reportSHA256": digests,
            "note": "Totals exclude duplicate English in the dual-track case. Voices and texts are not independent human holdout data. WER is literal; number spellings and units are not normalized."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = summarize(args.directory)
    output = args.directory / "comparison.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("case | baseline WER / missing phrases | hints WER / missing phrases")
    for row in result["cases"]:
        values = []
        for profile in PROFILES:
            value = row[profile]
            values.append(f"{value['wordErrorRate']:.2%} / {value['missingCriticalPhrases']}")
        print(row["case"] + " | " + " | ".join(values))
    print("Report:", output)


if __name__ == "__main__":
    main()
