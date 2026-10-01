#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/fixtures
say -v Samantha -r 155 -f Fixtures/ASR/timepoint.txt -o .build/fixtures/timepoint.aiff
say -v Daniel -r 165 -f Fixtures/ASR/necrosis.txt -o .build/fixtures/necrosis.aiff
say -v Samantha -r 155 -f Fixtures/ASR/numbers-negation.txt -o .build/fixtures/numbers-negation.aiff
say -v Tingting -r 155 -f Fixtures/ASR/chinese.txt -o .build/fixtures/chinese.aiff
say -v Daniel -r 165 -f Fixtures/ASR/reversible-control.txt -o .build/fixtures/reversible-control.aiff
say -v Samantha -r 155 -f Fixtures/ASR/irreversible-control.txt -o .build/fixtures/irreversible-control.aiff
say -v Samantha -r 155 -f Fixtures/ASR/necrosis.txt -o .build/fixtures/necrosis-samantha.aiff
for fixture in timepoint necrosis numbers-negation chinese reversible-control irreversible-control necrosis-samantha; do
  if ! afinfo ".build/fixtures/$fixture.aiff" | awk '/estimated duration:/ { if ($3 > 0) valid = 1 } END { exit !valid }'; then
    echo "Fixture $fixture contains no audio. Check access to the macOS speech synthesis service." >&2
    exit 1
  fi
done
echo 'Synthetic fixtures generated in .build/fixtures.'
