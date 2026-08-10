#!/usr/bin/env bash

SNI_FINDER_VERSION="1.0.0"
DEFAULT_COUNT=15
DEFAULT_TIMEOUT=5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_POOL="$SCRIPT_DIR/domains.txt"

usage() {
  cat <<EOF
sni-finder.sh v$SNI_FINDER_VERSION — Find the best SNI for REALITY protocol

Usage:
  $0 [options] [domain1 domain2 ...]

Options:
  -l FILE     Domain pool file (default: ./domains.txt)
  -n NUM      Number of domains to test (default: 15)
  -t SEC      Timeout per test in seconds (default: 5)
  -o FILE     Write JSON output to file (default: stdout)
  -y          Auto-apply best SNI to Xray config (no menu)
  -v          Verbose progress on stderr
  -V          Show version
  -h          Show this help
  --xray-config PATH  Specify Xray config file path
  --no-menu   Skip interactive menu, just output
  --max-latency MS    Max latency for scoring (default: 300ms)

Examples:
  $0                          Random 15 domains from pool
  $0 -n 5                    Random 5 domains
  $0 example.com foo.org     Test specific domains
  $0 -y --xray-config /etc/xray/config.json  Auto-apply
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

# --- Cloudflare IP ranges (official: https://www.cloudflare.com/ips-v4, /ips-v6) ---
# Script fetches fresh lists at runtime; these are offline fallbacks.
CLOUDFLARE_IPV4_RANGES=(
  "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
  "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
  "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
  "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22"
)
CLOUDFLARE_IPV6_RANGES=(
  "2400:cb00::/32" "2606:4700::/32" "2803:f800::/32"
  "2405:b500::/32" "2405:8100::/32" "2a06:98c0::/29" "2c0f:f248::/32"
  "2c00:f080::/32"
)

# --- Refresh CF ranges from official lists (silent fallback to built-ins) ---
refresh_cloudflare_ranges() {
  local v4 v6
  v4=$(curl -fsSL --max-time 5 https://www.cloudflare.com/ips-v4 2>/dev/null | grep -E '^[0-9]+\.' | tr -d '\r')
  v6=$(curl -fsSL --max-time 5 https://www.cloudflare.com/ips-v6 2>/dev/null | grep -E '^[0-9a-fA-F]+:' | tr -d '\r')
  if [[ -n "$v4" ]]; then
    mapfile -t CLOUDFLARE_IPV4_RANGES <<< "$v4"
  fi
  if [[ -n "$v6" ]]; then
    mapfile -t CLOUDFLARE_IPV6_RANGES <<< "$v6"
  fi
}

# --- GeoIP: country code for an IP (ip.im primary, ip-api.com fallback) ---
geoip_country() {
  local ip="$1"
  local resp
  resp=$(curl -fsSL --max-time 4 "https://ip.im/$ip" 2>/dev/null | grep -i "^Country:" | head -1 | awk '{print $2}' | tr -d '\r')
  if [[ -z "$resp" ]]; then
    resp=$(curl -fsSL --max-time 4 "http://ip-api.com/json/$ip?fields=status,countryCode" 2>/dev/null | grep -o '"countryCode":"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d '\r')
  fi
  echo "${resp:-UNKNOWN}"
}

# --- ISO 3166-1 alpha-2 -> country name (common set) ---
country_name() {
  local code="${1^^}"
  case "$code" in
    AD) echo "Andorra";; AE) echo "UAE";; AR) echo "Argentina";; AT) echo "Austria";;
    AU) echo "Australia";; BE) echo "Belgium";; BG) echo "Bulgaria";; BR) echo "Brazil";;
    CA) echo "Canada";; CH) echo "Switzerland";; CN) echo "China";; CY) echo "Cyprus";;
    CZ) echo "Czechia";; DE) echo "Germany";; DK) echo "Denmark";; EE) echo "Estonia";;
    ES) echo "Spain";; FI) echo "Finland";; FR) echo "France";; GB) echo "United Kingdom";;
    GR) echo "Greece";; HK) echo "Hong Kong";; HR) echo "Croatia";; HU) echo "Hungary";;
    ID) echo "Indonesia";; IE) echo "Ireland";; IL) echo "Israel";; IN) echo "India";;
    IS) echo "Iceland";; IT) echo "Italy";; JP) echo "Japan";; KR) echo "South Korea";;
    LT) echo "Lithuania";; LU) echo "Luxembourg";; LV) echo "Latvia";; MD) echo "Moldova";;
    MX) echo "Mexico";; MY) echo "Malaysia";; NL) echo "Netherlands";; NO) echo "Norway";;
    NZ) echo "New Zealand";; PH) echo "Philippines";; PL) echo "Poland";; PT) echo "Portugal";;
    RO) echo "Romania";; RS) echo "Serbia";; RU) echo "Russia";; SE) echo "Sweden";;
    SG) echo "Singapore";; SI) echo "Slovenia";; SK) echo "Slovakia";; TH) echo "Thailand";;
    TR) echo "Turkey";; TW) echo "Taiwan";; UA) echo "Ukraine";; US) echo "United States";;
    VN) echo "Vietnam";; ZA) echo "South Africa";;
    *) echo "$code";;
  esac
}

