# fund1 runbook

All commands use Foundry's `cast`/`forge` against Robinhood Chain mainnet
(`--rpc-url https://rpc.mainnet.chain.robinhood.com`, chain id 4663). Use
`https://rpc.testnet.chain.robinhood.com` (46630) for a dry run. The manager key is `me`
below; the deployer can be any key.

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com
export FUND=0x...   # after deploy: the fund — trades, NAV, and the v4 hook on its pool
export SHARE=$(cast call $FUND "share()(address)" --rpc-url $RPC)     # the share token
export ROUTER=0x8876789976dEcBfCbBbe364623C63652db8C0904
export PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
export WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
export USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
```

## Deploy (any key) + fund the fund (owner)

```bash
OWNER=0xTheManager FUND_NAME="My Fund" FUND_SYMBOL=MYF \
  forge script script/Deploy.s.sol --rpc-url $RPC --account deployer --broadcast
# one CREATE2 tx (salt mined in-script for the fund's v4 hook permission bits) deploys
# fund -> share and initializes the fund's pool; prints both

# testnet: same thing, but USDG defaults to Global Dollar (testnet)
# 0x004A37353Bd51CE8eDa2644E85E6a097ee07FB80 — the only USDG there with live v3 stock pools.
# MINT_USDG=true instead gives a throwaway mintable TestUSDG (no pools; deposits only).
OWNER=0xTheManager FUND_NAME="My Fund" FUND_SYMBOL=MYF \
  forge script script/DeployTestnet.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com --account deployer --broadcast

# owner: one-time Permit2 approvals for USDG and shares -> router, as for any token swapped there
for T in $USDG $SHARE; do
  cast send $T "approve(address,uint256)" $PERMIT2 $(cast max-uint) --rpc-url $RPC --account me
  cast send $PERMIT2 "approve(address,address,uint160,uint48)" $T $ROUTER \
    0xffffffffffffffffffffffffffffffffffffffff 0xffffffffffff --rpc-url $RPC --account me
done

# deposit $10,000 -> 1,000,000 shares on the first deposit. It is one router swap: V4_SWAP
# (0x10) on the fund's pool with the actions SETTLE (0x0b: pay the USDG in FIRST),
# SWAP_EXACT_IN_SINGLE (0x06) and TAKE_ALL (0x0f). Later deposits mint AMT * totalSupply / nav();
# quote MIN off that. The swap params carry this router's extra minHopPriceX36 field (0 = off).
AMT=10000000000
MIN=1000000000000000000000000
KEY=$(cast call $FUND "poolKey()((address,address,uint24,int24,address))" --rpc-url $RPC)
Z=$(cast call $FUND "usdgIsZero()(bool)" --rpc-url $RPC)      # USDG in: zeroForOne = usdgIsZero
P0=$(cast abi-encode "f(address,uint256,bool)" $USDG $AMT true)
P1=$(cast abi-encode "f((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes)" \
     "$KEY" $Z $AMT $MIN 0 0x)
P2=$(cast abi-encode "f(address,uint256)" $SHARE $MIN)
IN0=$(cast abi-encode "f(bytes,bytes[])" 0x0b060f "[$P0,$P1,$P2]")
cast send $ROUTER "execute(bytes,bytes[])" 0x10 "[$IN0]" --rpc-url $RPC --account me
```

## Trade (owner)

`trade` takes the **venue** (the swap contract to call) and the calldata for it. Which venue
depends on where the liquidity is:

| Chain | v3 pools reachable through | Why |
| --- | --- | --- |
| mainnet | Universal Router `0x8876789976dEcBfCbBbe364623C63652db8C0904` | its v3 factory immutable is live there |
| testnet | SwapRouter02 `0xF3545700dbc70B8b3962FAf08039BdA2664b71C9` | the Universal Router's v3 factory (`0x1f7d7550…fd2efa`) holds **no code** on testnet, so every pool address it derives is empty and the swap reverts blank. The live pools are under factory `0xe138C58a…B52979`. |

v4 pools go through the Universal Router on both. Keep every route USDG ↔ coin so the
cost-basis accounting stays honest. `minOut` is the only price check.

**Testnet — invest 5,000 USDG into AAPL (v3 0.05%) via SwapRouter02:**

```bash
AMT=5000000000
SWAP_ROUTER_02=0xF3545700dbc70B8b3962FAf08039BdA2664b71C9
P=$(cast concat-hex $USDG 0x0001f4 $AAPL)
DATA=$(cast calldata "exactInput((bytes,address,uint256,uint256))" "($P,$FUND,$AMT,0)")
cast send $FUND "trade(address,bytes,address,bool,uint256)" \
  $SWAP_ROUTER_02 $DATA $AAPL true $MIN_OUT --rpc-url $RPC --account me
