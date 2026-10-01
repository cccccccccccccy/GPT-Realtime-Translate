#!/usr/bin/env python3
"""Compare seven matched, unprompted ASR development runs across two models."""
import argparse
import hashlib
import json
from pathlib import Path

CASES = ("timepoint", "necrosis", "numbers-negation", "reversible-control",
         "irreversible-control", "necrosis-samantha", "dual-english-chinese")


def load(directory):
    reports, hashes = {}, {}
    for case in CASES:
        path = directory / (case + ".json")
        raw = path.read_bytes()
        report = json.loads(raw)
        if not report["realtimeInput"] or report["glossaryConditioning"]:
            raise ValueError("Expected real-time input without ASR hints: " + str(path))
        if not report.get("fixtureSHA256") or not report["remoteMetrics"].get("checkedCriticalTerms"):
            raise ValueError("Missing fixture identity or critical labels: " + str(path))
        reports[case] = report
        hashes[case + ".json"] = hashlib.sha256(raw).hexdigest()
    first = reports[CASES[0]]
    for report in reports.values():
        for field in ("preparedResources", "pipelineVersion"):
            if report[field] != first[field]:
                raise ValueError("Mixed " + field + " within " + str(directory))
    return reports, hashes


def compare(baseline, candidate):
    groups, hashes = {}, {}
    for label, directory in (("baseline", baseline), ("candidate", candidate)):
        groups[label], hashes[label] = load(directory)
    rows, totals = [], {label: dict(referenceWords=0, wordErrors=0,
                                    criticalPhrases=0, missingCriticalPhrases=0, gaps=0)
                       for label in groups}
    for case in CASES:
        first, second = (groups[label][case] for label in groups)
        for field in ("fixtureSHA256", "pipelineVersion", "audioDuration", "tracks"):
            if first[field] != second[field]:
                raise ValueError("Unmatched " + field + ": " + case)
        for field in ("checkedCriticalTerms", "referenceWords"):
            if first["remoteMetrics"][field] != second["remoteMetrics"][field]:
                raise ValueError("Unmatched reference " + field + ": " + case)
        row = {"case": case, "fixtureSHA256": first["fixtureSHA256"]}
        for label, reports in groups.items():
            report = reports[case]
            metrics = report["remoteMetrics"]
            row[label] = {"remoteMetrics": metrics, "microphoneMetrics": report.get("microphoneMetrics"),
                          "texts": {track: " ".join(s["text"] for s in report["finalSegments"] if s["track"] == track)
                                    for track in report["tracks"]},
                          "preparationSeconds": report["preparationSeconds"],
                          "firstPartialSeconds": report.get("firstPartialSeconds"),
                          "finalDelays": report["finalDelays"],
                          "peakRSSMiB": report["processPeakResidentBytes"] / 1048576,
                          "gaps": report["gaps"]}
            if case != "dual-english-chinese":
                total = totals[label]
                total["referenceWords"] += metrics["referenceWords"]
                total["wordErrors"] += metrics["wordErrors"]
                total["criticalPhrases"] += len(metrics["checkedCriticalTerms"])
                total["missingCriticalPhrases"] += len(metrics["missingCriticalTerms"])
                total["gaps"] += len(report["gaps"])
        rows.append(row)
    for total in totals.values():
        total["wordErrorRate"] = total["wordErrors"] / total["referenceWords"]
    return {"scope": "Synthetic development comparison, not human holdout or meeting acceptance",
            "pipelineVersion": groups["baseline"][CASES[0]]["pipelineVersion"],
            "preparedResources": {label: reports[CASES[0]]["preparedResources"] for label, reports in groups.items()},
            "singleTrackTotals": totals, "cases": rows, "reportSHA256": hashes,
            "limitations": ["Totals exclude duplicate English in the dual-track case",
                            "Literal WER and phrase checks do not establish semantic correctness",
                            "Nonconcurrent runs; cache and system load are not controlled",
                            "Final transcript delay is not question-to-answer latency"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = compare(args.baseline, args.candidate)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["singleTrackTotals"], indent=2))
    print("Report:", args.output)


if __name__ == "__main__":
    main()