# --- Parse arguments ---
POOL_FILE="$DEFAULT_POOL"
COUNT="$DEFAULT_COUNT"
TIMEOUT="$DEFAULT_TIMEOUT"
OUTPUT_FILE=""
VERBOSE=false
AUTO_APPLY=false
NO_MENU=false
XRAY_CONFIG=""
MAX_LATENCY_MS=300

# Parse long options first
LONGOPTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --xray-config) XRAY_CONFIG="$2"; shift 2 ;;
    --no-menu) NO_MENU=true; shift ;;
    --max-latency) MAX_LATENCY_MS="$2"; shift 2 ;;
    --) shift; break ;;
    *) LONGOPTS+=("$1"); shift ;;
  esac
done
set -- "${LONGOPTS[@]}"

while getopts "l:n:t:o:yvVh" opt; do
  case $opt in
    l) POOL_FILE="$OPTARG" ;;
    n) COUNT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    y) AUTO_APPLY=true ;;
    v) VERBOSE=true ;;
    V) echo "sni-finder.sh v$SNI_FINDER_VERSION"; exit 0 ;;
    h) usage ;;
    *) usage ;;
  esac
done

log() { $VERBOSE && echo "[*] $*" >&2; }

# Collect positional args as specific domains to test
shift $((OPTIND - 1))
SPECIFIC_DOMAINS=("$@")

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

# --- Resolve all A/AAAA records for a domain ---
# Sets global CF_IPV4_LIST and CF_IPV6_LIST (space separated)
resolve_host_ips() {
  local domain="$1"
  CF_IPV4_LIST=""
  CF_IPV6_LIST=""

  local records
  records=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
  if [[ -z "$records" ]]; then
    records=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
  fi

  local ip
  for ip in $records; do
    # Skip IPv4-mapped IPv6 (::ffff:a.b.c.d) — it's an IPv4 in disguise
    if [[ "$ip" == "::ffff:"* ]]; then
      CF_IPV4_LIST="$CF_IPV4_LIST ${ip#::ffff:}"
    elif [[ "$ip" == *":"* ]]; then
      CF_IPV6_LIST="$CF_IPV6_LIST $ip"
    else
      CF_IPV4_LIST="$CF_IPV4_LIST $ip"
    fi
  done
}

# --- Check if an IPv4 is inside Cloudflare ranges (pure awk, no bitwise ops) ---
is_cloudflare_ipv4() {
  local ip="$1"
  local ranges="${CLOUDFLARE_IPV4_RANGES[*]}"
  awk -v ip="$ip" -v ranges="$ranges" '
    function ip2int(a,  o){
      split(a, o, ".");
      return o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4];
    }
    BEGIN {
      n = ip2int(ip);
      split(ranges, r, " ");
      for (i in r) {
        split(r[i], p, "/");
        prefix = p[2] + 0;
        block = 2^(32 - prefix);
        net = ip2int(p[1]) - (ip2int(p[1]) % block);
        if (n >= net && n < net + block) exit 0;
      }
      exit 1;
    }'
}

