#!/usr/bin/env bash

SNI_FINDER_VERSION="1.0.0"
DEFAULT_COUNT=10
DEFAULT_TIMEOUT=5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_POOL="$SCRIPT_DIR/domains.txt"

usage() {
  cat <<EOF
sni-finder.sh v$SNI_FINDER_VERSION — Find the best SNI for REALITY protocol

Usage:
  $0 [options]

Options:
  -l FILE     Domain pool file (default: ./domains.txt)
  -n NUM      Number of domains to test (default: 10)
  -t SEC      Timeout per test in seconds (default: 5)
  -o FILE     Write JSON output to file (default: stdout)
  -v          Verbose progress on stderr
  -V          Show version
  -h          Show this help
EOF
  exit 0
}

# --- Default built-in domains (fallback if no pool file) ---
BUILTIN_DOMAINS=(
  docker.com hub.docker.com github.io npmjs.com pypi.org
  python.org golang.org rust-lang.org debian.org ubuntu.com
  archlinux.org postgresql.org sqlite.org redis.io apache.org
  nginx.org php.net jsdelivr.com unpkg.com cdnjs.com
  bitbucket.org gitlab.com kernel.org llvm.org godotengine.org
  harvard.edu stanford.edu mit.edu berkeley.edu cam.ac.uk
  ox.ac.uk princeton.edu yale.edu columbia.edu cornell.edu
  nyu.edu ucla.edu washington.edu toronto.edu ethz.ch
  kyoto-u.ac.jp anu.edu.au nus.edu.sg nasa.gov cern.ch
  ieee.org nature.com sciencedirect.com springer.com wiley.com
  wordpress.org wikimedia.org pixabay.com unsplash.com pexels.com
  archive.org mdn.mozilla.org gitter.im readthedocs.io gitbook.com
  latex-project.org w3.org canva.com sketchfab.com artstation.com
  behance.net dribbble.com vimeo.com bandcamp.com soundcloud.com
  digitalocean.com linode.com vultr.com hetzner.com ovhcloud.com
  namecheap.com godaddy.com hostinger.com fastly.com akamai.com
  backblaze.com wasabi.com speedtest.net cloudflarestatus.com
  statuspage.io discourse.org slack.com trello.com zoom.us webex.com
  eff.org fsf.org gnu.org linuxfoundation.org ietf.org
  icann.org openstreetmap.org creativecommons.org ted.com gutenberg.org
)

# --- Parse arguments ---
POOL_FILE="$DEFAULT_POOL"
COUNT="$DEFAULT_COUNT"
TIMEOUT="$DEFAULT_TIMEOUT"
OUTPUT_FILE=""
VERBOSE=false

while getopts "l:n:t:o:vVh" opt; do
  case $opt in
    l) POOL_FILE="$OPTARG" ;;
    n) COUNT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    v) VERBOSE=true ;;
    V) echo "sni-finder.sh v$SNI_FINDER_VERSION"; exit 0 ;;
    h) usage ;;
    *) usage ;;
  esac
done

log() { $VERBOSE && echo "[*] $*" >&2; }

