#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RESEARCH_COPILOT_APP_OUTPUT="$PWD/build/ResearchCopilotReview.app" bash Scripts/build-app.sh debug
python3 Scripts/create-ui-review.py
codesign --force --sign - build/ResearchCopilotReview.app
echo "Built: $PWD/build/ResearchCopilotReview.app"
