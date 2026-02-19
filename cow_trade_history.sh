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
# Token map — native tokens (offline fallback) + dynamic token lists
# ---------------------------------------------------------------------------
TOKEN_FILE=$(mktemp)

# Native/gas tokens per chain (not in ERC-20 token lists, 0xeee...eee)
cat > "$TOKEN_FILE" << 'TOKENEOF'
{
  "ethereum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "gnosis:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"xDAI","d":18},
  "arbitrum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "base:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "avalanche:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"AVAX","d":18},
  "polygon:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"MATIC","d":18},
  "bnb:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"BNB","d":18},
  "linea:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18},
  "lens:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"GHO","d":18},
  "ink:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"s":"ETH","d":18}
}
TOKENEOF

# ---------------------------------------------------------------------------
# Fetch token lists — pulls curated lists from CoW Protocol + CoinGecko
# and merges them into TOKEN_FILE. Falls back gracefully if offline.
#
# Token list format (Uniswap standard):
#   { "tokens": [ { "chainId": 1, "address": "0x...", "symbol": "WETH", "decimals": 18 }, ... ] }
#
# Sources:
#   - https://files.cow.fi/tokens/CowSwap.json       (CoW curated, all chains)
#   - https://files.cow.fi/tokens/CoinGecko.<id>.json (per chain, broad coverage)
# ---------------------------------------------------------------------------

# Convert a standard token list JSON into our chain:addr → {s,d} format
# Reads from file $1, outputs merged JSON to stdout
tokenlist_to_map() {
    local file="$1"
    jq '
        [.tokens[] |
            select(.chainId and .address and .symbol and .decimals) |
            {
                key: ((.chainId | tostring) + ":" + (.address | ascii_downcase)),
                value: { s: .symbol, d: .decimals }
            }
        ] | from_entries
    ' "$file" 2>/dev/null || echo '{}'
}

echo ""
echo "Fetching token lists..."

# Collect all token list URLs
TOKEN_LIST_URLS=(
    "https://files.cow.fi/tokens/CowSwap.json"
)
for cid in "${CHAIN_IDS[@]}"; do
    TOKEN_LIST_URLS+=("https://files.cow.fi/tokens/CoinGecko.${cid}.json")
done

fetched_lists=0
total_tokens_loaded=0

for url in "${TOKEN_LIST_URLS[@]}"; do
    LIST_FILE=$(mktemp)
    list_name="${url##*/}"

    if curl -s --connect-timeout 5 -m 15 -o "$LIST_FILE" "$url" 2>/dev/null \
       && [ -s "$LIST_FILE" ] \
       && jq -e '.tokens | type == "array"' "$LIST_FILE" &>/dev/null; then

        # Convert to our format, replacing chainId with chain name
        MAP_FILE=$(mktemp)
        tokenlist_to_map "$LIST_FILE" > "$MAP_FILE"

        # Replace numeric chainId keys with chain names
        NAMED_FILE=$(mktemp)
        jq '
            to_entries | map(
                (.key | split(":")) as $parts |
                ($parts[0] | tonumber) as $cid |
                (if   $cid == 1     then "ethereum"
                 elif $cid == 100   then "gnosis"
                 elif $cid == 42161 then "arbitrum"
                 elif $cid == 8453  then "base"
                 elif $cid == 43114 then "avalanche"
                 elif $cid == 137   then "polygon"
                 elif $cid == 56    then "bnb"
                 elif $cid == 59144 then "linea"
                 elif $cid == 232   then "lens"
                 elif $cid == 57073 then "ink"
                 else null end) as $name |
                select($name != null) |
                { key: ($name + ":" + $parts[1]), value: .value }
            ) | from_entries
        ' "$MAP_FILE" > "$NAMED_FILE" 2>/dev/null || echo '{}' > "$NAMED_FILE"

        count=$(jq 'length' "$NAMED_FILE" 2>/dev/null || echo 0)
        if [ "$count" -gt 0 ]; then
            # Merge into TOKEN_FILE (new entries don't overwrite existing)
            jq -s '.[1] * .[0]' "$TOKEN_FILE" "$NAMED_FILE" > "${TOKEN_FILE}.tmp" \
                && mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
            total_tokens_loaded=$((total_tokens_loaded + count))
            fetched_lists=$((fetched_lists + 1))
            echo "  + ${list_name}: ${count} tokens"
        fi
        rm -f "$MAP_FILE" "$NAMED_FILE"
    fi
    rm -f "$LIST_FILE"
done

if [ "$fetched_lists" -gt 0 ]; then
    final_count=$(jq 'length' "$TOKEN_FILE" 2>/dev/null || echo 0)
    echo "  => ${final_count} tokens loaded from ${fetched_lists} lists"
else
    echo "  Could not fetch token lists (offline?). Using native tokens only."
    echo "  Unknown tokens will be resolved via on-chain RPC calls."
fi
echo ""

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
