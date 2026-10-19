#!/usr/bin/env bash
# Hunty contract health monitor — polls on-chain health dashboards via stellar CLI.
set -euo pipefail

NETWORK="${NETWORK:-testnet}"
CORE_ID="${HUNTY_CORE_ID:-}"
RM_ID="${REWARD_MANAGER_ID:-}"

if [[ -z "$CORE_ID" || -z "$RM_ID" ]]; then
  echo "Set HUNTY_CORE_ID and REWARD_MANAGER_ID" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed" >&2
  exit 1
fi

echo "=== Hunty Contract Monitor ($NETWORK) ==="

core_health=$(stellar contract invoke --id "$CORE_ID" --network "$NETWORK" -- get_health_dashboard 2>/dev/null || echo "unavailable")
rm_health=$(stellar contract invoke --id "$RM_ID" --network "$NETWORK" -- get_health_dashboard 2>/dev/null || echo "unavailable")

echo "HuntyCore health: $core_health"
echo "RewardManager health: $rm_health"

# Alert thresholds (operator-tunable)
FAILURE_RATE_BPS_ALERT="${FAILURE_RATE_BPS_ALERT:-500}"

# Extract failure_rate_bps from a JSON health dashboard. Prints nothing on failure.
extract_failure_rate() {
  local payload="$1"
  echo "$payload" | jq -er '.failure_rate_bps // empty' 2>/dev/null || true
}

check_failure_rate() {
  local name="$1"
  local payload="$2"
  local rate

  rate=$(extract_failure_rate "$payload")
  if [[ -z "$rate" ]]; then
    echo "WARN: could not parse failure_rate_bps for $name"
    return 0
  fi

  if [[ "$rate" -gt "$FAILURE_RATE_BPS_ALERT" ]]; then
    echo "ALERT: $name failure rate ${rate}bps exceeds threshold ${FAILURE_RATE_BPS_ALERT}bps"
    return 1
  fi

  echo "OK: $name failure rate ${rate}bps within threshold"
  return 0
}

breach=0
check_failure_rate "HuntyCore" "$core_health" || breach=1
check_failure_rate "RewardManager" "$rm_health" || breach=1

if [[ "$breach" -ne 0 ]]; then
  exit 2
fi

echo "Monitor check passed"