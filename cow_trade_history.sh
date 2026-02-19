#!/usr/bin/env bash
# Re-exec under bash if invoked via sh/dash/zsh (preserves all args)
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi
# ============================================================================
# CoW Protocol — Complete Trade History Exporter  (v6)
# ============================================================================
# Exports ALL trades across ALL CoW Protocol chains into a single tax-ready
# CSV. Uses dual-source fetching:
#   Source A: Paginate /account/{owner}/orders  (standard orders)
#   Source B: Fetch    /trades?owner=           (eth-flow + all fills)
# Then reconciles orphaned trades by fetching individual order details.
#
# Usage:
#   ./cow_trade_history.sh                      # interactive prompt
#   ./cow_trade_history.sh 0x1234...abcd        # direct address
#
# Requirements: curl, jq, perl  (bash 3.2+ / macOS compatible)
# ============================================================================

set -eo pipefail

cat << 'MOOOO'

           (o)
    /-------\/ 
   / |     ||   CoW Protocol
  *  ||----||   Trade History Exporter
     ~~    ~~
MOOOO

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OUTPUT_DIR="./cow_exports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PAGE_LIMIT=1000
API_DELAY=0.25

# All 10 production chains
CHAIN_NAMES=(    "ethereum"                    "gnosis"                    "arbitrum"                        "base"                    "avalanche"                    "polygon"                    "bnb"                    "linea"                    "lens"                    "ink" )
CHAIN_APIS=(     "https://api.cow.fi/mainnet"  "https://api.cow.fi/xdai"  "https://api.cow.fi/arbitrum_one" "https://api.cow.fi/base" "https://api.cow.fi/avalanche" "https://api.cow.fi/polygon" "https://api.cow.fi/bnb" "https://api.cow.fi/linea" "https://api.cow.fi/lens" "https://api.cow.fi/ink" )
CHAIN_IDS=(      "1"                           "100"                      "42161"                           "8453"                    "43114"                        "137"                        "56"                     "59144"                    "232"                     "57073" )
CHAIN_EXPLORERS=("https://etherscan.io/tx"     "https://gnosisscan.io/tx" "https://arbiscan.io/tx"          "https://basescan.org/tx" "https://snowscan.xyz/tx"      "https://polygonscan.com/tx" "https://bscscan.com/tx" "https://lineascan.build/tx" "https://explorer.lens.xyz/tx" "https://explorer.inkonchain.com/tx" )
CHAIN_RPCS=(     "https://ethereum-rpc.publicnode.com"    "https://rpc.gnosischain.com" "https://arb1.arbitrum.io/rpc" "https://mainnet.base.org"  "https://api.avax.network/ext/bc/C/rpc" "https://polygon-bor-rpc.publicnode.com"   "https://bsc-dataseed.binance.org" "https://rpc.linea.build" "https://rpc.lens.xyz" "https://rpc-gel.inkonchain.com" )

# ---------------------------------------------------------------------------
# Dependency check — auto-install jq on macOS if possible
# ---------------------------------------------------------------------------
install_jq() {
    echo ""
    echo "  jq is required but not installed."
    echo ""

    # macOS with Homebrew
    case "$OSTYPE" in
    darwin*)
        if command -v brew &>/dev/null; then
            echo "  Installing jq via Homebrew..."
            brew install jq
            return $?
        else
            echo "  Homebrew not found. Install jq with one of:"
            echo "    brew install jq          (after installing Homebrew)"
            echo "    https://brew.sh          (install Homebrew first)"
            echo ""
            echo "  Or install jq manually from: https://jqlang.github.io/jq/download/"
            return 1
        fi
        ;;
    esac

    # Linux (Debian/Ubuntu)
    if command -v apt-get &>/dev/null; then
        echo "  Installing jq via apt..."
        sudo apt-get update -qq && sudo apt-get install -y jq
        return $?
    fi

    # Linux (RHEL/Fedora)
    if command -v dnf &>/dev/null; then
        echo "  Installing jq via dnf..."
        sudo dnf install -y jq
        return $?
    fi

    echo "  Please install jq manually: https://jqlang.github.io/jq/download/"
    return 1
}

for cmd in curl perl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

if ! command -v jq &>/dev/null; then
    install_jq || { echo "ERROR: jq is required. Please install it and try again." >&2; exit 1; }
    # Verify it worked
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq installation failed." >&2
        exit 1
    fi
    echo "  jq installed successfully!"
    echo ""
fi

# ---------------------------------------------------------------------------
# Address input — accept arg or prompt interactively
# ---------------------------------------------------------------------------
OWNER="${1:-}"
if [ -z "$OWNER" ]; then
    echo "  Enter the wallet address to export (0x...):"
    printf "  > "
    read -r OWNER
    echo ""
fi

# Validate address format
OWNER=$(echo "$OWNER" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
valid=false
case "$OWNER" in
    0x*) [ "${#OWNER}" -eq 42 ] && valid=true ;;