# --- Check if an IPv6 is inside Cloudflare ranges (hex string comparison) ---
is_cloudflare_ipv6() {
  local ip="$1"
  local ranges="${CLOUDFLARE_IPV6_RANGES[*]}"
  awk -v ip="$ip" -v ranges="$ranges" '
    function hexval(c){
      return index("0123456789abcdef", tolower(c)) - 1;
    }
    function strtonum16(s,  v, i, c) {
      v = 0;
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1);
        v = v * 16 + hexval(c);
      }
      return v;
    }
    function ip6hex(a,  out, parts, head, tail, hg, tg, nhead, ntail, i, cnt) {
      # Expand compressed IPv6 into 32 hex chars
      if (a == "::") { return "00000000000000000000000000000000" }
      split(a, parts, "::");
      head = parts[1]; tail = (length(parts) > 1) ? parts[2] : "";
      nhead = (head == "") ? 0 : split(head, hg, ":");
      ntail = (tail == "") ? 0 : split(tail, tg, ":");
      out = "";
      for (i = 1; i <= nhead; i++) out = out sprintf("%04x", strtonum16(hg[i]));
      cnt = 8 - nhead - ntail;
      for (i = 1; i <= cnt; i++) out = out "0000";
      for (i = 1; i <= ntail; i++) out = out sprintf("%04x", strtonum16(tg[i]));
      return out;
    }
    BEGIN {
      target = ip6hex(ip);
      split(ranges, r, " ");
      for (i in r) {
        split(r[i], p, "/");
        nethex = ip6hex(p[1]);
        prefix = p[2] + 0;
        full = int(prefix / 4);
        rem = prefix % 4;
        if (substr(target, 1, full) != substr(nethex, 1, full)) continue;
        if (rem > 0) {
          a = hexval(substr(target, full + 1, 1));
          b = hexval(substr(nethex, full + 1, 1));
          shift = 4 - rem;
          if (int(a / (16 ^ shift)) != int(b / (16 ^ shift))) continue;
        }
        exit 0;
      }
      exit 1;
    }'
}

