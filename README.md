<div align="center">
  <img src="https://fund1.io/logo.png" alt="fund1" width="88" height="88" />

  # fund1 contracts

  **Tokenized single-owner funds on Robinhood Chain.**
  <br />
  One share token *is* the fund — no vault wrapper, no oracle, no separate deposit contract.

  [![CI](https://github.com/merlo-team/fund1-contracts/actions/workflows/test.yml/badge.svg)](https://github.com/merlo-team/fund1-contracts/actions/workflows/test.yml)
  [![Solidity](https://img.shields.io/badge/solidity-0.8.26-1c2029?style=flat-square)](src/Fund1.sol)
  [![Foundry](https://img.shields.io/badge/built%20with-Foundry-1c2029?style=flat-square)](foundry.toml)
  [![Uniswap v4](https://img.shields.io/badge/uniswap-v4%20hook-1c2029?style=flat-square)](src/Fund1.sol)
  [![Chain](https://img.shields.io/badge/chain-Robinhood%20Chain-EBB73F?style=flat-square)](https://docs.robinhood.com/chain/)
  [![License: MIT](https://img.shields.io/badge/license-MIT-1c2029?style=flat-square)](LICENSE)

  [fund1.io](https://fund1.io) · [Docs](https://fund1.io/docs) · [X / Twitter](https://x.com/fund1io)
</div>

<br />

> This is the open-source contracts repo — just `Fund1` and `Fund1Share`, the two contracts that
> make up the protocol. The live product (client, server, MCP agent tooling) lives in a
> separate, private repo; this one exists so the protocol itself is independently readable,
> buildable, and testable by anyone.

## Contents

- [What it is](#what-it-is)
- [How shares are priced (oracle-free)](#how-shares-are-priced-oracle-free)
- [Interface](#interface)
- [The v4 hook, mechanically](#the-v4-hook-mechanically)
- [Network / addresses](#network--addresses-robinhood-chain-mainnet-chain-id-4663)
- [Build / test / deploy](#build--test--deploy)

## What it is

A tokenized single-manager fund for Robinhood Chain, in two contracts. The fund deploys the
share token:

- **`Fund1`** — the manager, the share token's `minter`, **and a Uniswap v4 hook**. It
  initializes a USDG/share pool on the v4 PoolManager hooked by itself. The pool admits exactly
  one kind of swap: the owner's, sent through **Uniswap's Universal Router** like any other v4
  swap on the chain. The fund's `beforeSwap` is the only place shares are ever minted or burned:
  it prices them at NAV, takes the input the router paid in, pays the output back for the router
  to take, and hands the whole swap amount to itself so the empty curve does nothing. The owner
  trades the pot through the same router (v2/v3/v4, every pools.trade coin included).
- **`Fund1Share`** — the share token. A plain 18-decimal ERC20 (solmate, so EIP-2612 permit
  comes free) with exactly one addition: an immutable `minter` that alone can `mint`/`burn`.
  No hooks, no pausing, no blacklist — it trades anywhere any ERC20 does.

There is no deposit or redeem function anywhere. A deposit **is** a swap — USDG → share on the
fund's pool, one `V4_SWAP` command to the Universal Router — and a redeem is the same swap the
other way. To anything reading the chain, the owner swapped tokens on Uniswap. Everyone else
gets exposure by trading the share token itself, e.g. in an ordinary Uniswap pool against USDG.
~260 lines of Solidity across the two, no oracle, no governance. The owner is a **constructor
parameter** — the deployer is irrelevant, so anyone can deploy a fund on someone else's behalf.
Every fund function is owner-only; the share token has no privileged functions besides
mint/burn, which only the fund can call.

## How shares are priced (oracle-free)

`NAV = liquid USDG + invested`, where `invested` is the **USDG cost basis of open positions,
tracked per coin** (`cost[coin]`): a buy books the USDG spent into the coin's basis; a sell
releases basis pro-rata to how much of the position left. Fully closing a position therefore
zeroes its basis automatically — at a profit or at a loss — with no manual marking.

- A deposit of `amount` USDG mints `amount × supply / NAV` shares (first deposit: 100 shares
  per USDG — $10,000 → 1,000,000 shares).
- A redeem of `shares` burns them and pays `shares × NAV / supply` in liquid USDG; if the fund
  is too invested to cover it, the swap reverts — sell positions first.

So: deposit $10k → 1mm shares; invest $5k in coins → NAV still $10k (positions at cost), and
0.5mm shares redeem exactly the $5k liquid; sell everything for $95k → NAV $95k, and the
remaining 0.5mm shares redeem it all.

**Cost is not market value.** That's why mint/redeem are owner-only: an open NAV window priced
at cost would be pure arbitrage against stale marks. Holders buy and sell the token on the
market instead, where it's priced continuously. One accounting edge remains: a coin that can
never be sold (a rug) keeps its cost in NAV while held — `burn` or `withdrawAll` it and its
basis is erased along with the tokens.

## Interface

`Fund1Share` is the standard ERC20 surface plus `minter()`, `mint(to, amount)` and
`burn(from, amount)` (the last two revert `"denied"` for anyone but the fund).

**Deposit and redeem** are Universal Router transactions from the owner: `execute` with one
`V4_SWAP` (`0x10`) command on the fund's pool (`poolKey()`) and three v4 actions —

| Action | Params | Deposit | Redeem |
|--------|--------|---------|--------|
| `SETTLE` (`0x0b`) | `(currency, amount, payerIsUser = true)` | USDG in | shares in |
| `SWAP_EXACT_IN_SINGLE` (`0x06`) | `(poolKey, zeroForOne, amountIn, amountOutMinimum, minHopPriceX36, hookData)` | `zeroForOne = usdgIsZero()` | `zeroForOne = !usdgIsZero()` |
| `TAKE_ALL` (`0x0f`) | `(currency, minAmount)` | shares out | USDG out |

USDG in mints shares at NAV; shares in burns them for their NAV slice in liquid USDG.
`amountOutMinimum` is the router's own price check. Two things to get right: **pay the input in
first** — `SETTLE` before the swap, because the hook takes the input out of the PoolManager in
the same breath it pays the output in, so the usual swap-then-`SETTLE_ALL` order only works
when the PoolManager happens to hold float from other pools, and never for a redeem — and this
router revision's `minHopPriceX36` field in the swap params (`0` = off), the same per-hop price
floor it adds to its v2/v3 inputs. The owner approves USDG and shares to Permit2 → router once,
like any other token they swap. The pool's own `Swap` log reports zero amounts (the curve
swapped nothing); the ERC20 `Transfer` logs and the router calldata are the record of what
moved. `RUNBOOK.md` has the `cast` encoding.

Everything below is on `Fund1`; `share()`, `router()` and `poolKey()` are views. Minting
and burning happen only in `beforeSwap`, only for a swap the router makes for the owner, so
"the owner deposits and redeems only through Uniswap" is enforced rather than merely intended.

- `trade(venue, data, coin, buy, minOut)` — calls `venue` with `data` (both built off-chain)
  for a USDG ↔ `coin` trade and books the cost basis from the measured balance deltas. The
  venue is whichever swap contract holds the liquidity: the Universal Router for v4 pools,
  SwapRouter02 for v3 pools. It is per-call because a chain wires only one of them to the
  pools that matter — on Robinhood **testnet** the Universal Router's v3 factory immutable
  (`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`) holds no code, so every v3 pool address it
  derives is empty and the swap reverts blank; the live stock pools sit under factory
  `0xe138C58a8f5FB97A52bf17966Ad1c68bD4B52979`, reachable through SwapRouter02 at
  `0xF3545700dbc70B8b3962FAf08039BdA2664b71C9`. Mainnet still routes v3 through the Universal
  Router. Passing the venue per call is no extra trust — `trade` is owner-only and the owner
  can already empty the fund with `withdrawAll` — and nothing the venue returns is believed:
  the accounting is the fund's own before/after balances. A venue holding no code is rejected
  (a plain call to one would silently succeed), and a venue's revert is re-thrown as-is so a
  failed swap says why. `minOut` (**the only price check**) applies to the coin on buys, to
  USDG on sells. Positions are plain ERC20s — for ETH exposure hold WETH; the fund never
  touches native ETH, and the input token self-approves the venue on first use, both directly
  and through Permit2.
- `withdraw(token)` — sweeps one token to the owner, erasing its cost from NAV, fund stays
  alive. For airdrops and retired positions (USDG only leaves via a redeem or `withdrawAll`).
- `withdrawAll(tokens[])` — terminal fire exit; latches the fund dead (deposits and trades
  disabled for good), zeroes the cost ledger outright (no subtraction, so a bugged basis can
  never block the way out), and sweeps the listed tokens to the owner — list everything the
  fund holds, USDG included. The contract keeps no position list; the app layer does.
- `burn(coin)` — rug disposal: erases the coin's cost basis from NAV and torches any
  remaining tokens to `0xdEaD` (best-effort, so frozen or balance-zeroing rugs still get
  erased from the books).

Trust statement, plainly: holding the share token means trusting the owner completely — they
control trades (`minOut` included), the NAV window, and the fire exit. Nothing on-chain protects
holders from the manager; that is the deliberate design.

## The v4 hook, mechanically

v4 reads a hook's permissions off its **address** (the low 14 bits), so the fund is deployed
with CREATE2 at a salt-mined address carrying `BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA` —
`script/HookMiner.sol` finds the salt, the constructor refuses to deploy anywhere else. The
pool is `{USDG, share}` sorted by address, fee 0, tick spacing 1, created with the starting
price v4 demands (`2^96`, i.e. 1.0). Nobody is stopped from adding liquidity to it, and nothing
happens if they do: the hook consumes the whole swap amount, so the curve — and anything in it
— is never touched.

Who may swap: v4 hands the hook the swapper's address, which for a router swap is the router
itself. The Universal Router reports who called it (`msgSender()`, the initiator of its lock,
set for the duration of `execute`), so the hook admits a swap iff the swapper is the canonical
router **and** the router's caller is the owner. Anything else — a stranger at the PoolManager,
a non-owner at the router, a different router — reverts in the hook. (This is also why the fund
can't swap on its own pool from `trade`: the router would report the fund, not the owner.)

A deposit is `router.execute(V4_SWAP: SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL)`:

1. `SETTLE`: the router `sync`s USDG, pulls the owner's USDG through Permit2 into the
   PoolManager, and `settle`s — it is now credited `+in`.
2. `SWAP_EXACT_IN_SINGLE`: the router calls `swap`. The PoolManager calls the fund's
   `beforeSwap`, which checks the swapper and the owner, prices `shares` at NAV, `take`s the
   USDG into the fund, mints the shares straight into the PoolManager and `settle`s them to
   itself, and returns `BeforeSwapDelta(+in, −out)`.
3. v4 subtracts the specified part from the swap amount, which hits zero, so the curve is
   skipped. The hook's `(+in, −out)` cancels its take and settle; the router is handed the
   mirror, `(−in, +out)` — the `−in` cancels step 1, and the router checks `+out` against
   `amountOutMinimum`.
4. `TAKE_ALL`: the router `take`s the `+out` shares to the owner. Every delta is zero when the
   unlock closes and the PoolManager holds nothing it didn't before.

A redeem is the same the other way, with the shares burned in the middle.

## Network / addresses (Robinhood Chain mainnet, chain id 4663)

| What | Value |
|------|-------|
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | https://robinhoodchain.blockscout.com |
| Universal Router (a revision with per-hop price floors: `minHopPriceX36` on v2/v3/v4 swap inputs; source verified on Sourcify, chain 4663) | `0x8876789976dEcBfCbBbe364623C63652db8C0904` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDG (6 decimals; the chain's stablecoin — no USDC here) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Uniswap v4 PoolManager (the fund's pool lives here; via router for v4 trades) | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| V4 Quoter (for off-chain `minOut` quotes) | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| CREATE2 deployer proxy (forge's default; the fund deploys through it) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Testnet | chain id 46630, `https://rpc.testnet.chain.robinhood.com` — router and PoolManager at the same addresses |

## Build / test / deploy

Install Foundry if needed: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

```bash
git clone --recurse-submodules https://github.com/merlo-team/fund1-contracts.git
cd fund1-contracts

forge build
forge test --no-match-contract Fork   # 22 unit tests: mock router, REAL v4 PoolManager; incl. the full lifecycle
forge test --match-contract Fork      # LIVE e2e on a mainnet fork: real USDG, router and PoolManager —
                                      # deposit (router swap) -> invest -> realize -> redeem (router swap);
                                      # stranger and non-owner rejected. The public RPC serves only
                                      # ~3 min of state history: keep it quick.

OWNER=0xTheManager FUND_NAME="My Fund" FUND_SYMBOL=MYF \
  forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast
```

Cloned without `--recurse-submodules`? Pull the dependencies in separately:

```bash
git submodule update --init --recursive
```

See `RUNBOOK.md` for `cast` command sequences (deposit, trade, redeem, fire exit).

## License

MIT — see [LICENSE](LICENSE).