esac
if [ "$valid" = "false" ]; then
    echo "ERROR: Invalid Ethereum address: '${OWNER:-<empty>}'" >&2
    echo "  Must be 42 characters starting with 0x" >&2
    echo "  Example: 0x76ba9825a5f707f133124e4608f1f2dd1ef4006a" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
warn() { echo "  WARN: $*" >&2; }

# curl wrapper: returns JSON to stdout, warns on errors
api_get() {
    local url="$1"
    local max_time="${2:-30}"
    local tmpbody
    tmpbody=$(mktemp)
    local http_code

    http_code=$(curl -s -o "$tmpbody" -w "%{http_code}" --max-time "$max_time" "$url" 2>/dev/null || echo "000")

    if [ "$http_code" = "000" ]; then
        warn "Network error / timeout: $url"
        rm -f "$tmpbody"; echo "[]"; return 1
    elif [ "$http_code" != "200" ]; then
        warn "HTTP ${http_code}: $url"
        rm -f "$tmpbody"; echo "[]"; return 1
    fi

    cat "$tmpbody"
    rm -f "$tmpbody"
}

# Append a JSON array to a file that already contains a JSON array.
# Uses jq with file input — never passes big JSON as shell arguments.
json_array_append() {
    local target_file="$1"   # file with existing JSON array
    local new_data_file="$2" # file with new JSON array to merge
    local tmp
    tmp=$(mktemp)
    jq -s 'add' "$target_file" "$new_data_file" > "$tmp"
    mv "$tmp" "$target_file"
}

# ---------------------------------------------------------------------------
# Output setup
# ---------------------------------------------------------------------------
ADDRESS="$OWNER"
SHORT_ADDR="${ADDRESS:0:8}..${ADDRESS:38:4}"
OUTPUT_CSV="${OUTPUT_DIR}/cow_trades_${ADDRESS:2:8}_${TIMESTAMP}.csv"
mkdir -p "$OUTPUT_DIR"

