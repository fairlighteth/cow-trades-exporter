# 🐮 cow-trades-exporter

Export your complete [CoW Protocol](https://cow.fi) trade history across all 10 chains into a single tax-ready CSV.

Zero-config bash script with automatic token resolution via on-chain RPC. Just run and moo.

```
           (o)
    /-------\/
   / |     ||   CoW Protocol
  *  ||----||   Trade History Exporter
     ~~    ~~
```

## What it does

Fetches every trade you've ever made through CoW Swap and produces a single CSV file with human-readable token symbols, decimal-converted amounts, and links to block explorers — ready to hand to your accountant or import into tax software.

### Chains supported

Ethereum · Gnosis · Arbitrum · Base · Avalanche · Polygon · BNB · Linea · Lens · Ink

### How it works

1. **Fetch orders** — Paginates through `/account/{owner}/orders` on each chain's CoW API
2. **Fetch trades** — Queries `/trades?owner=` to catch eth-flow orders and all fill events
3. **Reconcile** — Cross-references both sources to find orphaned trades (eth-flow, programmatic orders) and fetches their order details individually
4. **Resolve tokens** — Unknown tokens are looked up on-chain via batched `eth_call` RPC requests (`symbol()` + `decimals()`). Falls back to sequential calls if the RPC doesn't support batching
5. **Generate CSV** — Merges everything into a single sorted CSV with 20 columns

### CSV columns

| Column | Description |
|---|---|
| Date (UTC) | Order creation timestamp |
| Chain | Network name (ethereum, gnosis, arbitrum, ...) |
| Direction | `sell` or `buy` |
| Order Class | `market`, `limit`, or `liquidity` |
| Sell Token | Token symbol (e.g. WETH, USDC) |
| Sell Token Address | Contract address (0x...) |
| Sell Amount | Human-readable amount (decimal-converted) |
| Buy Token | Token symbol |
| Buy Token Address | Contract address (0x...) |
| Buy Amount | Human-readable amount |
| Fee Amount | Protocol fee (decimal-converted) |
| Fee Token | Fee token symbol |
| Tx Hash | Settlement transaction hash |
| Block Explorer | Direct link to tx on chain explorer |
| CoW Explorer | Direct link to order on explorer.cow.fi |
| Owner | Order creator address |
| Receiver | Token recipient address |
| Order UID | Full CoW Protocol order identifier |
| Partial Fill | `yes` / `no` |
| Status | `fulfilled`, `traded`, etc. |

## Quick start

```bash
# Download
curl -O https://raw.githubusercontent.com/fairlighteth/cow-trades-exporter/main/cow_trade_history.sh
chmod +x cow_trade_history.sh

# Run with address
./cow_trade_history.sh 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045

# Or run interactively (will prompt for address)
./cow_trade_history.sh
```

Output lands in `./cow_exports/cow_trades_<addr>_<timestamp>.csv`.

## Requirements

| Dependency | macOS | Linux |
|---|---|---|
| `curl` | ✅ Built-in | ✅ Built-in |
| `perl` | ✅ Built-in | ✅ Built-in |
| `jq` | ❌ Auto-installs via Homebrew | ❌ Auto-installs via apt/dnf |
| `bash` 3.2+ | ✅ Built-in | ✅ Built-in |

The script detects if `jq` is missing and attempts to install it automatically. If that fails, it prints instructions.

Works with any shell invocation — `sh`, `bash`, `zsh`, or `./` — the script auto-re-execs under bash if needed.

## Token resolution

The script ships with a built-in cache of ~90 common tokens (WETH, USDC, COW, DAI, stablecoins, Ondo tokenized stocks, etc.) across all chains.

For any token not in the cache, it makes on-chain RPC calls to the token contract's `symbol()` and `decimals()` functions. These are batched per chain into a single JSON-RPC request to minimize network calls. If the RPC doesn't respond or doesn't support batching, it falls back to sequential calls with rate limiting.

Tokens that still can't be resolved show up with their full contract address as the symbol — so you never lose data.

## Example output

```
sh cow_trade_history.sh 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045

           (o)
    /-------\/
   / |     ||   CoW Protocol
  *  ||----||   Trade History Exporter
     ~~    ~~

============================================
  Address:  0xd8dA6B..6045
  Chains:   10 (ethereum gnosis arbitrum base avalanche polygon bnb linea lens ink)
  Output:   ./cow_exports/cow_trades_d8dA6BF2_20260219_160000.csv
============================================

--- ethereum ---
  orders page 1: +201 (total: 201)
  => 163 executed / 201 total orders
  => 163 trades
--- gnosis ---
  ...
--- bnb ---
  orders page 1: +29 (total: 29)
  => 26 executed / 29 total orders
  => 26 trades

Resolving unknown tokens...
  Found 36 unknown tokens — resolving via batched RPC...
  ethereum: 21 tokens...
    + PNK (18d) <- 0x93ed3fbe...
    + AURA (18d) <- 0xc0c293ce...
  bnb: 7 tokens...
    + AAPLon (18d) <- 0x390a684e...
    + NVDAon (18d) <- 0xa9ee28c8...
  Done: 30 resolved, 6 failed

Building CSV...
============================================
  EXPORT COMPLETE
============================================
  Address:     0xd8dA6B..6045
  Trade rows:  224
  File:        ./cow_exports/cow_trades_d8dA6BF2_20260219_160000.csv
  Size:        148K
  Moo! Happy tax season.  (o)~
```

## License

[MIT](LICENSE)