# --- Test a single domain ---
test_domain() {
  local domain="$1"

  # --- DNS resolution ---
  local dns_ms=-1 dns_ok=false
  local dns_start dns_end
  dns_start=$(date +%s%N 2>/dev/null)
  resolve_host_ips "$domain"
  dns_end=$(date +%s%N 2>/dev/null)

  if [[ -n "$CF_IPV4_LIST" || -n "$CF_IPV6_LIST" ]]; then
    dns_ok=true
    dns_ms=$(( (dns_end - dns_start) / 1000000 ))
  fi

  # --- Cloudflare CDN check (skip all tests if hosted on CF) ---
  local cf=false
  if $dns_ok; then
    local ip
    for ip in $CF_IPV4_LIST; do
      if is_cloudflare_ipv4 "$ip"; then
        cf=true
        break
      fi
    done
    if [[ "$cf" != "true" ]]; then
      for ip in $CF_IPV6_LIST; do
        if is_cloudflare_ipv6 "$ip"; then
          cf=true
          break
        fi
      done
    fi
    if [[ "$cf" == "true" ]]; then
      # Cloudflare-hosted: score 0, skip all tests, move to next domain
      # domain|cf|reachable|cert_valid|tls|tls_ms|ping_ms|cert_size|chain_len|key_class|key_type|issuer|dns_ms|alpn|kex
      echo "$domain|true|false|false||-1|-1|0|0|unknown|||$dns_ms|none|other" | tr -d '\r'
      return 0
    fi
  fi

  # --- TCP + TLS ---
  local reachable=false tls_version="" tls_ms=-1
  local cert_size=0 cert_chain_len=0 key_type="" issuer=""
  local alpn="" kex=""
  local cert_valid=false

  if $dns_ok; then
    local tls_start tls_end raw
    tls_start=$(date +%s%N)
    raw=$(timeout "$TIMEOUT" openssl s_client -connect "$domain:443" -servername "$domain" -showcerts -alpn h2,http/1.1 -msg -verify_hostname "$domain" 2>&1 < /dev/null)
    tls_end=$(date +%s%N)

    if [[ "$raw" == *"BEGIN CERTIFICATE"* ]]; then
      reachable=true
      tls_ms=$(( (tls_end - tls_start) / 1000000 ))

      # Certificate chain trusted + hostname matches (aligned with 3x-ui CertValid)
      if [[ "$raw" == *"Verify return code: 0 (ok)"* ]]; then
        cert_valid=true
      fi

      # TLS version
      tls_version=$(sed -n '/^New, TLS/{s/New, //; s/, Cipher.*//p; q}' <<< "$raw")

      # ALPN negotiation (h2 / http/1.1)
      alpn=$(grep -i "ALPN protocol" <<< "$raw" | head -1 | sed 's/.*ALPN protocol: *//' | tr -d '\n\r')

      # Key exchange: TLS 1.3 via -msg (Negotiated TLS1.3 group), TLS 1.2 via Server Temp Key
      kex=$(grep -i "Negotiated TLS1.3 group" <<< "$raw" | head -1 | sed 's/.*group: *//' | tr -d '\n\r')
      if [[ -z "$kex" ]]; then
        kex=$(grep -i "Server Temp Key" <<< "$raw" | head -1 | sed 's/.*Key: *//' | awk '{print $1}' | tr -d '\n\r')
      fi

      # Certificate chain
      local certs
      certs=$(awk '/-----BEGIN CERTIFICATE-----/{flag=1} flag; /-----END CERTIFICATE-----/{flag=0; print ""}' <<< "$raw" 2>/dev/null)
      if [[ -n "$certs" ]]; then
        cert_size=$(wc -c <<< "$certs")
        cert_chain_len=$(grep -c "BEGIN CERTIFICATE" <<< "$certs")
      fi

      # Key type from leaf cert
      local leaf_cert
      leaf_cert=$(awk '/-----BEGIN CERTIFICATE-----/{if(!found) flag=1; found=1} flag; /-----END CERTIFICATE-----/{flag=0; print ""}' <<< "$raw" 2>/dev/null)
      if [[ -n "$leaf_cert" ]]; then
        local key_text
        key_text=$(openssl x509 -noout -text <<< "$leaf_cert" 2>/dev/null)
        if [[ -n "$key_text" ]]; then
          key_type=$(grep -i "Public Key Algorithm" <<< "$key_text" | head -1 | sed 's/.*: *//' | tr -d '\n\r')
          issuer=$(grep -i "^[[:space:]]*Issuer:" <<< "$key_text" | head -1 | sed 's/.*Issuer: *//' | cut -d',' -f1 | tr -d '\n\r')
        fi
      fi
    fi
  fi

  # --- Ping ---
  local ping_ms=-1
  if command -v ping &>/dev/null && [[ -n "$CF_IPV4_LIST" ]]; then
    local ping_output
    ping_output=$(timeout 3 ping -c 1 -W 2 "$domain" 2>/dev/null)
    if [[ -n "$ping_output" ]]; then
      ping_ms=$(tail -1 <<< "$ping_output" | awk -F'/' '{print $5}' | sed 's/^ *//; s/\..*//; s/ //g')
      if [[ -z "$ping_ms" || "$ping_ms" == "0" ]]; then
        ping_ms=$(grep -oE 'time=[0-9.]+' <<< "$ping_output" | head -1 | grep -oE '[0-9.]+' | sed 's/\..*//')
      fi
    fi
    [[ -z "$ping_ms" ]] && ping_ms=-1
  fi

  # --- Normalize key type ---
  local key_class
  if [[ -z "$key_type" ]]; then
    key_class="unknown"
  elif [[ "${key_type,,}" =~ ecdsa|id-ecpublickey|prime256v1|secp384r1|^ec$ ]]; then
    key_class="ECDSA"
  elif [[ "${key_type,,}" =~ rsa ]]; then
    key_class="RSA"
  else
    key_class="other"
  fi

  # --- Normalize ALPN ---
  local alpn_class
  if [[ "$alpn" == *"h2"* ]]; then
    alpn_class="h2"
  elif [[ "$alpn" == *"http/1.1"* ]]; then
    alpn_class="http1.1"
  else
    alpn_class="none"
  fi

  # --- Normalize key exchange ---
  local kex_class
  if [[ "$kex" == *"X25519MLKEM768"* || "$kex" == *"X25519Kyber768"* ]]; then
    kex_class="MLKEM768"
  elif [[ "$kex" == *"X25519"* ]]; then
    kex_class="X25519"
  elif [[ "$kex" == *"ECDHE"* || "$kex" == *"P-256"* || "$kex" == *"P-384"* ]]; then
    kex_class="ECDHE"
  else
    kex_class="other"
  fi

  echo "$domain|$cf|$reachable|$cert_valid|$tls_version|$tls_ms|$ping_ms|$cert_size|$cert_chain_len|$key_class|$key_type|$issuer|$dns_ms|$alpn_class|$kex_class" | tr -d '\r'
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
    # Skip entries with no pipe delimiters (corrupted data)
    [[ "$row" != *"|"* ]] && continue

    IFS='|' read -r domain cf reachable cert_valid tls_version tls_ms ping_ms cert_size chain_len key_class key_type issuer dns_ms alpn_class kex_class <<< "$row"

    # Skip entries with empty domain or Cloudflare-hosted (score 0)
    [[ -z "$domain" || "$domain" =~ ^[0-9]+$ ]] && continue
    [[ "$cf" == "true" ]] && continue

    if [[ "$reachable" == "true" ]]; then
      local total_ms=$(( (tls_ms > 0 ? tls_ms : 0) + (ping_ms > 0 ? ping_ms : 0) ))
      # Only collect latency for relative scoring if under the cap
      if [[ $total_ms -le $MAX_LATENCY_MS ]]; then
        [[ $total_ms -lt $min_latency ]] && min_latency=$total_ms
        [[ $total_ms -gt $max_latency ]] && max_latency=$total_ms
      fi
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
    IFS='|' read -r domain cf reachable cert_valid tls_version tls_ms ping_ms cert_size chain_len key_class key_type issuer dns_ms alpn_class kex_class <<< "$row"

    [[ -z "$domain" || "$domain" =~ ^[0-9]+$ ]] && continue
    [[ "$reachable" != "true" && "$reachable" != "false" ]] && continue

    local score=0

    # Cloudflare-hosted: exclude entirely, no output
    if [[ "$cf" == "true" ]]; then
      continue
    fi

    # Certificate not trusted for SNI: exclude entirely (aligned with 3x-ui Feasible)
    if [[ "$reachable" == "true" && "$cert_valid" != "true" ]]; then
      continue
    fi

    # 1. connectivity (25%)
    if [[ "$reachable" == "true" ]]; then
      score=$(( score + 25 ))
    fi

    # 2. latency (20%) - relative, 0 if over cap
    if [[ "$reachable" == "true" ]]; then
      local total_ms=$(( (tls_ms > 0 ? tls_ms : 0) + (ping_ms > 0 ? ping_ms : 0) ))
      if [[ $total_ms -le $MAX_LATENCY_MS ]]; then
        local lat_raw=$(( (total_ms - min_latency) * 100 / latency_range ))
        local lat_score=$(( 20 - (lat_raw * 20 / 100) ))
        [[ $lat_score -lt 0 ]] && lat_score=0
        score=$(( score + lat_score ))
      fi
    fi

    # 3. TLS version (12%)
    if [[ "${tls_version,,}" == *"tlsv1.3"* || "${tls_version,,}" == *"tls 1.3"* ]]; then
      score=$(( score + 12 ))
    elif [[ "${tls_version,,}" == *"tlsv1.2"* || "${tls_version,,}" == *"tls 1.2"* ]]; then
      score=$(( score + 3 ))
    fi

    # 4. ALPN h2 (8%)
    case "$alpn_class" in
      h2)       score=$(( score + 8 )) ;;
      http1.1)  score=$(( score + 3 )) ;;
      *)        score=$(( score + 0 )) ;;
    esac

    # 5. Key exchange (10%)
    case "$kex_class" in
      MLKEM768) score=$(( score + 10 )) ;;
      X25519)   score=$(( score + 7 )) ;;
      ECDHE)    score=$(( score + 4 )) ;;
      *)        score=$(( score + 1 )) ;;
    esac

    # 6. Cert size (10%) - relative
    if [[ $cert_size -gt 0 ]]; then
      local csize_raw=$(( (cert_size - min_certsize) * 100 / certsize_range ))
      local csize_score=$(( 10 - (csize_raw * 10 / 100) ))
      [[ $csize_score -lt 0 ]] && csize_score=0
      score=$(( score + csize_score ))
    fi

    # 7. Key type (10%)
    case "$key_class" in
      ECDSA) score=$(( score + 10 )) ;;
      RSA)   score=$(( score + 6 )) ;;
      *)     score=$(( score + 2 )) ;;
    esac

    # 8. DNS (5%) - relative
    if [[ $dns_ms -ge 0 ]]; then
      local dns_raw=$(( (dns_ms - min_dns) * 100 / dns_range ))
      local dns_score=$(( 5 - (dns_raw * 5 / 100) ))
      [[ $dns_score -lt 0 ]] && dns_score=0
      score=$(( score + dns_score ))
    fi

    scores+=("$score|$domain|$cf|$reachable|$cert_valid|$tls_version|$tls_ms|$ping_ms|$cert_size|$chain_len|$key_class|$issuer|$dns_ms|$alpn_class|$kex_class")
  done

  # Sort by score descending
  mapfile -t sorted < <(printf '%s\n' "${scores[@]}" | sort -t'|' -k1 -rn)
  printf '%s\n' "${sorted[@]}"
}