echo "============================================"
echo "  Address:  ${SHORT_ADDR}"
echo "  Chains:   ${#CHAIN_NAMES[@]} (${CHAIN_NAMES[*]})"
echo "  Output:   ${OUTPUT_CSV}"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Token map (written to file to avoid arg limits)
# ---------------------------------------------------------------------------
TOKEN_FILE=$(mktemp)
cat > "$TOKEN_FILE" << 'TOKENEOF'
{
  "ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{"s":"WETH","d":18},
  "ethereum:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48":{"s":"USDC","d":6},
  "ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7":{"s":"USDT","d":6},
  "ethereum:0x6b175474e89094c44da98b954eedeac495271d0f":{"s":"DAI","d":18},
  "ethereum:0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab":{"s":"COW","d":18},
  "ethereum:0x2260fac5e5542a773aa44fbcfedf7c193bc2c599":{"s":"WBTC","d":8},
  "ethereum:0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9":{"s":"AAVE","d":18},
  "ethereum:0x514910771af9ca656af840dff83e8264ecf986ca":{"s":"LINK","d":18},
  "ethereum:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984":{"s":"UNI","d":18},
  "ethereum:0x5a98fcbea516cf06857215779fd812ca3bef1b32":{"s":"LDO","d":18},
  "ethereum:0xae7ab96520de3a18e5e111b5eaab095312d7fe84":{"s":"stETH","d":18},
  "ethereum:0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0":{"s":"wstETH","d":18},
  "ethereum:0xbe9895146f7af43049ca1c1ae358b0541ea49704":{"s":"cbETH","d":18},
  "ethereum:0xd533a949740bb3306d119cc777fa900ba034cd52":{"s":"CRV","d":18},
  "ethereum:0xba100000625a3754423978a60c9317c58a424e3d":{"s":"BAL","d":18},
  "ethereum:0x9f8f72aa9304c8b593d555f12ef6589cc3a579a2":{"s":"MKR","d":18},
  "ethereum:0x6810e776880c02933d47db1b9fc05908e5386b96":{"s":"GNO","d":18},
  "ethereum:0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f":{"s":"GHO","d":18},
  "ethereum:0x111111111117dc0aa78b770fa6a738034120c302":{"s":"1INCH","d":18},
  "ethereum:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72":{"s":"ENS","d":18},
  "ethereum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "ethereum:0x7d1afa7b718fb893db30a3abc0cfc608aacfebb0":{"s":"MATIC","d":18},
  "ethereum:0xfaba6f8e4a5e8ab82f62fe7c39859fa577269be3":{"s":"ONDO","d":18},
  "ethereum:0x14c3abf95cb9c93a8b82c1cdcb76d72cb87b2d4c":{"s":"AAPLon","d":18},
  "ethereum:0xbb8774fb97436d23d74c1b882e8e9a69322cfd31":{"s":"AMZNon","d":18},
  "ethereum:0xf3e4872e6a4cf365888d93b6146a2baa7348f1a4":{"s":"SLVon","d":18},
  "ethereum:0xfedc5f4a6c38211c1338aa411018dfaf26612c08":{"s":"SPYon","d":18},
  "ethereum:0x03c1ec4ca9dbb168e6db0def827c085999cbffaf":{"s":"JPMon","d":18},
  "ethereum:0xf6b1117ec07684d3958cad8beb1b302bfd21103f":{"s":"TSLAon","d":18},
  "ethereum:0x0e397938c1aa0680954093495b70a9f5e2249aba":{"s":"QQQon","d":18},
  "ethereum:0x7a0f89c1606f71499950aa2590d547c3975b728e":{"s":"BLKon","d":18},
  "ethereum:0x62ca254a363dc3c748e7e955c20447ab5bf06ff7":{"s":"IVVon","d":18},
  "ethereum:0x7042a8ffc7c7049684bfbc2fcb41b72380755a43":{"s":"ADBEon","d":18},
  "ethereum:0x4d21affd27183b07335935f81a5c26b6a5a15355":{"s":"APOon","d":18},
  "gnosis:0xe91d153e0b41518a2ce8dd3d7944fa863463a97d":{"s":"WXDAI","d":18},
  "gnosis:0x6a023ccd1ff6f2045c3309768ead9e68f978f6e1":{"s":"WETH","d":18},
  "gnosis:0x9c58bacc331c9aa871afd802db6379a98e80cedb":{"s":"GNO","d":18},
  "gnosis:0x177127622c4a00f3d409b75571e12cb3c8973d3c":{"s":"COW","d":18},
  "gnosis:0xddafbb505ad214d7b80b1f830fccc89b60fb7a83":{"s":"USDC","d":6},
  "gnosis:0x4ecaba5870353805a9f068101a40e0f32ed605c6":{"s":"USDT","d":6},
  "gnosis:0x8e5bbbb09ed1ebde8674cda39a0c169401db4252":{"s":"WBTC","d":8},
  "gnosis:0xaf204776c7245bf4147c2612bf6e5972ee483701":{"s":"sDAI","d":18},
  "gnosis:0xcb444e90d8198415266c6a2724b7900fb12fc56e":{"s":"EURe","d":18},
  "gnosis:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"xDAI","d":18},
  "arbitrum:0x82af49447d8a07e3bd95bd0d56f35241523fbab1":{"s":"WETH","d":18},
  "arbitrum:0xaf88d065e77c8cc2239327c5edb3a432268e5831":{"s":"USDC","d":6},
  "arbitrum:0xff970a61a04b1ca14834a43f5de4533ebddb5cc8":{"s":"USDC.e","d":6},
  "arbitrum:0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9":{"s":"USDT","d":6},
  "arbitrum:0xda10009cbd5d07dd0cecc66161fc93d7c9000da1":{"s":"DAI","d":18},
  "arbitrum:0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f":{"s":"WBTC","d":8},
  "arbitrum:0xcb8b5cd20bdcaea9a010ac1f8d835824f5c87a04":{"s":"COW","d":18},
  "arbitrum:0x912ce59144191c1204e64559fe8253a0e49e6548":{"s":"ARB","d":18},
  "arbitrum:0x5979d7b546e38e414f7e9822514be443a4800529":{"s":"wstETH","d":18},
  "arbitrum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "base:0x4200000000000000000000000000000000000006":{"s":"WETH","d":18},
  "base:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913":{"s":"USDC","d":6},
  "base:0x50c5725949a6f0c72e6c4a641f24049a917db0cb":{"s":"DAI","d":18},
  "base:0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca":{"s":"USDbC","d":6},
  "base:0xc1cba3fcea344f92d9239c08c0568f6f2f0ee452":{"s":"wstETH","d":18},
  "base:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "avalanche:0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7":{"s":"WAVAX","d":18},
  "avalanche:0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e":{"s":"USDC","d":6},
  "avalanche:0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7":{"s":"USDT","d":6},
  "avalanche:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"AVAX","d":18},
  "polygon:0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270":{"s":"WMATIC","d":18},
  "polygon:0x3c499c542cef5e3811e1192ce70d8cc03d5c3359":{"s":"USDC","d":6},
  "polygon:0x2791bca1f2de4661ed88a30c99a7a9449aa84174":{"s":"USDC.e","d":6},
  "polygon:0x7ceb23fd6bc0add59e62ac25578270cff1b9f619":{"s":"WETH","d":18},
  "polygon:0xc2132d05d31c914a87c6611c10748aeb04b58e8f":{"s":"USDT","d":6},
  "polygon:0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6":{"s":"WBTC","d":8},
  "polygon:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"MATIC","d":18},
  "bnb:0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c":{"s":"WBNB","d":18},
  "bnb:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d":{"s":"USDC","d":18},
  "bnb:0x55d398326f99059ff775485246999027b3197955":{"s":"USDT","d":18},
  "bnb:0x2170ed0880ac9a755fd29b2688956bd959f933f8":{"s":"ETH","d":18},
  "bnb:0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c":{"s":"BTCB","d":18},
  "bnb:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"BNB","d":18},
  "linea:0xe5d7c2a44ffddf6b295a15c148167daaaf5cf34f":{"s":"WETH","d":18},
  "linea:0x176211869ca2b568f2a7d4ee941e073a821ee1ff":{"s":"USDC","d":6},
  "linea:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "lens:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"GHO","d":18},
  "ink:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "ethereum:0x93ed3fbe21207ec2e8f2d3c3de6e058cb73bc04d":{"s":"PNK","d":18},
  "ethereum:0xc0c293ce456ff0ed870add98a0828dd4d2903dbf":{"s":"AURA","d":18},
  "ethereum:0x19062190b1925b5b6689d7073fdfc8c2976ef8cb":{"s":"BZZ","d":16},
  "ethereum:0x455e53cbb86018ac2b8092fdcd39d8444affc3f6":{"s":"POL","d":18},
  "polygon:0x8f3cf7ad23cd3cadbd9735aff958023239c6a063":{"s":"DAI","d":18}
}
TOKENEOF

