#!/usr/bin/env bash
# Deploy the project to an org and run its tests with coverage.
# Usage: scripts/validate.sh <org alias or username>
set -euo pipefail
ORG="${1:?usage: scripts/validate.sh <org alias>}"
cd "$(dirname "$0")/.."

sf project deploy start --target-org "$ORG" --wait 20
sf apex run test --target-org "$ORG" --test-level RunLocalTests --code-coverage --result-format human --wait 20
