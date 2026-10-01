#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache="${1:-.build/models}"
report_dir="${2:-.build/benchmarks}"
if [[ ! -f "$cache/prepared-model-path.txt" ]]; then
  echo 'Prepare the local model first with CopilotDiagnostics prepare-model --cache DIRECTORY.' >&2
  exit 1
fi
model_folder="$(cat "$cache/prepared-model-path.txt")"
mkdir -p "$report_dir"
for fixture in timepoint necrosis numbers-negation; do
  .build/debug/CopilotDiagnostics transcribe --cache "$cache" --folder "$model_folder" \
    --audio ".build/fixtures/$fixture.aiff" --reference "Fixtures/ASR/$fixture.txt" \
    --critical-terms "Fixtures/ASR/$fixture-critical.json" \
    --report "$report_dir/$fixture.json" --realtime
done
.build/debug/CopilotDiagnostics transcribe --cache "$cache" --folder "$model_folder" \
  --audio .build/fixtures/necrosis.aiff --reference Fixtures/ASR/necrosis.txt \
  --critical-terms Fixtures/ASR/necrosis-critical.json \
  --microphone-audio .build/fixtures/chinese.aiff --microphone-reference Fixtures/ASR/chinese.txt \
  --report "$report_dir/dual-english-chinese.json" --realtime
