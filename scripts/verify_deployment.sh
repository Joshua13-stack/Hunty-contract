#!/usr/bin/env bash
# verify_deployment.sh — Post-deployment health checks for Hunty contracts
#
# USAGE:
#   HUNTY_CORE_ID=C...  REWARD_MANAGER_ID=C...  NFT_REWARD_ID=C... \
#   bash scripts/verify_deployment.sh [mainnet|testnet]
#
# Exits 0 only when all checks pass. Non-zero exit means deployment is unsafe.

set -euo pipefail

NETWORK="${1:-testnet}"

# ── Config ────────────────────────────────────────────────────────────────────
case "$NETWORK" in
  mainnet)
    PASSPHRASE="Public Global Stellar Network ; September 2015"
    RPC_URL="${MAINNET_RPC_URL:?Set MAINNET_RPC_URL}"
    ;;
  testnet)
    PASSPHRASE="Test SDF Network ; September 2015"
    RPC_URL="${TESTNET_RPC_URL:-https://soroban-testnet.stellar.org}"
    ;;
  *) echo "Usage: $0 [mainnet|testnet]" >&2; exit 1 ;;
esac

CORE_ID="${HUNTY_CORE_ID:?Set HUNTY_CORE_ID}"
RM_ID="${REWARD_MANAGER_ID:?Set REWARD_MANAGER_ID}"
NFT_ID="${NFT_REWARD_ID:?Set NFT_REWARD_ID}"

# RewardManager exposes CONTRACT_VERSION = 2. HuntyCore and NftReward have no
# `contract_version` entrypoint, so their expectations default to empty and the
# version check is skipped unless explicitly set.
EXPECTED_CORE_VERSION="${EXPECTED_CORE_VERSION:-}"
EXPECTED_RM_VERSION="${EXPECTED_RM_VERSION:-2}"
EXPECTED_NFT_VERSION="${EXPECTED_NFT_VERSION:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo "  [PASS] $label"
    ((PASS++)) || true
  else
    echo "  [FAIL] $label"
    ((FAIL++)) || true
  fi
}

# Build the common invoke argument list, appending --source-account only when set.
invoke_args() {
  INVOKE_ARGS=(
    --id "$1"
    --rpc-url "$RPC_URL"
    --network-passphrase "$PASSPHRASE"
  )
  if [[ -n "${SOURCE_ACCOUNT:-}" ]]; then
    INVOKE_ARGS+=(--source-account "$SOURCE_ACCOUNT")
  fi
  INVOKE_ARGS+=(-- "${@:2}")
}

invoke() {
  invoke_args "$@"
  stellar contract invoke "${INVOKE_ARGS[@]}" 2>/dev/null
}

version_check() {
  local id="$1" expected="$2" label="$3"
  local got
  if [[ -z "$expected" ]]; then
    echo "  [SKIP] $label version check (no expected version configured)"
    return 0
  fi
  got=$(invoke "$id" contract_version 2>/dev/null || echo "")
  if [[ "$got" == *"$expected"* ]]; then
    echo "  [PASS] $label version = $expected"
    ((PASS++)) || true
  else
    echo "  [FAIL] $label version: expected $expected, got '$got'"
    ((FAIL++)) || true
  fi
}

# assert_link <label> <contract-id> <read-method> <expected-address>
# Fails when the read reverts or returns an address that does not match the
# expected linked contract. This catches unlinked / mis-linked deployments.
assert_link() {
  local label="$1" id="$2" method="$3" expected="$4"
  local got
  got=$(invoke "$id" "$method" 2>/dev/null || echo "")
  if [[ -n "$got" && "$got" == *"$expected"* ]]; then
    echo "  [PASS] $label -> $expected"
    ((PASS++)) || true
  else
    echo "  [FAIL] $label: expected '$expected', got '$got'"
    ((FAIL++)) || true
  fi
}

# ── Run checks ────────────────────────────────────────────────────────────────
echo "=== Hunty Post-Deploy Verification ($NETWORK) ==="
echo "HuntyCore      : $CORE_ID"
echo "RewardManager  : $RM_ID"
echo "NftReward      : $NFT_ID"
echo ""

echo "--- Contract Versions ---"
version_check "$CORE_ID" "$EXPECTED_CORE_VERSION" "HuntyCore"
version_check "$RM_ID"   "$EXPECTED_RM_VERSION"   "RewardManager"
version_check "$NFT_ID"  "$EXPECTED_NFT_VERSION"  "NftReward"

echo ""
echo "--- Liveness (get_health_dashboard) ---"
invoke_args "$CORE_ID" get_health_dashboard
check "HuntyCore health"     stellar contract invoke "${INVOKE_ARGS[@]}"
invoke_args "$RM_ID" get_health_dashboard
check "RewardManager health" stellar contract invoke "${INVOKE_ARGS[@]}"

echo ""
echo "--- Cross-Contract Wiring ---"
# RewardManager must reference NftReward; HuntyCore must reference RewardManager.
# We invoke a lightweight read that would revert if the linked address is wrong.
assert_link "HuntyCore->RewardManager link" "$CORE_ID" get_reward_manager_address "$RM_ID"
assert_link "RewardManager->NftReward link" "$RM_ID"   get_nft_reward_address     "$NFT_ID"

# RewardManager must be registered as a minter on NftReward, and HuntyCore must
# be registered as a distributor on RewardManager. Without these the contracts
# are deployed but NFT rewards fail on first use.
assert_link "NftReward->RewardManager minter" "$NFT_ID" get_minter "$RM_ID"
assert_link "RewardManager->HuntyCore distributor" "$RM_ID" get_distributor "$CORE_ID"

echo ""
echo "--- Schema Versions ---"
invoke_args "$CORE_ID" get_schema_version
check "HuntyCore schema"    stellar contract invoke "${INVOKE_ARGS[@]}"
invoke_args "$RM_ID" get_schema_version
check "RewardManager schema" stellar contract invoke "${INVOKE_ARGS[@]}"
invoke_args "$NFT_ID" get_schema_version
check "NftReward schema"    stellar contract invoke "${INVOKE_ARGS[@]}"

echo ""
echo "--- NFT Max Supply ---"
# A max_supply of Some(0) (deployed with "0" instead of null) caps supply at
# zero, so every mint fails with MaxSupplyReached. None (unlimited) or a
# positive cap is fine.
NFT_MAX_SUPPLY="$(invoke "$NFT_ID" get_max_supply || echo "")"
if [[ "$NFT_MAX_SUPPLY" == "0" ]]; then
  echo "  [FAIL] NftReward max_supply is Some(0): all mints will fail (redeploy with null for unlimited)"
  ((FAIL++)) || true
else
  echo "  [PASS] NftReward max_supply is not zero-capped (got: '${NFT_MAX_SUPPLY:-none/unlimited}')"
  ((PASS++)) || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
  echo "DEPLOYMENT VERIFICATION FAILED — do not proceed to production traffic."
  exit 1
fi

echo "All checks passed. Deployment verified."
exit 0