```

**Mainnet — the same trade through the Universal Router.** This router's quirk: **v2/v3 swap
inputs end with an extra `uint256[]`** (`[]` = disabled). Recipient sentinels: `0x...01` =
the caller (the fund), `0x...02` = the router. `payerIsUser` must be **`true`** — that makes
the fund the payer and the router pulls from it via Permit2; `false` would have the router
pay from its own (empty) balance.

```bash
P=$(cast concat-hex $USDG 0x000064 $WETH)
IN0=$(cast abi-encode "f(address,uint256,uint256,bytes,bool,uint256[])" \
      0x0000000000000000000000000000000000000001 $AMT 0 $P true "[]")
DATA=$(cast calldata "execute(bytes,bytes[])" 0x00 "[$IN0]")
cast send $FUND "trade(address,bytes,address,bool,uint256)" \
  $ROUTER $DATA $WETH true $MIN_OUT --rpc-url $RPC --account me
```

Realize back to USDG: same shape with the path reversed, `buy = false`, `minOut` now
denominated in USDG. Approvals for the input token (direct and Permit2) happen automatically
on first use, once per token/venue pair. A pools.trade coin (hookless v4 pool quoted in
native ETH) is one `trade` through the Universal Router: USDG →(v3)→ WETH → `UNWRAP_WETH` →
`V4_SWAP` (`0x10`) — let the Uniswap SDK encode the v4 actions blob; quote via the V4 Quoter
(`0x8dc178efb8111bb0973dd9d722ebeff267c98f94`).

If a trade reverts, the venue's own reason is re-thrown. Two reasons come from the fund
itself: `venue` means the venue address holds no code (or reverted without saying anything),
and `output` means `minOut` was not met.

## NAV window (owner)

```bash
cast call $FUND "nav()(uint256)" --rpc-url $RPC          # USDG base units
cast call $FUND "invested()(uint256)" --rpc-url $RPC     # total cost basis of open positions
cast call $FUND "cost(address)(uint256)" $COIN --rpc-url $RPC   # one position's cost basis
cast call $SHARE "totalSupply()(uint256)" --rpc-url $RPC
cast call $SHARE "balanceOf(address)(uint256)" $ME --rpc-url $RPC

# redeem 500,000 shares for their NAV slice in USDG: the deposit swap the other way
# (shares in, USDG out, zeroForOne flipped). Quote MIN as SH * nav() / totalSupply().
SH=500000000000000000000000
MIN=0
NZ=$([ "$Z" = true ] && echo false || echo true)
P0=$(cast abi-encode "f(address,uint256,bool)" $SHARE $SH true)
P1=$(cast abi-encode "f((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes)" \
     "$KEY" $NZ $SH $MIN 0 0x)
P2=$(cast abi-encode "f(address,uint256)" $USDG $MIN)
IN0=$(cast abi-encode "f(bytes,bytes[])" 0x0b060f "[$P0,$P1,$P2]")
cast send $ROUTER "execute(bytes,bytes[])" 0x10 "[$IN0]" --rpc-url $RPC --account me
```

There is no deposit or redeem function: shares are minted and burned solely inside the fund's
`beforeSwap`, for a swap the Universal Router makes for the owner. Any other swap on the pool
— a stranger at the PoolManager, a non-owner at the router — reverts inside the hook
(`"locked"`, wrapped by the PoolManager). Pay the input in first: the hook takes
it out of the PoolManager as it pays the output in, so a swap-then-`SETTLE_ALL` encoding
finds nothing to take.

Selling releases cost basis pro-rata automatically — closing a position zeroes it, win or
lose. No manual marking exists.

If a redeem reverts, the fund is too invested to pay it — sell positions first.

## Making the share token tradable

`$SHARE` is a normal ERC20 (with EIP-2612 permit); the fund is merely its minter. To open it
to the public, the owner seeds a Uniswap pool with `$SHARE` + USDG (via the standard Uniswap
UI/SDK with the owner's own tokens — not through the fund contract). Market price will float around NAV on pure trust:
nothing arbs it, and nothing on-chain protects holders from the manager.

## Emergency (owner)

```bash
cast send $FUND "withdraw(address)" $COIN --rpc-url $RPC --account me   # sweep one token, fund stays alive
cast send $FUND "withdrawAll(address[])" "[$COIN,$USDG]" --rpc-url $RPC --account me   # evacuate + kill the fund
cast send $FUND "burn(address)" $COIN --rpc-url $RPC --account me   # rug: erase from NAV + torch
```

`withdrawAll` is terminal: it sweeps every listed token to the owner (list USDG too) and
zeroes the whole cost ledger with no arithmetic that could revert — even a bugged basis
can't block the exit. The fund is dead afterwards; deploy a new one. `burn` torches one
coin to 0xdEaD, erasing its basis (best-effort, works on frozen rugs too).