# ---------------------------------------------------------------------------
# Temp files — ALL large JSON goes via files, never shell args
# ---------------------------------------------------------------------------
ORDERS_FILE=$(mktemp)    # accumulated orders JSON array
TRADES_FILE=$(mktemp)    # accumulated trades JSON array
TMPJSON=$(mktemp)        # scratch
ORPHAN_FILE=$(mktemp)    # orphan UIDs
trap 'rm -f "$ORDERS_FILE" "$TRADES_FILE" "$TMPJSON" "$ORPHAN_FILE" "$TOKEN_FILE"' EXIT

echo "[]" > "$ORDERS_FILE"
echo "[]" > "$TRADES_FILE"

grand_total_orders=0
grand_total_trades=0
chain_count=${#CHAIN_NAMES[@]}

# =====================================================================
# PASS 1: Fetch orders (paginated) + trades per chain
# =====================================================================
for (( ci=0; ci<chain_count; ci++ )); do
    chain="${CHAIN_NAMES[$ci]}"
    api="${CHAIN_APIS[$ci]}"
    chain_id="${CHAIN_IDS[$ci]}"
    explorer="${CHAIN_EXPLORERS[$ci]}"

    echo "--- ${chain} ---"

    # ---- 1A: Paginate orders ----
    CHAIN_ORDERS_FILE=$(mktemp)
    echo "[]" > "$CHAIN_ORDERS_FILE"
    offset=0
    page=0

    while true; do
        url="${api}/api/v1/account/${ADDRESS}/orders?limit=${PAGE_LIMIT}&offset=${offset}"

        # Write response directly to file (no shell variable for big JSON)
        RESP_FILE=$(mktemp)
        api_get "$url" 45 > "$RESP_FILE"

        # Validate
        if ! jq -e 'type == "array"' "$RESP_FILE" &>/dev/null 2>&1; then
            warn "Non-array response for orders on ${chain}, skipping"
            rm -f "$RESP_FILE"
            break
        fi

        count=$(jq 'length' "$RESP_FILE")
        if [ "$count" -eq 0 ]; then
            rm -f "$RESP_FILE"
            break
        fi

        # Merge into chain orders via file
        json_array_append "$CHAIN_ORDERS_FILE" "$RESP_FILE"
        rm -f "$RESP_FILE"

        page=$((page + 1))
        offset=$((offset + count))
        echo "  orders page ${page}: +${count} (total: ${offset})"

        if [ "$count" -lt "$PAGE_LIMIT" ]; then break; fi
        sleep "$API_DELAY"
    done

    # Filter to executed, add chain metadata
    jq --arg chain "$chain" --arg chainId "$chain_id" --arg explorer "$explorer" '
        [ .[] | select(
            .status == "fulfilled" or
            .status == "partiallyFilled" or
            ((.executedSellAmount // "0") != "0")
        ) | . + { _chain: $chain, _chainId: ($chainId|tonumber), _explorer: $explorer } ]
    ' "$CHAIN_ORDERS_FILE" > "$TMPJSON"

    ecount=$(jq 'length' "$TMPJSON")
    total_on_chain=$(jq 'length' "$CHAIN_ORDERS_FILE")
    echo "  => ${ecount} executed / ${total_on_chain} total orders"
    grand_total_orders=$((grand_total_orders + ecount))

    # Append to global orders file
    json_array_append "$ORDERS_FILE" "$TMPJSON"
    rm -f "$CHAIN_ORDERS_FILE"

    sleep "$API_DELAY"

    # ---- 1B: Fetch trades?owner= ----
    RESP_FILE=$(mktemp)
    api_get "${api}/api/v1/trades?owner=${ADDRESS}" 60 > "$RESP_FILE"

    if jq -e 'type == "array"' "$RESP_FILE" &>/dev/null 2>&1; then
        tcount=$(jq 'length' "$RESP_FILE")
    else
        tcount=0
        echo "[]" > "$RESP_FILE"
    fi

    echo "  => ${tcount} trades"
    grand_total_trades=$((grand_total_trades + tcount))

    if [ "$tcount" -gt 0 ]; then
        jq --arg chain "$chain" --arg explorer "$explorer" '
            [ .[] | . + {_chain: $chain, _explorer: $explorer} ]
        ' "$RESP_FILE" > "$TMPJSON"
        json_array_append "$TRADES_FILE" "$TMPJSON"
    fi
    rm -f "$RESP_FILE"

    sleep "$API_DELAY"
    echo ""
done

echo "============================================"
echo "  Orders (from /account/orders):  ${grand_total_orders}"
echo "  Trades (from /trades?owner):    ${grand_total_trades}"
echo "============================================"

if [ "$grand_total_orders" -eq 0 ] && [ "$grand_total_trades" -eq 0 ]; then
    echo "No trades found for ${SHORT_ADDR}."
    exit 0
fi

# =====================================================================
# PASS 2: Fetch orphaned trades (in trades but not in orders)
# =====================================================================
echo ""
echo "Checking for orphaned trades..."

# Find orderUids in trades that are NOT in orders
jq -rn --slurpfile orders "$ORDERS_FILE" --slurpfile trades "$TRADES_FILE" '
    ($orders[0] | map(.uid) | unique) as $known |
    [$trades[0][] | .orderUid] | unique | map(select(. as $u | $known | index($u) | not)) | .[]
' > "$ORPHAN_FILE" 2>/dev/null || true

orphan_count=$(wc -l < "$ORPHAN_FILE" | tr -d ' ')
echo "  ${orphan_count} orphaned order UIDs (eth-flow / programmatic)"

if [ "$orphan_count" -gt 0 ]; then
    echo "  Fetching order details..."
    EXTRA_FILE=$(mktemp)
    echo "[]" > "$EXTRA_FILE"
    fetched=0

    while IFS= read -r uid; do
        [ -z "$uid" ] && continue

        # Which chain did this trade come from?
        trade_chain=$(jq -r --arg uid "$uid" '
            [.[] | select(.orderUid == $uid) | ._chain] | first // empty
        ' "$TRADES_FILE")
        [ -z "$trade_chain" ] && continue

        # Find API for this chain
        api=""
        chain_id=""
        explorer=""
        for (( ci=0; ci<chain_count; ci++ )); do
            if [ "${CHAIN_NAMES[$ci]}" = "$trade_chain" ]; then
                api="${CHAIN_APIS[$ci]}"
                chain_id="${CHAIN_IDS[$ci]}"
                explorer="${CHAIN_EXPLORERS[$ci]}"
                break
            fi
        done
        [ -z "$api" ] && continue

        RESP_FILE=$(mktemp)
        api_get "${api}/api/v1/orders/${uid}" 15 > "$RESP_FILE"

        if jq -e '.uid' "$RESP_FILE" &>/dev/null 2>&1; then
            jq --arg chain "$trade_chain" --arg chainId "$chain_id" --arg explorer "$explorer" '
                [. + { _chain: $chain, _chainId: ($chainId|tonumber), _explorer: $explorer }]
            ' "$RESP_FILE" > "$TMPJSON"
            json_array_append "$EXTRA_FILE" "$TMPJSON"
            fetched=$((fetched + 1))
        fi
        rm -f "$RESP_FILE"

        # Progress
        if [ $((fetched % 20)) -eq 0 ] && [ "$fetched" -gt 0 ]; then
            printf "\r  %d / %d fetched..." "$fetched" "$orphan_count" >&2
        fi

        sleep "$API_DELAY"
    done < "$ORPHAN_FILE"

    printf "\r  %d / %d fetched.      \n" "$fetched" "$orphan_count" >&2

    # Merge extra orders into main orders
    json_array_append "$ORDERS_FILE" "$EXTRA_FILE"

    # Deduplicate by uid
    jq 'unique_by(.uid)' "$ORDERS_FILE" > "$TMPJSON"
    mv "$TMPJSON" "$ORDERS_FILE"

    rm -f "$EXTRA_FILE"
fi

final_order_count=$(jq 'length' "$ORDERS_FILE")
final_trade_count=$(jq 'length' "$TRADES_FILE")
echo ""
echo "  Final: ${final_order_count} orders, ${final_trade_count} trade fills"

# =====================================================================
# PASS 2.5: Resolve unknown token symbols via BATCHED on-chain RPC
#   Groups all unknown tokens per chain into a single batch JSON-RPC
#   request (symbol + decimals per token). Reduces ~72 HTTP calls to ~6.
# =====================================================================

# Find chain index by name
chain_index_of() {
    local name="$1"
    for (( i=0; i<chain_count; i++ )); do
        if [ "${CHAIN_NAMES[$i]}" = "$name" ]; then echo "$i"; return; fi
    done
    echo "-1"
}

# Decode ABI-encoded string (symbol return value) from hex
decode_abi_string() {
    local hex_data="$1"
    local symbol=""

    if [ "${#hex_data}" -eq 64 ]; then
        # bytes32 return (e.g. MKR) — raw hex padded to 32 bytes
        symbol=$(echo "$hex_data" | sed 's/00*$//' | perl -pe 's/(..)/chr(hex($1))/ge; s/[^\x20-\x7E]//g' 2>/dev/null)
    elif [ "${#hex_data}" -ge 128 ]; then
        # Dynamic string: offset(32) + length(32) + data
        local len_hex="${hex_data:64:64}"
        local len
        len=$(printf "%d" "0x${len_hex}" 2>/dev/null) || len=0
        if [ "$len" -gt 0 ] && [ "$len" -lt 100 ]; then
            local str_hex="${hex_data:128:$((len * 2))}"
            symbol=$(echo "$str_hex" | perl -pe 's/(..)/chr(hex($1))/ge; s/[^\x20-\x7E]//g' 2>/dev/null)
        fi
    fi
    echo "$symbol"
}


echo ""
echo "Resolving unknown tokens..."

# Token resolution is best-effort — don't let RPC failures kill the script
set +e
set +o pipefail

# Extract all unique chain:tokenAddress pairs from orders
UNKNOWN_FILE=$(mktemp)
jq -r '
    [ .[] | {chain: ._chain, token: .sellToken}, {chain: ._chain, token: .buyToken} ]
    | map(select(.chain != null and .token != null))
    | map(.chain + ":" + (.token | ascii_downcase))
    | unique[]
' "$ORDERS_FILE" > "$UNKNOWN_FILE"

# Check which are NOT in token map
MISSING_FILE=$(mktemp)
while IFS= read -r key; do
    if ! jq -e --arg k "$key" '.[$k]' "$TOKEN_FILE" &>/dev/null; then
        echo "$key"
    fi
done < "$UNKNOWN_FILE" > "$MISSING_FILE"

missing_count=$(wc -l < "$MISSING_FILE" | tr -d ' ')

if [ "$missing_count" -gt 0 ]; then
    echo "  Found $missing_count unknown tokens — resolving via batched RPC..."
    resolved=0
    failed=0

    # Group missing tokens by chain, then batch-resolve
    for (( ci=0; ci<chain_count; ci++ )); do
        chain="${CHAIN_NAMES[$ci]}"
        rpc="${CHAIN_RPCS[$ci]}"

        # Collect addresses for this chain
        CHAIN_ADDRS=()
        while IFS= read -r key; do
            kchain="${key%%:*}"
            if [ "$kchain" = "$chain" ]; then
                CHAIN_ADDRS+=("${key#*:}")
            fi
        done < "$MISSING_FILE"

        [ "${#CHAIN_ADDRS[@]}" -eq 0 ] && continue

        token_count="${#CHAIN_ADDRS[@]}"
        echo "  ${chain}: ${token_count} tokens..."

        # --- Build batch JSON-RPC via simple string concat (no jq pipe) ---
        BATCH_REQ=$(mktemp)
        batch_json="["
        idx=0
        for addr in "${CHAIN_ADDRS[@]}"; do
            sym_id=$(( idx * 2 + 1 ))
            dec_id=$(( idx * 2 + 2 ))
            if [ "$idx" -gt 0 ]; then batch_json="${batch_json},"; fi
            batch_json="${batch_json}"'{"jsonrpc":"2.0","id":'"${sym_id}"',"method":"eth_call","params":[{"to":"'"${addr}"'","data":"0x95d89b41"},"latest"]}'
            batch_json="${batch_json}"',{"jsonrpc":"2.0","id":'"${dec_id}"',"method":"eth_call","params":[{"to":"'"${addr}"'","data":"0x313ce567"},"latest"]}'
            idx=$(( idx + 1 ))
        done
        batch_json="${batch_json}]"
        echo "$batch_json" > "$BATCH_REQ"

        # --- Send batch request ---
        BATCH_RESP=$(mktemp)
        if ! curl -s --connect-timeout 5 -m 20 -X POST "$rpc" \
            -H "Content-Type: application/json" \
            -d @"$BATCH_REQ" -o "$BATCH_RESP" 2>/dev/null; then
            echo "    curl failed for ${chain}"
        fi

        # --- Check response ---
        batch_ok=false
        if [ -s "$BATCH_RESP" ] && jq -e 'type == "array"' "$BATCH_RESP" >/dev/null 2>&1; then
            batch_ok=true
        fi

        if [ "$batch_ok" = "true" ]; then
            # Parse batch response into id->result map
            RESULT_MAP=$(mktemp)
            jq '[ .[] | {key: (.id|tostring), value: (.result // "")} ] | from_entries' \
                "$BATCH_RESP" > "$RESULT_MAP" 2>/dev/null || echo '{}' > "$RESULT_MAP"

            idx=0
            for addr in "${CHAIN_ADDRS[@]}"; do
                sym_id=$(( idx * 2 + 1 ))
                dec_id=$(( idx * 2 + 2 ))

                sym_hex=$(jq -r --arg id "$sym_id" '.[$id] // ""' "$RESULT_MAP" 2>/dev/null) || sym_hex=""
                dec_hex=$(jq -r --arg id "$dec_id" '.[$id] // ""' "$RESULT_MAP" 2>/dev/null) || dec_hex=""
                sym_hex_clean="${sym_hex#0x}"

                symbol=""
                if [ -n "$sym_hex_clean" ] && [ "${#sym_hex_clean}" -ge 64 ]; then
                    symbol=$(decode_abi_string "$sym_hex_clean") || symbol=""
                fi

                decimals=18
                if [ -n "$dec_hex" ] && [ "$dec_hex" != "" ] && [ "$dec_hex" != "0x" ]; then
                    decimals=$(printf "%d" "$dec_hex" 2>/dev/null) || decimals=18
                fi
                if [ "$decimals" -eq 0 ] 2>/dev/null; then decimals=18; fi

                key="${chain}:${addr}"
                if [ -n "$symbol" ]; then
                    if jq --arg k "$key" --arg s "$symbol" --argjson d "$decimals" \
                        '. + {($k): {s: $s, d: $d}}' "$TOKEN_FILE" > "${TOKEN_FILE}.tmp" 2>/dev/null \
                        && [ -s "${TOKEN_FILE}.tmp" ]; then
                        mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
                    else
                        rm -f "${TOKEN_FILE}.tmp"
                    fi
                    resolved=$((resolved + 1))
                    echo "    + ${symbol} (${decimals}d) <- ${addr:0:10}..."
                else
                    failed=$((failed + 1))
                    echo "    x ${addr:0:10}... (no symbol)"
                fi
                idx=$(( idx + 1 ))
            done
            rm -f "$RESULT_MAP"
        else
            # Fallback: sequential calls with rate limiting
            echo "    Batch failed, trying sequential..."
            for addr in "${CHAIN_ADDRS[@]}"; do
                key="${chain}:${addr}"

                sym_resp=$(curl -s --connect-timeout 3 -m 5 -X POST "$rpc" \
                    -H "Content-Type: application/json" \
                    -d '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"'"$addr"'","data":"0x95d89b41"},"latest"]}' 2>/dev/null) || sym_resp=""
                sym_hex=""
                if [ -n "$sym_resp" ]; then
                    sym_hex=$(echo "$sym_resp" | jq -r '.result // ""' 2>/dev/null) || sym_hex=""
                fi
                sym_hex_clean="${sym_hex#0x}"

                symbol=""
                if [ -n "$sym_hex_clean" ] && [ "${#sym_hex_clean}" -ge 64 ]; then
                    symbol=$(decode_abi_string "$sym_hex_clean") || symbol=""
                fi

                if [ -n "$symbol" ]; then
                    dec_resp=$(curl -s --connect-timeout 3 -m 5 -X POST "$rpc" \
                        -H "Content-Type: application/json" \
                        -d '{"jsonrpc":"2.0","id":2,"method":"eth_call","params":[{"to":"'"$addr"'","data":"0x313ce567"},"latest"]}' 2>/dev/null) || dec_resp=""
                    dec_hex=""
                    if [ -n "$dec_resp" ]; then
                        dec_hex=$(echo "$dec_resp" | jq -r '.result // ""' 2>/dev/null) || dec_hex=""
                    fi

                    decimals=18
                    if [ -n "$dec_hex" ] && [ "$dec_hex" != "" ] && [ "$dec_hex" != "0x" ]; then
                        decimals=$(printf "%d" "$dec_hex" 2>/dev/null) || decimals=18
                    fi
                    if [ "$decimals" -eq 0 ] 2>/dev/null; then decimals=18; fi

                    if jq --arg k "$key" --arg s "$symbol" --argjson d "$decimals" \
                        '. + {($k): {s: $s, d: $d}}' "$TOKEN_FILE" > "${TOKEN_FILE}.tmp" 2>/dev/null \
                        && [ -s "${TOKEN_FILE}.tmp" ]; then
                        mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
                    else
                        rm -f "${TOKEN_FILE}.tmp"
                    fi
                    resolved=$((resolved + 1))
                    echo "    + ${symbol} (${decimals}d) <- ${addr:0:10}..."
                else
                    failed=$((failed + 1))
                    echo "    x ${addr:0:10}... (no symbol)"
                fi
                sleep 0.3
            done
        fi

        rm -f "$BATCH_REQ" "$BATCH_RESP"
    done

    echo "  Done: ${resolved} resolved, ${failed} failed"
else
    echo "  All tokens already known!"
fi

rm -f "$UNKNOWN_FILE" "$MISSING_FILE"

# Restore strict mode for CSV generation
set -eo pipefail


# =====================================================================
# PASS 3: Merge → CSV  (all via --slurpfile, no arg limits)
# =====================================================================
echo ""
echo "Building CSV..."

jq -rn \
    --slurpfile orders "$ORDERS_FILE" \
    --slurpfile trades "$TRADES_FILE" \
    --slurpfile tokens "$TOKEN_FILE" \
'
($orders[0]) as $orders |
($trades[0]) as $trades |
($tokens[0]) as $tokens |

def token_info(chain; addr):
    (chain + ":" + (addr | ascii_downcase)) as $key |
    if $tokens[$key] then $tokens[$key]
    else {s: addr, d: 18}
    end;

def to_human(amount_str; decimals):
    (amount_str | if . == null or . == "" or . == "0" then "0" else . end) as $a |
    if $a == "0" then "0"
    elif decimals == 0 then $a
    else
        (if ($a | length) <= decimals
         then ((decimals - ($a | length) + 1) as $pad | ("0" * $pad) + $a)
         else $a end) as $padded |
        ($padded | length) as $len |
        ($padded[0:($len - decimals)]) as $integer |
        ($padded[($len - decimals):]) as $fraction |
        ($fraction | sub("0+$"; "")) as $trimmed |
        (if $integer == "" then "0" else $integer end) as $int_part |
        if $trimmed == "" then $int_part
        else $int_part + "." + $trimmed
        end
    end;

# Lookups
($trades | group_by(.orderUid) | map({key: .[0].orderUid, value: .}) | from_entries) as $tlookup |
($orders | map({key: .uid, value: .}) | from_entries) as $olookup |
([$orders[].uid] + [$trades[].orderUid] | unique) as $all_uids |

# Header
"Date (UTC),Chain,Direction,Order Class,Sell Token,Sell Token Address,Sell Amount,Buy Token,Buy Token Address,Buy Amount,Fee Amount,Fee Token,Tx Hash,Block Explorer,CoW Explorer,Owner,Receiver,Order UID,Partial Fill,Status",

# Rows
(
    [ $all_uids[] as $uid |
        ($olookup[$uid] // null) as $order |
        ($tlookup[$uid] // []) as $fills |

        (if ($fills | length) > 0 then
            $fills[] | {
                sellAmt: (.sellAmount // "0"),
                buyAmt:  (.buyAmount // "0"),
                feeAmt:  (.feeAmount // (if $order then ($order.executedFeeAmount // $order.executedSurplusFee // "0") else "0" end)),
                txHash:  (.txHash // ""),
                chain:   (._chain // (if $order then $order._chain else null end)),
                explorer:(._explorer // (if $order then $order._explorer else null end))
            }
        elif $order then
            {
                sellAmt: ($order.executedSellAmount // "0"),
                buyAmt:  ($order.executedBuyAmount // "0"),
                feeAmt:  ($order.executedFeeAmount // $order.executedSurplusFee // "0"),
                txHash:  "",
                chain:   $order._chain,
                explorer:$order._explorer
            }
        else empty
        end) |

        . as $fill |
        {
            date:      (if $order then ($order.creationDate // "") else "" end),
            chain:     ($fill.chain // "unknown"),
            kind:      (if $order then ($order.kind // "") else "" end),
            class:     (if $order then ($order.class // "") else "" end),
            sellToken: (if $order then ($order.sellToken // "") else "" end),
            buyToken:  (if $order then ($order.buyToken // "") else "" end),
            sellAmt:   $fill.sellAmt,
            buyAmt:    $fill.buyAmt,
            feeAmt:    $fill.feeAmt,
            txHash:    $fill.txHash,
            explorer:  ($fill.explorer // ""),
            owner:     (if $order then ($order.owner // "") else "" end),
            receiver:  (if $order then ($order.receiver // $order.owner // "") else "" end),
            uid:       $uid,
            partial:   (if $order then ($order.partiallyFillable // false) else false end),
            status:    (if $order then ($order.status // "") else "traded" end)
        }
    ]
    | map(select(.sellAmt != "0" or .buyAmt != "0"))
    | sort_by(.date)[]
    |
    token_info(.chain; .sellToken) as $si |
    token_info(.chain; .buyToken)  as $bi |
    to_human(.sellAmt; $si.d) as $sellH |
    to_human(.buyAmt;  $bi.d) as $buyH  |
    to_human(.feeAmt;  $si.d) as $feeH  |
    (if .txHash != "" and .txHash != null
     then .explorer + "/" + .txHash else "" end) as $expUrl |
    ("https://explorer.cow.fi/orders/" + .uid) as $cowUrl |
    [ .date, .chain, .kind, .class,
      $si.s, .sellToken, $sellH, $bi.s, .buyToken, $buyH, $feeH, $si.s,
      .txHash, $expUrl, $cowUrl,
      .owner, .receiver, .uid,
      (if .partial then "yes" else "no" end),
      .status
    ] | @csv
)
' > "$OUTPUT_CSV"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ROW_COUNT=$(($(wc -l < "$OUTPUT_CSV") - 1))

echo ""
echo "============================================"
echo "  EXPORT COMPLETE"
echo "============================================"
echo "  Address:     ${SHORT_ADDR}"
echo "  Trade rows:  ${ROW_COUNT}"
echo "  File:        ${OUTPUT_CSV}"
echo "  Size:        $(du -h "$OUTPUT_CSV" | cut -f1)"
echo ""
echo "  Per chain:"
tail -n +2 "$OUTPUT_CSV" | cut -d',' -f2 | tr -d '"' | sort | uniq -c | sort -rn | while read cnt ch; do
    printf "    %-12s %s\n" "$ch" "$cnt"
done
echo ""
echo "  CoW Explorer: https://explorer.cow.fi/address/${ADDRESS}"
echo "============================================"
echo "  Moo! Happy tax season.  (o)~"
echo ""
