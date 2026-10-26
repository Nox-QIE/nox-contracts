#!/usr/bin/env bash
# Mainnet (or testnet) deploy preflight. Needs no key and sends nothing: checks the network, RPCs,
# gas price, the deployer's balance against the simulated cost, the admin/operator split, and runs
# the deploy script as a simulation.
#   DEPLOYER=0x... NOX_ADMIN=0x... NOX_OPERATOR=0x... script/preflight.sh mainnet
set -euo pipefail
NET="${1:-mainnet}"
case "$NET" in
  mainnet) CHAIN=1990; RPCS="https://rpc1mainnet.qie.digital https://rpc2mainnet.qie.digital https://rpc3mainnet.qie.digital https://rpc4mainnet.qie.digital https://rpc5mainnet.qie.digital"; ALIAS=qie_mainnet ;;
  testnet) CHAIN=1983; RPCS="https://rpc2testnet.qie.digital https://rpc4testnet.qie.digital https://rpc5testnet.qie.digital"; ALIAS=qie_testnet ;;
  *) echo "usage: script/preflight.sh mainnet|testnet" >&2; exit 2 ;;
esac
: "${DEPLOYER:?set DEPLOYER to the deployer address}"
ADMIN="${NOX_ADMIN:-$DEPLOYER}"
OPERATOR="${NOX_OPERATOR:-$ADMIN}"
fail=0
ok() { printf "  ok    %s\n" "$1"; }
warn() { printf "  WARN  %s\n" "$1"; }
bad() { printf "  FAIL  %s\n" "$1"; fail=1; }

echo "Network $NET (chain $CHAIN)"
RPC=""
for r in $RPCS; do
  if id=$(cast chain-id --rpc-url "$r" 2>/dev/null) && [ "$id" = "$CHAIN" ]; then ok "$r answers (block $(cast block-number --rpc-url "$r"))"; RPC="${RPC:-$r}"; else warn "$r is down or on another chain"; fi
done
[ -n "$RPC" ] || { bad "no working RPC"; exit 1; }

GAS=$(cast gas-price --rpc-url "$RPC")
echo "Gas price: $GAS wei"

echo "Roles"
[ "$ADMIN" != "$OPERATOR" ] && ok "admin $ADMIN differs from operator $OPERATOR" || {
  if [ "$NET" = mainnet ]; then warn "admin = operator ($ADMIN): the bot's hot key could change credits, rewards and roles; use a separate cold admin wallet"; else ok "admin = operator (fine on testnet)"; fi
}

echo "Simulation (no broadcast)"
SIM=$(NOX_ADMIN="$ADMIN" NOX_OPERATOR="$OPERATOR" forge script script/Deploy.s.sol --rpc-url "$ALIAS" --sender "$DEPLOYER" 2>&1) || { bad "deploy simulation failed"; echo "$SIM" | tail -5; exit 1; }
GASUSED=$(echo "$SIM" | sed -n 's/.*Estimated total gas used for script: \([0-9]*\).*/\1/p')
ok "deploy simulates: $GASUSED gas"
# Budget twice the simulated gas at the current price (QIE charges at least half the gas limit).
NEED=$(python3 -c "print($GASUSED * $GAS * 2)")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
echo "Deployer $DEPLOYER: $(cast from-wei "$BAL") QIE, needs about $(cast from-wei "$NEED") QIE"
[ "$(python3 -c "print(int($BAL >= $NEED))")" = 1 ] && ok "deployer can pay for the deploy" || bad "deployer needs at least $(cast from-wei "$NEED") QIE (no faucet on mainnet)"

[ $fail = 0 ] && echo "Preflight passed." || { echo "Preflight failed."; exit 1; }