# --- Load domain pool ---
load_pool() {
  local file="$1"
  if [[ -f "$file" ]]; then
    mapfile -t pool < <(grep -vE '^\s*(#|$)' "$file" | tr -d '\r' | sed '/^$/d')
    if [[ ${#pool[@]} -eq 0 ]]; then
      log "Pool file '$file' is empty, using built-in defaults"
      pool=("${BUILTIN_DOMAINS[@]}")
    fi
  else
    log "Pool file '$file' not found, using built-in defaults"
    pool=("${BUILTIN_DOMAINS[@]}")
  fi
}

# --- Randomly select N domains ---
pick_random() {
  local n="$1"
  shift
  local arr=("$@")
  if [[ ${#arr[@]} -le "$n" ]]; then
    echo "${arr[@]}"
    return
  fi
  if command -v shuf &>/dev/null; then
    printf '%s\n' "${arr[@]}" | shuf -n "$n" | tr '\n' ' '
  elif command -v sort &>/dev/null; then
    printf '%s\n' "${arr[@]}" | sort -R | head -n "$n" | tr '\n' ' '
  else
    # Fallback: Fisher-Yates-ish shuffle in pure bash
    local idx selected=()
    for ((i = ${#arr[@]} - 1; i >= 0; i--)); do
      idx=$((RANDOM % (i + 1)))
      selected+=("${arr[idx]}")
      arr[idx]="${arr[i]}"
      [[ ${#selected[@]} -eq "$n" ]] && break
    done
    echo "${selected[@]}"
  fi
}

# --- Test a single domain ---
test_domain() {
  local domain="$1"
  local result

  log "Testing: $domain"

  # --- DNS resolution time ---
  local dns_ms=-1 dns_ok=false
  local dns_start dns_end
  dns_start=$(date +%s%N 2>/dev/null)
  host_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  dns_end=$(date +%s%N 2>/dev/null)
  if [[ -z "$host_ip" ]]; then
    host_ip=$(ping -c 1 -W 1 "$domain" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    dns_end=$(date +%s%N 2>/dev/null)
  fi
  if [[ -n "$host_ip" ]]; then
    dns_ok=true
    dns_ms=$(( (dns_end - dns_start) / 1000000 ))
  fi

  # --- TCP + TLS test ---
  local reachable=false
  local tls_version=""
  local tls_ms=-1
  local cert_size=0
  local cert_chain_len=0
  local key_type=""
  local issuer=""

  if $dns_ok; then
    local tls_start tls_end
    tls_start=$(date +%s%N)
    raw=$(timeout "$TIMEOUT" openssl s_client -connect "$domain:443" -servername "$domain" -showcerts 2>/dev/null < /dev/null)
    tls_end=$(date +%s%N)

    if [[ -n "$raw" ]] && echo "$raw" | grep -qi "BEGIN CERTIFICATE"; then
      reachable=true
      tls_ms=$(( (tls_end - tls_start) / 1000000 ))

      # TLS version
      tls_version=$(echo "$raw" | grep -i "^New, TLS" | head -1 | sed 's/New, //' | sed 's/, Cipher.*//')

      # Cert chain size & length
      local certs
      certs=$(echo "$raw" | awk '/-----BEGIN CERTIFICATE-----/{flag=1} flag; /-----END CERTIFICATE-----/{if(flag) flag=0; print ""}' 2>/dev/null)
      if [[ -n "$certs" ]]; then
        cert_size=$(echo "$certs" | wc -c)
        cert_chain_len=$(echo "$certs" | grep -c "BEGIN CERTIFICATE")
      fi

      # Key type from leaf cert
      local leaf_cert
      leaf_cert=$(echo "$raw" | awk '/-----BEGIN CERTIFICATE-----/{if(!found) flag=1; found=1} flag; /-----END CERTIFICATE-----/{if(flag) flag=0; print ""}' 2>/dev/null)
      if [[ -n "$leaf_cert" ]]; then
        local key_text
        key_text=$(echo "$leaf_cert" | openssl x509 -noout -text 2>/dev/null)
        if [[ -n "$key_text" ]]; then
          key_type=$(echo "$key_text" | grep -i "Public Key Algorithm" | head -1 | sed 's/.*: //' | sed 's/^ *//')
          issuer=$(echo "$key_text" | grep -i "Issuer:" | head -1 | sed 's/.*Issuer: //' | sed 's/^ *//' | cut -d',' -f1)
        fi
      fi
    fi
  fi

  # --- Ping latency ---
  local ping_ms=-1
  if command -v ping &>/dev/null && [[ -n "$host_ip" ]]; then
    ping_output=$(timeout 3 ping -c 1 -W 2 "$domain" 2>/dev/null)
    if [[ -n "$ping_output" ]]; then
      ping_ms=$(echo "$ping_output" | tail -1 | awk -F'/' '{print $5}' | tr -d ' ' | sed 's/\..*//')
      if [[ -z "$ping_ms" || "$ping_ms" == "0" ]]; then
        ping_ms=$(echo "$ping_output" | grep -oE 'time=[0-9.]+ ms' | grep -oE '[0-9.]+' | head -1 | sed 's/\..*//')
      fi
    fi
    [[ -z "$ping_ms" ]] && ping_ms=-1
  fi

  # --- Normalize key type for scoring ---
  local key_class=""
  if [[ -z "$key_type" ]]; then
    key_class="unknown"
  elif echo "$key_type" | grep -qi "ecdsa\|id-ecPublicKey\|prime256v1\|secp384r1\|ec\b"; then
    key_class="ECDSA"
  elif echo "$key_type" | grep -qi "rsaEncryption\|rsa\b"; then
    key_class="RSA"
  else
    key_class="other"
  fi

  echo "$domain|$reachable|$tls_version|$tls_ms|$ping_ms|$cert_size|$cert_chain_len|$key_class|$key_type|$issuer|$dns_ms"
}

# --- Scoring ---
score_domains() {
  local -n data="$1"
  local -a scores=()
  local total=${#data[@]}

  # --- Collect values for relative scoring ---
  local min_latency=999999 max_latency=0
  local min_dns=999999 max_dns=0
  local min_certsize=999999 max_certsize=0

  for row in "${data[@]}"; do
    IFS='|' read -r domain reachable tls_version tls_ms ping_ms cert_size chain_len key_class key_type issuer dns_ms <<< "$row"

    if [[ "$reachable" == "true" ]]; then
      local total_ms=$(( (tls_ms > 0 ? tls_ms : 0) + (ping_ms > 0 ? ping_ms : 0) ))
      [[ $total_ms -lt $min_latency ]] && min_latency=$total_ms
      [[ $total_ms -gt $max_latency ]] && max_latency=$total_ms
    fi

    [[ $dns_ms -ge 0 && $dns_ms -lt $min_dns ]] && min_dns=$dns_ms
    [[ $dns_ms -gt $max_dns ]] && max_dns=$dns_ms
    [[ $cert_size -gt 0 && $cert_size -lt $min_certsize ]] && min_certsize=$cert_size
    [[ $cert_size -gt $max_certsize ]] && max_certsize=$cert_size
  done

  [[ $min_latency -eq 999999 ]] && min_latency=0
  [[ $max_latency -eq 0 ]] && max_latency=1
  [[ $min_dns -eq 999999 ]] && min_dns=0
  [[ $max_dns -eq 0 ]] && max_dns=1
  [[ $min_certsize -eq 999999 ]] && min_certsize=0
  [[ $max_certsize -eq 0 ]] && max_certsize=1

  local latency_range=$(( max_latency - min_latency ))
  local dns_range=$(( max_dns - min_dns ))
  local certsize_range=$(( max_certsize - min_certsize ))
  [[ $latency_range -eq 0 ]] && latency_range=1
  [[ $dns_range -eq 0 ]] && dns_range=1
  [[ $certsize_range -eq 0 ]] && certsize_range=1

  for row in "${data[@]}"; do
    IFS='|' read -r domain reachable tls_version tls_ms ping_ms cert_size chain_len key_class key_type issuer dns_ms <<< "$row"

    local score=0

    # 1. connectivity (25%)
    if [[ "$reachable" == "true" ]]; then
      score=$(( score + 25 ))
    fi

    # 2. latency (20%) - relative
    if [[ "$reachable" == "true" ]]; then
      local total_ms=$(( (tls_ms > 0 ? tls_ms : 0) + (ping_ms > 0 ? ping_ms : 0) ))
      local lat_raw=$(( (total_ms - min_latency) * 100 / latency_range ))
      local lat_score=$(( 20 - (lat_raw * 20 / 100) ))
      [[ $lat_score -lt 0 ]] && lat_score=0
      score=$(( score + lat_score ))
    fi

    # 3. TLS version (15%)
    if echo "$tls_version" | grep -qi "TLSv1\.3\|TLS 1\.3"; then
      score=$(( score + 15 ))
    elif echo "$tls_version" | grep -qi "TLSv1\.2\|TLS 1\.2"; then
      score=$(( score + 7 ))
    fi

    # 4. Cert size (15%) - relative
    if [[ $cert_size -gt 0 ]]; then
      local csize_raw=$(( (cert_size - min_certsize) * 100 / certsize_range ))
      local csize_score=$(( 15 - (csize_raw * 15 / 100) ))
      [[ $csize_score -lt 0 ]] && csize_score=0
      score=$(( score + csize_score ))
    fi

    # 5. Key type (15%)
    case "$key_class" in
      ECDSA) score=$(( score + 15 )) ;;
      RSA)   score=$(( score + 10 )) ;;
      *)     score=$(( score + 3 )) ;;
    esac

    # 6. DNS (10%) - relative
    if [[ $dns_ms -ge 0 ]]; then
      local dns_raw=$(( (dns_ms - min_dns) * 100 / dns_range ))
      local dns_score=$(( 10 - (dns_raw * 10 / 100) ))
      [[ $dns_score -lt 0 ]] && dns_score=0
      score=$(( score + dns_score ))
    fi

    scores+=("$score|$domain|$reachable|$tls_version|$tls_ms|$ping_ms|$cert_size|$chain_len|$key_class|$issuer|$dns_ms")
  done

  # Sort by score descending
  IFS=$'\n' sorted=($(sort -t'|' -k1 -rn <<< "${scores[*]}"))
  echo "${sorted[@]}"
}

# --- JSON escape ---
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  echo "$s"
}

# --- Output JSON ---
output_json() {
  local -n results="$1"
  local best_sni="$2"
  local pool_size="$3"
  local sample_size="$4"

  local json="{\n"
  json+="  \"tool\": \"sni-finder.sh\",\n"
  json+="  \"version\": \"$SNI_FINDER_VERSION\",\n"
  json+="  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\n"
  json+="  \"best_sni\": \"$(json_escape "$best_sni")\",\n"
  json+="  \"pool_size\": $pool_size,\n"
  json+="  \"sample_size\": $sample_size,\n"
  json+="  \"results\": [\n"

  local first=true
  for row in "${results[@]}"; do
    IFS='|' read -r score domain reachable tls_version tls_ms ping_ms cert_size chain_len key_class issuer dns_ms <<< "$row"

    $first && first=false || json+=",\n"
    json+="    {\n"
    json+="      \"sni\": \"$(json_escape "$domain")\",\n"
    json+="      \"score\": $score,\n"
    json+="      \"reachable\": $reachable,\n"
    json+="      \"tls_version\": \"$(json_escape "$tls_version")\",\n"
    json+="      \"tls_ms\": $tls_ms,\n"
    json+="      \"ping_ms\": $ping_ms,\n"
    json+="      \"cert_size_bytes\": $cert_size,\n"
    json+="      \"cert_chain_len\": $chain_len,\n"
    json+="      \"key_type\": \"$(json_escape "$key_class")\",\n"
    json+="      \"issuer\": \"$(json_escape "$issuer")\",\n"
    json+="      \"dns_ms\": $dns_ms\n"
    json+="    }"
  done

  json+="\n  ]\n}\n"

  echo -e "$json"
}

# --- Main ---
main() {
  load_pool "$POOL_FILE"

  local pool_size=${#pool[@]}
  if [[ $pool_size -eq 0 ]]; then
    echo '{"error": "No domains in pool"}' >&2
    exit 1
  fi

  local sample_size=$COUNT
  [[ $sample_size -gt $pool_size ]] && sample_size=$pool_size

  log "Pool: $pool_size domains, testing: $sample_size"

  # Randomly select domains
  read -ra selected <<< "$(pick_random "$sample_size" "${pool[@]}")"
  log "Selected: ${selected[*]}"

  # Test each domain
  local raw_results=()
  for domain in "${selected[@]}"; do
    raw_results+=("$(test_domain "$domain")")
  done

  # Score and sort
  IFS=' ' read -ra scored <<< "$(score_domains raw_results)"

  # Get best SNI
  IFS='|' read -r best_score best_sni best_reachable _ <<< "${scored[0]}"

  # Output
  if [[ -n "$OUTPUT_FILE" ]]; then
    output_json scored "$best_sni" "$pool_size" "$sample_size" > "$OUTPUT_FILE"
    echo "Results written to: $OUTPUT_FILE"
  else
    output_json scored "$best_sni" "$pool_size" "$sample_size"
  fi

  # Summary
  if [[ "$best_reachable" == "true" ]]; then
    echo "---" >&2
    echo ">>> Best SNI: $best_sni (score: $best_score) <<<" >&2
  else
    echo "---" >&2
    echo ">>> No reachable domain found. Best effort: $best_sni (score: $best_score) <<<" >&2
  fi
}

main