# --- JSON escape ---
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//|/-}"
  printf '%s' "$s" | tr -dc '[:print:]'
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
    IFS='|' read -r score domain cf reachable cert_valid tls_version tls_ms ping_ms cert_size chain_len key_class issuer dns_ms alpn_class kex_class <<< "$row"

    # Skip corrupted entries in output
    [[ -z "$domain" || "$domain" =~ ^[0-9]+$ ]] && continue
    [[ "$reachable" != "true" && "$reachable" != "false" ]] && continue
    [[ ! "$score" =~ ^[0-9]+$ ]] && continue

    $first && first=false || json+=",\n"
    json+="    {\n"
    json+="      \"sni\": \"$(json_escape "$domain")\",\n"
    json+="      \"score\": $score,\n"
    json+="      \"reachable\": $reachable,\n"
    json+="      \"cloudflare\": $cf,\n"
    json+="      \"cert_valid\": $cert_valid,\n"
    json+="      \"tls_version\": \"$(json_escape "$tls_version")\",\n"
    json+="      \"alpn\": \"$(json_escape "$alpn_class")\",\n"
    json+="      \"kex\": \"$(json_escape "$kex_class")\",\n"
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

  printf '%b\n' "$json"
}

# --- Find Xray config file ---
find_xray_config() {
  local paths=(
    "/usr/local/etc/xray/config.json"
    "/etc/xray/config.json"
    "/opt/xray/config.json"
    "/usr/local/etc/v2ray/config.json"
    "/etc/v2ray/config.json"
  )
  for p in "${paths[@]}"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# --- Apply best SNI to Xray config ---
apply_sni() {
  local sni="$1"
  local config_path="$2"

  if [[ -z "$config_path" ]]; then
    config_path=$(find_xray_config)
  fi

  if [[ -z "$config_path" || ! -f "$config_path" ]]; then
    echo "Error: Xray/V2ray config not found." >&2
    echo "Specify path with --xray-config PATH" >&2
    return 1
  fi

  local backup="${config_path}.bak.$(date +%s)"
  cp "$config_path" "$backup"
  echo "Backup saved: $backup" >&2

  if command -v jq &>/dev/null; then
    jq --arg sni "$sni" '
      (.inbounds[]?.streamSettings?.realitySettings?.serverNames) |= [$sni] |
      (.inbounds[]?.streamSettings?.realitySettings?.serverName) //= $sni |
      (.inbounds[]?.streamSettings?.realitySettings?.serverName) |= $sni |
      (.inbounds[]?.streamSettings?.realitySettings?.dest | select(. != null)) |= $sni + ":" + (split(":")[1] // "443") |
      (.inbounds[]?.streamSettings?.realitySettings?.target | select(. != null)) |= $sni + ":" + (split(":")[1] // "443") |
      (.inbounds[]?.streamSettings?.xhttpSettings?.host | select(. != null)) |= $sni
    ' "$config_path" > "${config_path}.tmp" && mv "${config_path}.tmp" "$config_path"
    echo "Config updated with jq." >&2
  else
    sed -i "s/\"serverNames\": \[[^]]*\]/\"serverNames\": [\"$sni\"]/" "$config_path"
    sed -i "s/\"serverName\": \"[^\"]*\"/\"serverName\": \"$sni\"/" "$config_path"
    sed -i "s/\"dest\": \"[^\":]*:/\"dest\": \"$sni:/" "$config_path"
    sed -i "s/\"target\": \"[^\":]*:/\"target\": \"$sni:/" "$config_path"
    sed -i "/\"xhttpSettings\"/,/\"host\": \"/s/\"host\": \"[^\"]*\"/\"host\": \"$sni\"/" "$config_path"
    echo "Config updated with sed." >&2
  fi

  local svc=""
  systemctl is-active --quiet xray 2>/dev/null && svc="xray"
  systemctl is-active --quiet v2ray 2>/dev/null && svc="v2ray"
  if [[ -n "$svc" ]]; then
    systemctl restart "$svc"
    echo "$svc restarted." >&2
  fi

  echo ">>> SNI updated to: $sni <<<" >&2
  return 0
}

# --- Browse tested domains by country (GeoIP via ip.im) ---
browse_by_country() {
  local -n scored_ref="$1"

  # Collect only reachable, non-CF entries
  local -a rows=()
  local row
  for row in "${scored_ref[@]}"; do
    local r_domain r_reachable
    IFS='|' read -r _ r_domain _ r_reachable _ _ <<< "$row"
    [[ -z "$r_domain" || "$r_domain" =~ ^[0-9]+$ ]] && continue
    [[ "$r_reachable" == "true" ]] && rows+=("$row")
  done

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No reachable domains to browse." >&2
    return 0
  fi

  # Ask how many top domains to check
  echo "Enter number of top domains to check (default: all, ${#rows[@]}):" >&2
  read -r -p "> " num
  num=$(echo "$num" | tr -cd '0-9')
  if [[ -z "$num" || "$num" -le 0 || "$num" -gt ${#rows[@]} ]]; then
    num=${#rows[@]}
  fi

  # Resolve IP + query country for each selected domain
  local -a geo_rows=()   # "country|domain|row"
  local i=0
  for row in "${rows[@]:0:$num}"; do
    local g_domain g_ip g_country
    IFS='|' read -r _ g_domain _ <<< "$row"
    i=$((i + 1))
    printf '[%d/%d] %s ...' "$i" "$num" "$g_domain" >&2

    resolve_host_ips "$g_domain"
    g_ip=$(echo "$CF_IPV4_LIST" | awk '{print $1}')
    if [[ -z "$g_ip" ]]; then
      g_country="UNKNOWN"
    else
      g_country=$(geoip_country "$g_ip")
    fi
    printf '\r[%d/%d] %-35s → %s\n' "$i" "$num" "$g_domain" "$g_country" >&2
    geo_rows+=("$g_country|$g_domain|$row")
  done

  # Group by country, keep first-seen order
  local -a country_codes=()
  local -a country_domains=()  # "code|domain1|domain2..."
  local g
  for g in "${geo_rows[@]}"; do
    local code d
    code="${g%%|*}"
    d="${g#*|}"
    d="${d%%|*}"
    local found=false idx=0
    for ((j = 0; j < ${#country_codes[@]}; j++)); do
      if [[ "${country_codes[j]}" == "$code" ]]; then
        found=true
        idx=$j
        break
      fi
    done
    if $found; then
      country_domains[idx]="${country_domains[idx]}|$d"
    else
      country_codes+=("$code")
      country_domains+=("$code|$d")
    fi
  done

  # Show country list (numbered from 0)
  echo >&2
  echo "==============================" >&2
  echo "Country classification:" >&2
  for ((j = 0; j < ${#country_codes[@]}; j++)); do
    local cname cc cnt
    cc="${country_codes[j]}"
    cname="$(country_name "$cc")"
    cnt=$(echo "${country_domains[j]}" | awk -F'|' '{print NF-1}')
    echo "  $j) $cc ($cname) - $cnt domain(s)" >&2
  done
  echo "==============================" >&2

  read -r -p "Enter country number: " pick
  pick=$(echo "$pick" | tr -cd '0-9')
  if [[ -z "$pick" || "$pick" -ge ${#country_codes[@]} ]]; then
    echo "Invalid selection." >&2
    return 0
  fi

  # Show domains of selected country with their measured info
  local sel_code="${country_codes[pick]}"
  echo >&2
  echo "Domains in $sel_code ($(country_name "$sel_code")):" >&2
  local g
  for g in "${geo_rows[@]}"; do
    local code d row2
    code="${g%%|*}"
    rest="${g#*|}"
    d="${rest%%|*}"
    row2="${rest#*|}"
    [[ "$code" != "$sel_code" ]] && continue
    local s tls alpn kex tls_ms ping_ms kc
    IFS='|' read -r s _ _ _ _ tls tls_ms ping_ms _ _ kc _ _ alpn kex <<< "$row2"
    printf '  [score %-3s] %-30s %s %s %s %s %sms\n' "$s" "$d" "$tls" "$alpn" "$kex" "$kc" "$tls_ms" >&2
  done
  echo >&2
  read -r -p "Press Enter to return to menu..." _ >&2
}

# --- Interactive menu ---
show_menu() {
  local best_sni="$1"
  local best_score="$2"
  local best_reachable="$3"
  local config_path="$4"
  local scored_ref="$5"

  while true; do
    echo >&2
    echo "==============================" >&2
    echo " 0) Exit" >&2
    echo " 1) Re-test with new random domains" >&2
    if [[ "$best_reachable" == "true" ]]; then
      echo " 2) Apply '$best_sni' to Xray config and restart" >&2
    else
      echo " 2) (unavailable - no reachable domain)" >&2
    fi
    echo " 3) Browse domains by country" >&2
    echo "==============================" >&2
    read -r -p "Choose [0-3]: " choice

    case "$choice" in
      0) exit 0 ;;
      1) return 1 ;;
      2)
        if [[ "$best_reachable" != "true" ]]; then
          echo "No reachable domain. Cannot apply." >&2
          continue
        fi
        apply_sni "$best_sni" "$config_path"
        exit $?
        ;;
      3)
        if [[ -n "$scored_ref" ]]; then
          browse_by_country "$scored_ref"
        else
          echo "No results available." >&2
        fi
        ;;
      *) echo "Invalid choice." >&2 ;;
    esac
  done
}

# --- Main ---
run_test() {
  local selected=()
  local pool_size=0
  local sample_size=0

  # Refresh Cloudflare ranges from official lists (fallback to built-ins)
  refresh_cloudflare_ranges

  if [[ ${#SPECIFIC_DOMAINS[@]} -gt 0 ]]; then
    selected=("${SPECIFIC_DOMAINS[@]}")
    pool_size=${#selected[@]}
    sample_size=$pool_size
    log "Testing ${#selected[@]} specified domain(s): ${selected[*]}"
  else
    load_pool "$POOL_FILE"
    pool_size=${#pool[@]}
    if [[ $pool_size -eq 0 ]]; then
      echo '{"error": "No domains in pool"}' >&2
      exit 1
    fi
    sample_size=$COUNT
    [[ $sample_size -gt $pool_size ]] && sample_size=$pool_size
    read -ra selected <<< "$(pick_random "$sample_size" "${pool[@]}")"
    log "Pool: $pool_size domains, testing: $sample_size"
    log "Selected: ${selected[*]}"
  fi

  local total=${#selected[@]}

  # Test each domain with progress
  local raw_results=()
  for i in "${!selected[@]}"; do
    local domain="${selected[i]}" idx=$((i + 1))

    # Show progress line (always to stderr, not just in verbose)
    printf '\r[%2d/%d] %s ...' "$idx" "$total" "$domain" >&2

    raw_results+=("$(test_domain "$domain")")

    # Quick parse for result indicator
    # row format: domain|cf|reachable|cert_valid|tls|tls_ms|...
    local row="${raw_results[-1]}"
    local p_cf p_reach p_cert
    IFS='|' read -r _ p_cf p_reach p_cert _ <<< "$row"
    if [[ "$p_cf" == "true" ]]; then
      printf '\r[%2d/%d] %-35s ☁ Cloudflare skipped\n' "$idx" "$total" "$domain" >&2
    elif [[ "$p_reach" == "true" && "$p_cert" == "true" ]]; then
      local ver ms
      IFS='|' read -r _ _ _ _ ver ms _ <<< "$row"
      printf '\r[%2d/%d] %-35s ✓ %s %sms\n' "$idx" "$total" "$domain" "$ver" "$ms" >&2
    elif [[ "$p_reach" == "true" && "$p_cert" == "false" ]]; then
      printf '\r[%2d/%d] %-35s ⚠ cert invalid\n' "$idx" "$total" "$domain" >&2
    else
      printf '\r[%2d/%d] %-35s ✗ unreachable\n' "$idx" "$total" "$domain" >&2
    fi
  done

  # Score and sort (scored is global so menu option 3 can use it)
  echo "Scoring..." >&2
  scored=()
  while IFS= read -r line; do
    scored+=("$line")
  done < <(score_domains raw_results)

  # Get best SNI
  IFS='|' read -r best_score best_sni _ best_reachable _ _ <<< "${scored[0]}"

  # Output
  if [[ -n "$OUTPUT_FILE" ]]; then
    output_json scored "$best_sni" "$pool_size" "$sample_size" > "$OUTPUT_FILE"
    echo "Results written to: $OUTPUT_FILE" >&2
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

main() {
  if $AUTO_APPLY; then
    run_test
    if [[ "$best_reachable" == "true" ]]; then
      apply_sni "$best_sni" "$XRAY_CONFIG"
    else
      echo "No reachable domain found, nothing to apply." >&2
      exit 1
    fi
    exit 0
  fi

  while true; do
    run_test

    if $NO_MENU || [[ ! -t 0 ]]; then
      break
    fi

    show_menu "$best_sni" "$best_score" "$best_reachable" "$XRAY_CONFIG" scored
    ret=$?
    [[ $ret -eq 1 ]] && continue || break
  done
}

main
