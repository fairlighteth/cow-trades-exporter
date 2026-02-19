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

## Quick start (for complete beginners)

Never used a terminal before? No problem. This section walks you through every step.

### What is a terminal?

A terminal (also called "command line" or "shell") is a text-based way to talk to your computer. Instead of clicking buttons, you type commands and press **Enter**. It looks like a black or white window with a blinking cursor.

You don't need to install anything special — every Mac and Linux computer already has one.

### Step 1: Open your terminal

<details>
<summary><strong>macOS</strong></summary>

**Option A — Spotlight (fastest):**
1. Press **Cmd + Space** to open Spotlight
2. Type **Terminal**
3. Press **Enter**

**Option B — Finder:**
1. Open **Finder**
2. Go to **Applications** > **Utilities**
3. Double-click **Terminal**

You'll see a window with a `$` or `%` prompt — that's where you type commands.
</details>

<details>
<summary><strong>Windows</strong></summary>

You'll need WSL (Windows Subsystem for Linux):
1. Open **PowerShell** as Administrator
2. Run: `wsl --install`
3. Restart your computer
4. Open **Ubuntu** from the Start menu

Alternatively, use [Git Bash](https://gitforwindows.org/) which includes the tools you need.
</details>

<details>
<summary><strong>Linux</strong></summary>

Press **Ctrl + Alt + T**, or look for "Terminal" in your application menu.
</details>

### Step 2: Download the script

Copy and paste this into your terminal, then press **Enter**:

```bash
curl -O https://raw.githubusercontent.com/fairlighteth/cow-trades-exporter/main/cow_trade_history.sh
```

This downloads the script file to your current folder (usually your home folder).

Then make it executable (this tells your computer it's OK to run this file):

```bash
chmod +x cow_trade_history.sh
```

### Step 3: Run it

**Option A — Provide your wallet address directly:**

```bash
./cow_trade_history.sh 0xYOUR_WALLET_ADDRESS_HERE
```

Replace `0xYOUR_WALLET_ADDRESS_HERE` with your actual Ethereum wallet address (the `0x...` address you use in CoW Swap).

**Option B — Run interactively (it will ask you for the address):**

```bash
./cow_trade_history.sh
```

### Step 4: Find your CSV file

When the script finishes, it tells you where the file was saved. It will be in a folder called `cow_exports` inside wherever you ran the script:

```
./cow_exports/cow_trades_<addr>_<timestamp>.csv
```

To open the folder in Finder (macOS):

```bash
open cow_exports
```

You can open the `.csv` file with Excel, Google Sheets, Numbers, or any spreadsheet app.

### Troubleshooting

| Problem | Solution |
|---|---|
| `permission denied` | Run `chmod +x cow_trade_history.sh` and try again |
| `command not found: jq` | The script tries to install `jq` automatically. If it can't, run `brew install jq` (macOS) or `sudo apt install jq` (Linux) |
| `curl: command not found` | This is very rare — `curl` comes pre-installed. On Linux try `sudo apt install curl` |
| Script shows 0 trades | Double-check your wallet address. Make sure it's the address you used on CoW Swap |
| `No such file or directory` | Make sure you're in the same folder where you downloaded the script. Run `ls` to check — you should see `cow_trade_history.sh` listed |

---

## Quick start (for developers)

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
| `curl` | Built-in | Built-in |
| `perl` | Built-in | Built-in |
| `jq` | Auto-installs via Homebrew | Auto-installs via apt/dnf |
| `bash` 3.2+ | Built-in | Built-in |

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

## Example CSV

Here's what the output looks like (columns truncated for readability):

| Date (UTC) | Chain | Direction | Sell Token | Sell Token Address | Sell Amount | Buy Token | Buy Token Address | Buy Amount | Fee Amount |
|---|---|---|---|---|---|---|---|---|---|
| 2024-03-15T10:23:01Z | ethereum | sell | WETH | 0xc02aaa...756cc2 | 1.5 | USDC | 0xa0b869...e18ad8 | 5,234.12 | 0.003 |
| 2024-03-16T14:05:33Z | ethereum | sell | USDC | 0xa0b869...e18ad8 | 2,000 | COW | 0xdef1ca...8c46eb | 8,421.37 | 4.52 |
| 2024-04-01T09:12:44Z | arbitrum | buy | ARB | 0x912ce5...e5b0f7 | 500 | USDC | 0xaf88d0...e5b0f7 | 612.50 | 0.85 |
| 2024-04-10T18:30:00Z | gnosis | sell | WXDAI | 0xe91d15...3a97d | 1,000 | COW | 0x177127...8973d3 | 12,345.67 | 0.001 |
| 2024-05-22T11:00:15Z | bnb | sell | USDC | 0x8ac76a...b72223 | 500 | AAPLon | 0x390a68...018eb9 | 2.156 | 1.20 |

<details>
<summary>Full 20-column CSV header</summary>

```
Date (UTC),Chain,Direction,Order Class,Sell Token,Sell Token Address,Sell Amount,Buy Token,Buy Token Address,Buy Amount,Fee Amount,Fee Token,Tx Hash,Block Explorer,CoW Explorer,Owner,Receiver,Order UID,Partial Fill,Status
```
</details>

Each row also includes: Order Class, Fee Token, Tx Hash, Block Explorer link, CoW Explorer link, Owner, Receiver, Order UID, Partial Fill flag, and Status. Token addresses are always present even when the symbol was resolved, so you can cross-reference on-chain.

## License

[MIT](LICENSE)
