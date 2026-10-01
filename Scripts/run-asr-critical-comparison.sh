#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache="${1:-.build/models}"
report_dir="${2:-.build/benchmarks-critical}"
profile_selection="${3:-all}"
case "$profile_selection" in
  all) profiles=(baseline balanced-hints) ;;
  baseline|balanced-hints) profiles=("$profile_selection") ;;
  *) echo 'Profile must be all, baseline, or balanced-hints.' >&2; exit 2 ;;
esac
model_folder="$(cat "$cache/prepared-model-path.txt")"
for fixture in timepoint necrosis numbers-negation reversible-control irreversible-control necrosis-samantha chinese; do
  if ! afinfo ".build/fixtures/$fixture.aiff" | awk '/estimated duration:/ { if ($3 > 0) valid = 1 } END { exit !valid }'; then
    echo "Missing or empty fixture: $fixture. Generate fixtures first." >&2
    exit 1
  fi
done
for profile in "${profiles[@]}"; do
  mkdir -p "$report_dir/$profile"
  hints=(--decode-trace)
  if [[ "$profile" == balanced-hints ]]; then hints+=(--hint-file Fixtures/ASR/balanced-medical-hints.txt); fi
  for fixture in timepoint necrosis numbers-negation reversible-control irreversible-control necrosis-samantha; do
    reference="$fixture"
    if [[ "$fixture" == necrosis-samantha ]]; then reference=necrosis; fi
    .build/debug/CopilotDiagnostics transcribe --cache "$cache" --folder "$model_folder" \
      --audio ".build/fixtures/$fixture.aiff" --reference "Fixtures/ASR/$reference.txt" \
      --critical-terms "Fixtures/ASR/$reference-critical.json" --realtime \
      --report "$report_dir/$profile/$fixture.json" "${hints[@]}"
  done
  .build/debug/CopilotDiagnostics transcribe --cache "$cache" --folder "$model_folder" \
    --audio .build/fixtures/necrosis.aiff --reference Fixtures/ASR/necrosis.txt \
    --critical-terms Fixtures/ASR/necrosis-critical.json \
    --microphone-audio .build/fixtures/chinese.aiff --microphone-reference Fixtures/ASR/chinese.txt \
    --realtime --report "$report_dir/$profile/dual-english-chinese.json" "${hints[@]}"
done
