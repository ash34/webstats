#!/bin/bash
# =============================================================================
# webstats.sh  –  Apache / WordPress access log analyser
# Generates a self-contained HTML dashboard in ./output/index.html
# Designed to be run every 5 minutes from cron.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOG_FILE="${APACHE_LOG:-/var/log/apache2/access.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OUTPUT_FILE="${OUTPUT_DIR}/index.html"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
TODAY="$(date '+%d/%b/%Y')"
NOW_EPOCH="$(date +%s)"

# Site address shown in the page title.
# Auto-detected from WordPress wp-config.php, Apache ServerName, or falls back to localhost.
# Override at any time by setting: SITE_ADDRESS=example.com ./webstats.sh
SITE_ADDRESS="${SITE_ADDRESS:-}"
WP_CONFIG_FOUND=""

if [[ -z "${SITE_ADDRESS}" ]]; then
    LOG_DIR_PARENT="$(dirname "$(dirname "${LOG_FILE}")")"
    for WP_CONFIG in \
        "/var/www/html/wp-config.php" \
        "/var/www/wordpress/wp-config.php" \
        "/var/www/wp-config.php" \
        "/srv/www/wp-config.php" \
        "${LOG_DIR_PARENT}/wp-config.php"; do
        if [[ -f "${WP_CONFIG}" ]]; then
            WP_CONFIG_FOUND="${WP_CONFIG}"
            # Use awk to extract WP_HOME or WP_SITEURL value - avoids quote issues
            _wp_url="$(awk -F"'" '
                /define/ && /WP_HOME|WP_SITEURL/ {
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^https?:\/\//) {
                            url = $i
                            sub(/^https?:\/\//, "", url)
                            sub(/^www\./, "", url)
                            sub(/\/$/, "", url)
                            print url
                            exit
                        }
                    }
                }
            ' "${WP_CONFIG}" 2>/dev/null | head -1)"
            if [[ -n "${_wp_url}" ]]; then
                SITE_ADDRESS="${_wp_url}"
                break
            fi
        fi
    done
fi

# Fallback: read ServerName from Apache enabled sites
if [[ -z "${SITE_ADDRESS}" ]]; then
    SITE_ADDRESS="$(grep -rh 'ServerName' /etc/apache2/sites-enabled/ 2>/dev/null \
        | grep -v '#' | awk '{print $2}' | grep '\.' | grep -v localhost | head -1)"
fi

# Final fallback
SITE_ADDRESS="${SITE_ADDRESS:-localhost}"


mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Guard: log file must exist
# ---------------------------------------------------------------------------
if [[ ! -f "${LOG_FILE}" ]]; then
    echo "ERROR: Log file not found: ${LOG_FILE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Slurp the whole log once into a temp file so we don't re-read repeatedly
# ---------------------------------------------------------------------------
TMP_ALL="$(mktemp)"
TMP_TODAY="$(mktemp)"
trap 'rm -f "${TMP_ALL}" "${TMP_TODAY}"' EXIT

cp "${LOG_FILE}" "${TMP_ALL}"

# Also include rotated logs for all-time stats
LOG_DIR="$(dirname "${LOG_FILE}")"
LOG_BASE="$(basename "${LOG_FILE}")"
# Append uncompressed rotated logs
for f in "${LOG_DIR}/${LOG_BASE}".1 "${LOG_DIR}/${LOG_BASE}"-*.log; do
    [[ -f "${f}" ]] && cat "${f}" >> "${TMP_ALL}" || true
done
# Append gzip compressed rotated logs
for f in "${LOG_DIR}/${LOG_BASE}"*.gz; do
    [[ -f "${f}" ]] && zcat "${f}" >> "${TMP_ALL}" || true
done

# Filter out internal/excluded IPs from both temp files
# Excluded: 10.98.0.0/16 subnet, 78.131.56.62, 127.0.0.0/8 loopback
filter_excluded_ips() {
    grep -vE "^(10\.98\.|78\.131\.56\.62[[:space:]]|127\.)" "$1" > "$1.tmp" && mv "$1.tmp" "$1" || true
}
filter_excluded_ips "${TMP_ALL}"

grep "${TODAY}" "${LOG_FILE}" | grep -vE "^(10\.98\.|78\.131\.56\.62[[:space:]]|127\.)" > "${TMP_TODAY}" || true

TOTAL_REQUESTS="$(wc -l < "${TMP_ALL}")"
TOTAL_TODAY="$(wc -l < "${TMP_TODAY}")"

# ---------------------------------------------------------------------------
# Month name -> number map (used throughout for timestamp parsing)
# ---------------------------------------------------------------------------
MONTHS="Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6 Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12"

# ---------------------------------------------------------------------------
# Oldest log entry in the dataset (all-time, after IP filtering)
# Find the oldest line across all source files rather than head of TMP_ALL,
# because TMP_ALL has today's log first and rotated logs appended after.
# Rotated logs are older by definition; the oldest .gz is the furthest back.
# ---------------------------------------------------------------------------

# Collect candidate "first lines" from each source file, excluding filtered IPs
OLDEST_CANDIDATES=""

# From each rotated uncompressed log
for f in "${LOG_DIR}/${LOG_BASE}".1 "${LOG_DIR}/${LOG_BASE}"-*.log; do
    if [[ -f "${f}" ]]; then
        _line="$(grep -vE "^(10\.98\.|78\.131\.56\.62[[:space:]]|127\.)" "${f}" | head -1)"
        [[ -n "${_line}" ]] && OLDEST_CANDIDATES="${OLDEST_CANDIDATES}${_line}
"
    fi
done

# From each rotated compressed log (last .gz has the oldest data)
for f in "${LOG_DIR}/${LOG_BASE}"*.gz; do
    if [[ -f "${f}" ]]; then
        _line="$(zcat "${f}" | grep -vE "^(10\.98\.|78\.131\.56\.62[[:space:]]|127\.)" | head -1)"
        [[ -n "${_line}" ]] && OLDEST_CANDIDATES="${OLDEST_CANDIDATES}${_line}
"
    fi
done

# Also include the first filtered line from the current log as a fallback
_line="$(head -1 "${TMP_ALL}")"
[[ -n "${_line}" ]] && OLDEST_CANDIDATES="${OLDEST_CANDIDATES}${_line}
"

# Find the true oldest by converting each candidate's timestamp to epoch and picking minimum
OLDEST_LOG_LINE="$(echo "${OLDEST_CANDIDATES}" | grep -v '^$' | awk -v months="${MONTHS}" '
BEGIN {
    n = split(months, mp, " ")
    for (i = 1; i <= n; i += 2) mon[mp[i]] = mp[i+1]
    min_epoch = 9999999999
    min_line  = ""
}
{
    raw = $4
    gsub(/[\[\]]/, "", raw)
    gsub(/\//, " ", raw)
    split(raw, a, /[: ]/)
    if (a[3]+0 < 2000) next
    epoch = mktime(a[3] " " mon[a[2]]+0 " " a[1]+0 " " a[4]+0 " " a[5]+0 " " a[6]+0)
    if (epoch > 0 && epoch < min_epoch) {
        min_epoch = epoch
        min_line  = $0
    }
}
END { print min_line }
')"
OLDEST_LOG_TS=""
OLDEST_LOG_AGE=""
if [[ -n "${OLDEST_LOG_LINE}" ]]; then
    # Parse directly from the log line using awk — extract all parts in one pass
    # Output format: "YYYY MON DD HH MM SS" suitable for mktime()
    read -r OLDEST_EPOCH OLDEST_LOG_DISPLAY < <(echo "${OLDEST_LOG_LINE}" | awk -v months="${MONTHS}" '
    BEGIN {
        n = split(months, mp, " ")
        for (i = 1; i <= n; i += 2) mon[mp[i]] = mp[i+1]
    }
    {
        raw = $4
        gsub(/[\[\]]/, "", raw)
        gsub(/\//, " ", raw)
        n2 = split(raw, a, /[: ]/)
        # a[1]=DD a[2]=Mon a[3]=YYYY a[4]=HH a[5]=MM a[6]=SS
        epoch = mktime(a[3] " " mon[a[2]]+0 " " a[1]+0 " " a[4]+0 " " a[5]+0 " " a[6]+0)
        display = sprintf("%s-%02d-%02s %s:%s:%s", a[3], mon[a[2]]+0, a[1], a[4], a[5], a[6])
        print epoch, display
    }')
    if [[ "${OLDEST_EPOCH:-0}" -gt 0 ]]; then
        AGE_SECS=$(( NOW_EPOCH - OLDEST_EPOCH ))
        AGE_DAYS=$(( AGE_SECS / 86400 ))
        AGE_HRS=$(( (AGE_SECS % 86400) / 3600 ))
        AGE_MINS=$(( (AGE_SECS % 3600) / 60 ))
        if   (( AGE_DAYS >= 1 )); then
            OLDEST_LOG_AGE="${AGE_DAYS}d ${AGE_HRS}h ago"
        elif (( AGE_HRS >= 1 )); then
            OLDEST_LOG_AGE="${AGE_HRS}h ${AGE_MINS}m ago"
        else
            OLDEST_LOG_AGE="${AGE_MINS}m ago"
        fi
    fi
fi
OLDEST_LOG_DISPLAY="${OLDEST_LOG_DISPLAY:-Unknown}"
OLDEST_LOG_AGE="${OLDEST_LOG_AGE:-Unknown}"

# ---------------------------------------------------------------------------
# Requests in the last 5 / 15 / 60 minutes
# Pure POSIX awk (mawk + gawk compatible) — no subshells per line.
# Apache Combined Log field 4 is [DD/Mon/YYYY:HH:MM:SS +nnnn]
# We strip brackets, split on / : space and feed mktime().
# ---------------------------------------------------------------------------
MONTHS="Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6 Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12"

read -r REQ_5MIN REQ_15MIN REQ_60MIN < <(
awk -v now="${NOW_EPOCH}" -v months="${MONTHS}" '
BEGIN {
    n = split(months, mp, " ")
    for (i = 1; i <= n; i += 2) mon[mp[i]] = mp[i+1]
}
{
    # Field 4 looks like: [01/Jan/2025:14:32:01
    raw = $4
    gsub(/[\[\]]/, "", raw)        # strip brackets
    gsub(/:/, " ", raw)            # turn colons into spaces
    gsub(/\//, " ", raw)           # turn slashes into spaces
    # raw is now: DD Mon YYYY HH MM SS
    split(raw, a, " ")
    # a[1]=DD a[2]=Mon a[3]=YYYY a[4]=HH a[5]=MM a[6]=SS
    if (a[3]+0 < 2000) next       # skip malformed lines
    t = mktime(a[3] " " mon[a[2]]+0 " " a[1]+0 " " a[4]+0 " " a[5]+0 " " a[6]+0)
    if (t < 0) next
    diff = now - t
    if (diff <= 300)  c5++
    if (diff <= 900)  c15++
    if (diff <= 3600) c60++
}
END { print c5+0, c15+0, c60+0 }
' "${TMP_TODAY}"
)

# ---------------------------------------------------------------------------
# Status code breakdown (all time)
# ---------------------------------------------------------------------------
STATUS_BREAKDOWN="$(awk '{print $9}' "${TMP_ALL}" | grep -E '^[0-9]{3}$' | sort | uniq -c | sort -rn | head -20)"

# ---------------------------------------------------------------------------
# Unique IPs
# ---------------------------------------------------------------------------
UNIQUE_IPS_ALL="$(awk '{print $1}' "${TMP_ALL}" | sort -u | wc -l)"
UNIQUE_IPS_TODAY="$(awk '{print $1}' "${TMP_TODAY}" | sort -u | wc -l)"

# Top 20 IPs
TOP_IPS="$(awk '{print $1}' "${TMP_ALL}" | sort | uniq -c | sort -rn | head -20)"

# ---------------------------------------------------------------------------
# Top 20 URLs (all requests)
# ---------------------------------------------------------------------------
TOP_URLS="$(awk '{print $7}' "${TMP_ALL}" | sort | uniq -c | sort -rn | head -20)"

# Top 20 pages (exclude static assets)
TOP_PAGES="$(awk '{print $7}' "${TMP_ALL}" | grep -vE '\.(css|js|png|jpg|jpeg|gif|ico|woff|woff2|ttf|svg|webp|map)(\?|$)' | sort | uniq -c | sort -rn | head -20)"

# ---------------------------------------------------------------------------
# WordPress-specific
# ---------------------------------------------------------------------------
WP_LOGIN="$(grep -c 'wp-login\.php' "${TMP_ALL}" || true)"
XMLRPC="$(grep -c 'xmlrpc\.php' "${TMP_ALL}" || true)"
WP_JSON="$(grep -c '/wp-json/' "${TMP_ALL}" || true)"
WP_ADMIN="$(grep -c '/wp-admin/' "${TMP_ALL}" || true)"
WP_CRON="$(grep -c 'wp-cron\.php' "${TMP_ALL}" || true)"

# ---------------------------------------------------------------------------
# 404 URLs
# ---------------------------------------------------------------------------
TOP_404="$(awk '$9=="404"{print $7}' "${TMP_ALL}" | sort | uniq -c | sort -rn | head -20)"
TOTAL_404="$(awk '$9=="404"' "${TMP_ALL}" | wc -l)"

# ---------------------------------------------------------------------------
# Bandwidth (field 10 = bytes sent)
# ---------------------------------------------------------------------------
TOTAL_BYTES="$(awk '{if($10~/^[0-9]+$/) sum+=$10} END{print sum+0}' "${TMP_ALL}")"
TOTAL_BYTES_TODAY="$(awk '{if($10~/^[0-9]+$/) sum+=$10} END{print sum+0}' "${TMP_TODAY}")"

human_bytes() {
    local b="$1"
    if   (( b >= 1073741824 )); then printf "%.2f GB" "$(echo "scale=2; ${b}/1073741824" | bc)"
    elif (( b >= 1048576 ));    then printf "%.2f MB" "$(echo "scale=2; ${b}/1048576" | bc)"
    elif (( b >= 1024 ));       then printf "%.2f KB" "$(echo "scale=2; ${b}/1024" | bc)"
    else echo "${b} B"
    fi
}

TOTAL_BW="$(human_bytes "${TOTAL_BYTES}")"
TOTAL_BW_TODAY="$(human_bytes "${TOTAL_BYTES_TODAY}")"

# Top 20 URLs by total bytes served (aggregated)
TOP_LARGE_RAW="$(awk '{if($10~/^[0-9]+$/) bytes[$7]+=$10} END{for(u in bytes) print bytes[u], u}' "${TMP_ALL}" | sort -rn | head -20)"

# Format bytes using max-3-integer rule: <1000B->B, <1000KB->KB, <1000MB->MB, else GB
# Rounding: standard half-up (5+ rounds up)
smart_size() {
    local b="$1"
    local kb=$(( (b + 512) / 1024 ))
    local mb=$(( (b + 524288) / 1048576 ))
    local gb=$(( (b + 536870912) / 1073741824 ))
    if   (( b < 1000 ));         then echo "${b}B"
    elif (( kb < 1000 ));        then echo "${kb}KB"
    elif (( mb < 1000 ));        then echo "${mb}MB"
    else                              echo "${gb}GB"
    fi
}

# Build TOP_LARGE with smart sizes prepended for display
TOP_LARGE=""
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    raw_bytes="$(echo "${line}" | awk '{print $1}')"
    url="$(echo "${line}" | awk '{$1=""; print substr($0,2)}')"
    sized="$(smart_size "${raw_bytes}")"
    TOP_LARGE="${TOP_LARGE}${sized} ${url}
"
done <<< "${TOP_LARGE_RAW}"

# ---------------------------------------------------------------------------
# Bandwidth by hour today
# ---------------------------------------------------------------------------
BW_BY_HOUR="$(awk '{
    raw = $4; gsub(/[\[\]]/, "", raw); split(raw, t, ":")
    hr = t[2]
    if($10~/^[0-9]+$/) bw[hr]+=$10
}
END { for(h in bw) print h, bw[h] }' "${TMP_TODAY}" | sort)"

# ---------------------------------------------------------------------------
# Requests by hour today (for chart)
# ---------------------------------------------------------------------------
REQ_BY_HOUR="$(awk '{
    raw = $4; gsub(/[\[\]]/, "", raw); split(raw, t, ":")
    hr = t[2]
    count[hr]++
}
END { for(h in count) print h, count[h] }' "${TMP_TODAY}" | sort)"

# Peak hour
PEAK_HOUR="$(echo "${REQ_BY_HOUR}" | sort -k2 -rn | head -1)"

# ---------------------------------------------------------------------------
# Suspicious IPs (>500 req today)
# ---------------------------------------------------------------------------
SUSPICIOUS_IPS="$(awk '{print $1}' "${TMP_TODAY}" | sort | uniq -c | sort -rn | awk '$1>500{print $1, $2}' | head -20)"

# ---------------------------------------------------------------------------
# Top 20 User Agents
# ---------------------------------------------------------------------------
# User agent is the last double-quoted field in Combined Log Format.
# Split each line on " and take the second-to-last segment.
TOP_UA="$(awk '{
    n = split($0, chars, "\"")
    if (n >= 2) print chars[n-1]
}' "${TMP_ALL}" | grep -v "^[[:space:]]*$" | sort | uniq -c | sort -rn | head -20)"

# Known good bots
GOOGLEBOT="$(grep -ci 'googlebot' "${TMP_ALL}" || true)"
BINGBOT="$(grep -ci 'bingbot' "${TMP_ALL}" || true)"
FACEBOOKBOT="$(grep -ci 'facebookexternalhit' "${TMP_ALL}" || true)"
TWITTERBOT="$(grep -ci 'twitterbot' "${TMP_ALL}" || true)"
SEMRUSHBOT="$(grep -ci 'semrushbot' "${TMP_ALL}" || true)"

# Known bad bot activity
BAD_BOT_WP_ADMIN="$(awk '$9~/^[45][0-9][0-9]$/ && /\/wp-admin\// {print $1}' "${TMP_ALL}" | sort -u | wc -l)"
BAD_BOT_XMLRPC="$(awk '/xmlrpc\.php/ && $9~/^[45][0-9][0-9]$/ {print $1}' "${TMP_ALL}" | sort -u | wc -l)"

# Human vs bot split (heuristic — looks at UA field and known automated endpoints)
BOT_REQS="$(grep -ciE '(bot|crawler|spider|slurp|wget|curl|python-requests|libwww|scrapy|go-http|jetpack|wordpress\.com|ahrefsbot|semrushbot|mj12bot|dotbot|petalbot|yandex|baiduspider|zgrab|masscan|nuclei|nmap|sqlmap)' "${TMP_ALL}" || true)"
# Also count lines hitting xmlrpc.php or wp-login.php with no UA (Common log format lines = 7 fields)
NOUA_REQS="$(awk 'NF<=7 && (/xmlrpc\.php/ || /wp-login\.php/)' "${TMP_ALL}" | wc -l)"
BOT_REQS=$(( BOT_REQS + NOUA_REQS ))
HUMAN_REQS=$(( TOTAL_REQUESTS - BOT_REQS ))
if (( HUMAN_REQS < 0 )); then HUMAN_REQS=0; fi
BOT_PCT=0
HUMAN_PCT=0
if (( TOTAL_REQUESTS > 0 )); then
    BOT_PCT=$(( BOT_REQS * 100 / TOTAL_REQUESTS ))
    HUMAN_PCT=$(( 100 - BOT_PCT ))
fi

# ---------------------------------------------------------------------------
# GeoIP (optional – only if geoiplookup is installed)
# ---------------------------------------------------------------------------
GEO_TABLE=""
if command -v geoiplookup &>/dev/null; then
    GEO_TABLE="$(awk '{print $1}' "${TMP_ALL}" | sort -u | while read -r ip; do
        geoiplookup "${ip}" 2>/dev/null | grep -oP '(?<=: )[A-Z]{2}, .*' | head -1
    done | sort | uniq -c | sort -rn | head -20)"
fi

# ---------------------------------------------------------------------------
# Fail2ban statistics (optional – only if fail2ban-client is available)
# ---------------------------------------------------------------------------
F2B_AVAILABLE=0
F2B_JAIL_LIST=""
F2B_TOTAL_BANNED=0
F2B_JAIL_ROWS=""
F2B_BANNED_IPS=""

if command -v fail2ban-client &>/dev/null; then
    F2B_AVAILABLE=1

    # Get list of active jails
    # Get all running jails from fail2ban-client
    _F2B_RUNNING="$(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*Jail list:[[:space:]]*//' | tr ',' '\n' | tr -d ' ' | grep -v '^$')"

    # Cross-reference with jail.local to include only explicitly enabled jails.
    # A jail is enabled if jail.local contains [jailname] followed by enabled = true
    # before the next [section]. Jails not mentioned in jail.local but running are included.
    F2B_JAIL_LIST=""
    F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"
    while IFS= read -r jail; do
        [[ -z "${jail}" ]] && continue
        if [[ -f "${F2B_JAIL_LOCAL}" ]]; then
            # Extract the block for this jail and check for enabled = true
            _enabled="$(awk -v j="${jail}" '
                /^\[/ { in_jail = (substr($0,2,length($0)-2) == j) }
                in_jail && /enabled[[:space:]]*=[[:space:]]*true/ { found=1 }
                in_jail && /enabled[[:space:]]*=[[:space:]]*false/ { found=0 }
                END { print found+0 }
            ' "${F2B_JAIL_LOCAL}")"
            # Include if explicitly enabled OR if jail.local has no entry for it (running = trusted)
            _mentioned="$(grep -c "^\[${jail}\]" "${F2B_JAIL_LOCAL}" 2>/dev/null || echo 0)"
            if [[ "${_enabled}" == "1" ]] || [[ "${_mentioned}" == "0" ]]; then
                F2B_JAIL_LIST="${F2B_JAIL_LIST}${jail}
"
            fi
        else
            # No jail.local — include all running jails
            F2B_JAIL_LIST="${F2B_JAIL_LIST}${jail}
"
        fi
    done <<< "${_F2B_RUNNING}"
    F2B_JAIL_LIST="$(echo "${F2B_JAIL_LIST}" | sort)"
    F2B_JAIL_COUNT="$(echo "${F2B_JAIL_LIST}" | grep -c . || true)"

    # Per-jail stats
    ALL_BANNED_IPS=""
    F2B_JAIL_DATA=""
    while IFS= read -r jail; do
        [[ -z "${jail}" ]] && continue
        jail_status="$(fail2ban-client status "${jail}" 2>/dev/null)"
        currently_banned="$(echo "${jail_status}" | grep 'Currently banned' | awk '{print $NF}')"
        total_banned="$(echo "${jail_status}"    | grep 'Total banned'     | awk '{print $NF}')"
        total_failed="$(echo "${jail_status}"    | grep 'Total failed'     | awk '{print $NF}')"
        banned_ips="$(echo "${jail_status}"      | grep 'Banned IP list'   | sed 's/.*Banned IP list:\s*//')"
        # Store as sortable line: padded failed count | html row
        _failed_padded="$(printf '%010d' "${total_failed:-0}")"
        F2B_JAIL_DATA="${F2B_JAIL_DATA}${_failed_padded}|<tr><td>${jail}</td><td class='num'>${total_failed:-0}</td><td class='num'>${total_banned:-0}</td><td class='num'>${currently_banned:-0}</td></tr>
"
        ALL_BANNED_IPS="${ALL_BANNED_IPS} ${banned_ips}"
        F2B_TOTAL_BANNED=$(( F2B_TOTAL_BANNED + ${currently_banned:-0} ))
    done <<< "${F2B_JAIL_LIST}"

    # Sort jail rows by failed attempts descending (highest first)
    F2B_JAIL_ROWS="$(echo "${F2B_JAIL_DATA}" | sort -t'|' -k1 -rn | cut -d'|' -f2- | tr -d '\n')"

    # Build banned IP list ordered by most-recently-banned first using fail2ban log
    # Extract "Ban <ip>" lines from fail2ban log, newest last -> reverse -> unique by IP
    F2B_LOG="/var/log/fail2ban.log"
    declare -A seen_ip
    F2B_ORDERED_IPS=""
    if [[ -f "${F2B_LOG}" ]]; then
        while IFS= read -r ip; do
            [[ -z "${ip}" ]] && continue
            [[ -n "${seen_ip[$ip]+x}" ]] && continue
            seen_ip[$ip]=1
            F2B_ORDERED_IPS="${F2B_ORDERED_IPS}${ip}\n"
        done < <(grep ' Ban ' "${F2B_LOG}" 2>/dev/null | awk '{print $NF}' | tac)
    fi
    # Fall back to alphabetical if log unavailable
    if [[ -z "${F2B_ORDERED_IPS}" ]]; then
        F2B_ORDERED_IPS="$(echo "${ALL_BANNED_IPS}" | tr ' ' '\n' | grep -v '^$' | sort -u)"
    fi
    # Only keep IPs that are currently banned
    CURRENTLY_BANNED_SET="$(echo "${ALL_BANNED_IPS}" | tr ' ' '\n' | grep -v '^$' | sort -u)"
    F2B_BANNED_ROWS=""
    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        echo "${CURRENTLY_BANNED_SET}" | grep -qx "${ip}" || continue
        geo=""
        if command -v geoiplookup &>/dev/null; then
            geo="$(geoiplookup "${ip}" 2>/dev/null | grep -oP '(?<=: )[A-Z]{2}, [^,]+' | head -1)"
        fi
        F2B_BANNED_ROWS="${F2B_BANNED_ROWS}<tr><td class='item'>${ip}</td><td>${geo:-Unknown}</td></tr>"
    done < <(printf "%b" "${F2B_ORDERED_IPS}")
fi


make_table() {
    local data="$1"
    local col1="$2"
    local col2="$3"
    echo "<table><thead><tr><th>${col1}</th><th>${col2}</th></tr></thead><tbody>"
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        count="$(echo "${line}" | awk '{print $1}')"
        item="$(echo "${line}" | awk '{$1=""; print substr($0,2)}')"
        item_escaped="$(echo "${item}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        echo "<tr><td class='num'>${count}</td><td class='item'>${item_escaped}</td></tr>"
    done <<< "${data}"
    echo "</tbody></table>"
}

# ---------------------------------------------------------------------------
# Build hourly bar chart data (JSON-ish for inline JS)
# ---------------------------------------------------------------------------
build_chart_data() {
    local labels=""
    local values=""
    for h in $(seq -w 0 23); do
        val="$(echo "${REQ_BY_HOUR}" | awk -v hr="${h}" '$1==hr{print $2}' | head -1)"
        val="${val:-0}"
        labels="${labels}\"${h}:00\","
        values="${values}${val},"
    done
    echo "labels:[${labels%,}], values:[${values%,}]"
}

CHART_DATA="$(build_chart_data)"

# ---------------------------------------------------------------------------
# Build bandwidth-by-hour rows
# ---------------------------------------------------------------------------
BW_ROWS=""
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    hr="$(echo "${line}" | awk '{print $1}')"
    bw="$(echo "${line}" | awk '{print $2}')"
    BW_ROWS="${BW_ROWS}<tr><td>${hr}:00</td><td class='num'>$(human_bytes "${bw}")</td></tr>"
done <<< "${BW_BY_HOUR}"

# ---------------------------------------------------------------------------
# Status codes as coloured badge rows
# ---------------------------------------------------------------------------
status_class() {
    local code="$1"
    case "${code:0:1}" in
        2) echo "s2xx" ;;
        3) echo "s3xx" ;;
        4) echo "s4xx" ;;
        5) echo "s5xx" ;;
        *) echo "soth" ;;
    esac
}

STATUS_ROWS=""
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    cnt="$(echo "${line}" | awk '{print $1}')"
    code="$(echo "${line}" | awk '{print $2}')"
    cls="$(status_class "${code}")"
    STATUS_ROWS="${STATUS_ROWS}<tr><td><span class='badge ${cls}'>${code}</span></td><td class='num'>${cnt}</td></tr>"
done <<< "${STATUS_BREAKDOWN}"

# ---------------------------------------------------------------------------
# Suggested fail2ban filters — analyse log patterns not yet covered
# ---------------------------------------------------------------------------
# Each entry: "COUNT LABEL|DESCRIPTION|COMMAND"
SUGGESTED_FILTERS=""

# Helper: count hits for a pattern not already handled by active jails
# We generate suggestions based on significant unblocked attack patterns

# 1. xmlrpc.php POST attacks — check if any active jail covers it
F2B_HAS_XMLRPC=0
if echo "${F2B_JAIL_LIST}" | grep -qi "xmlrpc"; then F2B_HAS_XMLRPC=1; fi
XMLRPC_UNIQUE_IPS="$(awk '/xmlrpc\.php/ && $6~/POST/ {print $1}' "${TMP_ALL}" | sort -u | wc -l)"
if (( F2B_HAS_XMLRPC == 0 && XMLRPC_UNIQUE_IPS > 0 )); then
    XMLRPC_HITS="$(grep -c 'xmlrpc\.php' "${TMP_ALL}" || true)"
    SUGGESTED_FILTERS="${SUGGESTED_FILTERS}${XMLRPC_HITS}|xmlrpc.php brute force|POST /xmlrpc.php attacks (${XMLRPC_UNIQUE_IPS} unique IPs)|sudo fail2ban-client set apache-wordpress banip <IP>  # or create apache-xmlrpc jail
"
fi

# 2. PHP shell scanner (sequential random .php probes)
SHELL_SCAN_IPS="$(awk '{print $1, $7}' "${TMP_ALL}" | grep -E '/(alfa|b|x|aaa|admin|shell|c99|r57|wso|indoxploit|bypass|ghost|mini|config|setup)\.php' | awk '{print $1}' | sort -u | wc -l)"
SHELL_SCAN_HITS="$(grep -cE '/(alfa|b|x|aaa|admin\.php|shell|c99|r57|wso|indoxploit|bypass|ghost|mini\.php|config\.php|setup\.php)' "${TMP_ALL}" || true)"
if (( SHELL_SCAN_IPS > 0 )); then
    SUGGESTED_FILTERS="${SUGGESTED_FILTERS}${SHELL_SCAN_HITS}|PHP shell scanner|Probing for PHP webshells (${SHELL_SCAN_IPS} unique IPs)|sudo apt install fail2ban  # then enable apache-botsearch jail in /etc/fail2ban/jail.local
"
fi

# 3. .env / .git config probes
ENV_HITS="$(grep -cE '\.(env|git/config|git/HEAD)' "${TMP_ALL}" || true)"
ENV_IPS="$(grep -E '\.(env|git/config|git/HEAD)' "${TMP_ALL}" | awk '{print $1}' | sort -u | wc -l)"
if (( ENV_IPS > 0 )); then
    SUGGESTED_FILTERS="${SUGGESTED_FILTERS}${ENV_HITS}|.env/.git probe|Scanning for exposed config files (${ENV_IPS} unique IPs)|sudo fail2ban-client set apache-wordpress banip <IP>  # or create custom filter
"
fi

# 4. wp-json 401 scraping
WPJSON_HITS="$(awk '/wp-json/ && $9=="401"' "${TMP_ALL}" | wc -l)"
WPJSON_IPS="$(awk '/wp-json/ && $9=="401"' "${TMP_ALL}" | awk '{print $1}' | sort -u | wc -l)"
if (( WPJSON_IPS > 2 )); then
    SUGGESTED_FILTERS="${SUGGESTED_FILTERS}${WPJSON_HITS}|wp-json 401 scraper|REST API enumeration attempts (${WPJSON_IPS} unique IPs)|sudo fail2ban-client set apache-wordpress banip <IP>  # or add wp-json rule to filter
"
fi

# 5. Repeated 404 scanner (>20 404s from same IP)
SCANNER_404_IPS="$(awk '$9=="404"{count[$1]++} END{for(ip in count) if(count[ip]>20) print ip}' "${TMP_ALL}" | wc -l)"
SCANNER_404_HITS="$(awk '$9=="404"{count[$1]++} END{for(ip in count) if(count[ip]>20) total+=count[ip]} END{print total+0}' "${TMP_ALL}")"
if (( SCANNER_404_IPS > 0 )); then
    SUGGESTED_FILTERS="${SUGGESTED_FILTERS}${SCANNER_404_HITS}|404 scanner|IPs with >20 consecutive 404s (${SCANNER_404_IPS} unique IPs)|sudo fail2ban-client set apache-wordpress banip <IP>  # enable apache-404 jail
"
fi

# Build HTML rows for suggested filters table
SUGGEST_ROWS=""
if [[ -n "${SUGGESTED_FILTERS}" ]]; then
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        hits="$(echo "${entry}" | cut -d'|' -f1)"
        label="$(echo "${entry}" | cut -d'|' -f2)"
        desc="$(echo "${entry}" | cut -d'|' -f3)"
        cmd="$(echo "${entry}" | cut -d'|' -f4)"
        cmd_escaped="$(echo "${cmd}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"
        safe_id="$(echo "${label}" | tr ' /' '__')"
        SUGGEST_ROWS="${SUGGEST_ROWS}
<tr>
  <td class='num'>${hits}</td>
  <td><strong>${label}</strong><br><span style='font-size:0.78rem;color:var(--muted)'>${desc}</span></td>
  <td>
    <div class='cmd-block' id='cmd_${safe_id}'>
      <code>${cmd_escaped}</code>
      <button class='copy-btn' onclick='copyCmd("cmd_${safe_id}")'>&#128203; Copy command</button>
    </div>
  </td>
</tr>"
    done <<< "${SUGGESTED_FILTERS}"
fi

# ---------------------------------------------------------------------------
# Write the HTML
# ---------------------------------------------------------------------------
cat > "${OUTPUT_FILE}" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="refresh" content="120">
<title>Apache &amp; WordPress Dashboard | ${SITE_ADDRESS}</title>
<style>
/* ── Palette & Tokens ───────────────────────────────────────────────── */
:root{
  --bg:       #0d1117;
  --surface:  #161b22;
  --surface2: #1f2937;
  --border:   #30363d;
  --text:     #e6edf3;
  --muted:    #8b949e;
  --accent1:  #58a6ff;   /* blue  */
  --accent2:  #3fb950;   /* green */
  --accent3:  #f78166;   /* red   */
  --accent4:  #d29922;   /* amber */
  --accent5:  #bc8cff;   /* purple*/
  --accent6:  #39d0d8;   /* teal  */
  --s2xx:#238636; --s3xx:#1f6feb; --s4xx:#9e6a03; --s5xx:#b91c1c; --soth:#30363d;
  --radius:10px;
  --font-head:'Courier Prime',monospace;
  --font-body:'IBM Plex Sans',system-ui,sans-serif;
}

/* ── Reset & Base ───────────────────────────────────────────────────── */
*{box-sizing:border-box;margin:0;padding:0}
body{
  background:var(--bg);
  color:var(--text);
  font-family:var(--font-body);
  font-size:14px;
  line-height:1.6;
  min-height:100vh;
}

/* ── Top Bar ────────────────────────────────────────────────────────── */
.topbar{
  background:linear-gradient(90deg,#1a2744 0%,#0d1117 60%);
  border-bottom:2px solid var(--accent1);
  padding:18px 32px;
  display:flex;
  align-items:center;
  justify-content:space-between;
  flex-wrap:wrap;
  gap:12px;
  position:sticky;
  top:0;
  z-index:100;
  backdrop-filter:blur(6px);
}
.topbar h1{
  font-family:var(--font-head);
  font-size:1.5rem;
  color:var(--accent1);
  letter-spacing:0.04em;
}
.topbar h1 span{color:var(--accent2);}
.timestamp{
  font-family:var(--font-head);
  font-size:0.78rem;
  color:var(--accent4);
  background:rgba(210,153,34,0.1);
  padding:5px 12px;
  border-radius:20px;
  border:1px solid rgba(210,153,34,0.3);
}
.refresh-note{font-size:0.72rem;color:var(--muted);margin-top:2px;}

/* ── Layout ─────────────────────────────────────────────────────────── */
.main{padding:28px 32px;max-width:1600px;margin:0 auto;}
section{margin-bottom:40px;}
.section-title{
  font-family:var(--font-head);
  font-size:1.05rem;
  color:var(--accent5);
  letter-spacing:0.06em;
  text-transform:uppercase;
  border-bottom:1px solid var(--border);
  padding-bottom:10px;
  margin-bottom:20px;
}
.section-title .icon{margin-right:8px;}

/* ── Stat Cards ─────────────────────────────────────────────────────── */
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:16px;}
.card{
  background:var(--surface);
  border:1px solid var(--border);
  border-radius:var(--radius);
  padding:18px 20px;
  position:relative;
  overflow:hidden;
  transition:transform 0.15s,border-color 0.15s;
}
.card:hover{transform:translateY(-2px);border-color:var(--accent1);}
.card::before{
  content:'';
  position:absolute;
  top:0;left:0;right:0;height:3px;
}
.card.c1::before{background:var(--accent1);}
.card.c2::before{background:var(--accent2);}
.card.c3::before{background:var(--accent3);}
.card.c4::before{background:var(--accent4);}
.card.c5::before{background:var(--accent5);}
.card.c6::before{background:var(--accent6);}
.card-label{font-size:0.72rem;text-transform:uppercase;letter-spacing:0.08em;color:var(--muted);margin-bottom:8px;}
.card-value{font-family:var(--font-head);font-size:1.9rem;font-weight:700;line-height:1;}
.card-sub{font-size:0.72rem;color:var(--muted);margin-top:6px;}

/* ── Grid Layouts ───────────────────────────────────────────────────── */
.grid-2{display:grid;grid-template-columns:1fr 1fr;gap:20px;}
.grid-3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:20px;}
@media(max-width:900px){.grid-2,.grid-3{grid-template-columns:1fr;}}

/* ── Panels ─────────────────────────────────────────────────────────── */
.panel{
  background:var(--surface);
  border:1px solid var(--border);
  border-radius:var(--radius);
  overflow:hidden;
}
.panel-head{
  padding:12px 18px;
  background:var(--surface2);
  font-family:var(--font-head);
  font-size:0.82rem;
  color:var(--accent6);
  letter-spacing:0.05em;
  text-transform:uppercase;
  border-bottom:1px solid var(--border);
}
.panel-body{padding:0;}

/* ── Tables ─────────────────────────────────────────────────────────── */
table{width:100%;border-collapse:collapse;}
thead tr{background:var(--surface2);}
th{
  padding:10px 14px;
  text-align:left;
  font-size:0.72rem;
  letter-spacing:0.08em;
  text-transform:uppercase;
  color:var(--muted);
  border-bottom:1px solid var(--border);
}
td{
  padding:8px 14px;
  border-bottom:1px solid rgba(48,54,61,0.5);
  font-size:0.82rem;
  vertical-align:middle;
}
tr:last-child td{border-bottom:none;}
tr:hover td{background:rgba(255,255,255,0.03);}
td.num{
  font-family:var(--font-head);
  color:var(--accent1);
  white-space:nowrap;
  font-size:0.9rem;
}
td.item{
  font-family:'Courier Prime',monospace;
  word-break:break-all;
  font-size:0.8rem;
  color:#c9d1d9;
}

/* ── Status Badges ───────────────────────────────────────────────────── */
.badge{
  display:inline-block;
  padding:2px 10px;
  border-radius:12px;
  font-family:var(--font-head);
  font-size:0.85rem;
  font-weight:700;
}
.s2xx{background:rgba(35,134,54,0.25);color:#3fb950;border:1px solid rgba(35,134,54,0.4);}
.s3xx{background:rgba(31,111,235,0.25);color:#58a6ff;border:1px solid rgba(31,111,235,0.4);}
.s4xx{background:rgba(158,106,3,0.25); color:#d29922;border:1px solid rgba(158,106,3,0.4);}
.s5xx{background:rgba(185,28,28,0.25); color:#f78166;border:1px solid rgba(185,28,28,0.4);}
.soth{background:var(--surface2);color:var(--muted);border:1px solid var(--border);}

/* ── WP Metric rows ─────────────────────────────────────────────────── */
.wp-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:12px;padding:16px;}
.wp-item{
  background:var(--surface2);
  border-radius:8px;
  padding:14px 16px;
  border-left:3px solid var(--accent5);
}
.wp-item .wlabel{font-size:0.72rem;color:var(--muted);margin-bottom:4px;}
.wp-item .wvalue{font-family:var(--font-head);font-size:1.4rem;color:var(--accent5);}

/* ── Bot/Human doughnut-like bar ────────────────────────────────────── */
.bot-bar-wrap{padding:16px 18px;}
.bot-bar-label{display:flex;justify-content:space-between;margin-bottom:6px;font-size:0.8rem;}
.bot-bar-outer{height:18px;background:var(--surface2);border-radius:9px;overflow:hidden;border:1px solid var(--border);}
.bot-bar-human{height:100%;float:left;background:linear-gradient(90deg,var(--accent2),var(--accent6));transition:width 1s;}
.bot-bar-bot  {height:100%;float:left;background:linear-gradient(90deg,var(--accent4),var(--accent3));}
.bot-summary{display:flex;gap:20px;margin-top:12px;font-size:0.8rem;}
.bot-dot{width:10px;height:10px;border-radius:50%;display:inline-block;margin-right:5px;vertical-align:middle;}

/* ── Hour Chart ─────────────────────────────────────────────────────── */
.chart-wrap{padding:20px 18px 10px;}
.chart-svg-container{width:100%;overflow-x:auto;}

/* ── Security Alert ─────────────────────────────────────────────────── */
.alert-row{
  background:rgba(185,28,28,0.1);
  border:1px solid rgba(185,28,28,0.3);
  border-radius:8px;
  padding:14px 18px;
  margin-bottom:12px;
  display:flex;
  align-items:center;
  gap:12px;
  font-size:0.84rem;
}
.alert-icon{font-size:1.3rem;}

/* ── Suggested Filter Commands ──────────────────────────────────────── */
.cmd-block{
  background:var(--surface2);
  border:1px solid var(--border);
  border-radius:6px;
  padding:8px 10px;
  display:flex;
  align-items:center;
  gap:10px;
  flex-wrap:wrap;
}
.cmd-block code{
  font-family:'Courier Prime',monospace;
  font-size:0.75rem;
  color:var(--accent6);
  flex:1;
  word-break:break-all;
}
.copy-btn{
  background:var(--accent1);
  color:#0d1117;
  border:none;
  border-radius:5px;
  padding:5px 12px;
  font-size:0.75rem;
  font-weight:700;
  cursor:pointer;
  white-space:nowrap;
  transition:background 0.15s,transform 0.1s;
}
.copy-btn:hover{background:var(--accent2);transform:scale(1.04);}
.copy-btn.copied{background:var(--accent2);}
.suggest-none{padding:14px;color:var(--muted);font-style:italic;}

/* ── Footer ─────────────────────────────────────────────────────────── */
footer{
  text-align:center;
  padding:20px;
  color:var(--muted);
  font-size:0.75rem;
  border-top:1px solid var(--border);
  margin-top:20px;
}
</style>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Courier+Prime:wght@400;700&family=IBM+Plex+Sans:wght@400;600&display=swap" rel="stylesheet">
</head>
<body>

<!-- ── Top Bar ───────────────────────────────────────────────────────── -->
<div class="topbar">
  <div>
    <h1>&#9632; Apache <span>&amp; WordPress</span> Dashboard | ${SITE_ADDRESS}</h1>
    <div class="refresh-note">Auto-refreshes every 2 minutes &bull; Log: ${LOG_FILE}</div>
  </div>
  <div style="text-align:right;">
    <div class="timestamp">&#128337; Last updated: ${GENERATED_AT}</div>
  </div>
</div>

<div class="main">

<!-- ── Traffic Overview ─────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#128200;</span>Traffic Overview</div>
  <div class="cards">
    <div class="card c1">
      <div class="card-label">Total Requests (all time)</div>
      <div class="card-value">${TOTAL_REQUESTS}</div>
    </div>
    <div class="card c2">
      <div class="card-label">Requests Today</div>
      <div class="card-value">${TOTAL_TODAY}</div>
    </div>
    <div class="card c4">
      <div class="card-label">Last 5 Minutes</div>
      <div class="card-value">${REQ_5MIN}</div>
    </div>
    <div class="card c4">
      <div class="card-label">Last 15 Minutes</div>
      <div class="card-value">${REQ_15MIN}</div>
    </div>
    <div class="card c4">
      <div class="card-label">Last 60 Minutes</div>
      <div class="card-value">${REQ_60MIN}</div>
    </div>
    <div class="card c3">
      <div class="card-label">Total 404s</div>
      <div class="card-value">${TOTAL_404}</div>
    </div>
    <div class="card c5">
      <div class="card-label">Unique IPs (all)</div>
      <div class="card-value">${UNIQUE_IPS_ALL}</div>
    </div>
    <div class="card c5">
      <div class="card-label">Unique IPs Today</div>
      <div class="card-value">${UNIQUE_IPS_TODAY}</div>
    </div>
    <div class="card c6">
      <div class="card-label">Bandwidth (all)</div>
      <div class="card-value" style="font-size:1.4rem">${TOTAL_BW}</div>
    </div>
    <div class="card c6">
      <div class="card-label">Bandwidth Today</div>
      <div class="card-value" style="font-size:1.4rem">${TOTAL_BW_TODAY}</div>
    </div>
    <div class="card c5" style="grid-column:span 2;">
      <div class="card-label">Oldest Log Entry in Dataset</div>
      <div class="card-value" style="font-size:1.1rem">${OLDEST_LOG_DISPLAY}</div>
      <div class="card-sub">&#128336; ${OLDEST_LOG_AGE}</div>
    </div>
  </div>
</section>

<!-- ── Hourly Chart ──────────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#128336;</span>Hourly Requests (Today)</div>
  <div class="panel">
    <div class="panel-head">Requests per hour &bull; Peak: ${PEAK_HOUR:-N/A}</div>
    <div class="chart-wrap">
      <canvas id="hourChart" height="120" style="width:100%;display:block;"></canvas>
    </div>
  </div>
</section>

<!-- ── Status Codes + Top IPs ───────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#128203;</span>Status Codes &amp; Top Visitors</div>
  <div class="grid-2">
    <div class="panel">
      <div class="panel-head">HTTP Status Code Breakdown</div>
      <div class="panel-body">
        <table>
          <thead><tr><th>Code</th><th>Requests</th></tr></thead>
          <tbody>${STATUS_ROWS}</tbody>
        </table>
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">Top 20 IP Addresses</div>
      <div class="panel-body">
$(make_table "${TOP_IPS}" "Requests" "IP Address")
      </div>
    </div>
  </div>
</section>

<!-- ── Top URLs + Top Pages ─────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#128279;</span>Content &amp; URLs</div>
  <div class="grid-2">
    <div class="panel">
      <div class="panel-head">Top 20 Requested URLs</div>
      <div class="panel-body">
$(make_table "${TOP_URLS}" "Requests" "URL")
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">Top 20 Pages (excluding static assets)</div>
      <div class="panel-body">
$(make_table "${TOP_PAGES}" "Requests" "Page")
      </div>
    </div>
  </div>
</section>

<!-- ── WordPress ────────────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#127760;</span>WordPress Activity</div>
  <div class="panel">
    <div class="panel-head">WordPress-specific endpoints</div>
    <div class="wp-grid">
      <div class="wp-item">
        <div class="wlabel">wp-login.php hits</div>
        <div class="wvalue">${WP_LOGIN}</div>
      </div>
      <div class="wp-item">
        <div class="wlabel">xmlrpc.php hits</div>
        <div class="wvalue">${XMLRPC}</div>
      </div>
      <div class="wp-item">
        <div class="wlabel">wp-json API hits</div>
        <div class="wvalue">${WP_JSON}</div>
      </div>
      <div class="wp-item">
        <div class="wlabel">wp-admin hits</div>
        <div class="wvalue">${WP_ADMIN}</div>
      </div>
      <div class="wp-item">
        <div class="wlabel">wp-cron hits</div>
        <div class="wvalue">${WP_CRON}</div>
      </div>
    </div>
  </div>
</section>

<!-- ── 404s ─────────────────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#10060;</span>Top 404 Not Found URLs</div>
  <div class="panel">
    <div class="panel-head">Top 20 missing resources</div>
    <div class="panel-body">
$(make_table "${TOP_404}" "404 Count" "URL")
    </div>
  </div>
</section>

<!-- ── Bandwidth ─────────────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#128225;</span>Bandwidth</div>
  <div class="grid-2">
    <div class="panel">
      <div class="panel-head">Bandwidth by Hour (Today)</div>
      <div class="panel-body">
        <table>
          <thead><tr><th>Hour</th><th>Transferred</th></tr></thead>
          <tbody>${BW_ROWS}</tbody>
        </table>
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">Top 20 Largest Responses</div>
      <div class="panel-body">
$(make_table "${TOP_LARGE}" "Size" "URL")
      </div>
    </div>
  </div>
</section>

<!-- ── Security ─────────────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#128737;</span>Security</div>
  $(if [[ -n "${SUSPICIOUS_IPS}" ]]; then
    echo '<div class="alert-row"><span class="alert-icon">&#9888;</span><div><strong>Suspicious IPs detected</strong> (&gt;500 requests today)</div></div>'
  fi)
  <div class="grid-2">
    <div class="panel">
      <div class="panel-head">Suspicious IPs (&gt;500 requests today)</div>
      <div class="panel-body">
$(if [[ -n "${SUSPICIOUS_IPS}" ]]; then make_table "${SUSPICIOUS_IPS}" "Requests" "IP"; else echo '<p style="padding:14px;color:var(--muted);">None detected ✔</p>'; fi)
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">Bad Bot Activity (unique IPs with 4xx/5xx)</div>
      <div class="panel-body" style="padding:16px;">
        <table>
          <thead><tr><th>Endpoint</th><th>Unique Attacker IPs</th></tr></thead>
          <tbody>
            <tr><td>/wp-admin/ (errors)</td><td class="num">${BAD_BOT_WP_ADMIN}</td></tr>
            <tr><td>xmlrpc.php (errors)</td><td class="num">${BAD_BOT_XMLRPC}</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</section>

<!-- ── Bots & User Agents ────────────────────────────────────────────── -->
<section>
  <div class="section-title"><span class="icon">&#129302;</span>Bots &amp; User Agents</div>
  <div class="grid-3">
    <div class="panel" style="grid-column:span 2;">
      <div class="panel-head">Top 20 User Agents</div>
      <div class="panel-body">
$(make_table "${TOP_UA}" "Requests" "User Agent")
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">Bot Traffic Split</div>
      <div class="bot-bar-wrap">
        <div class="bot-bar-label">
          <span>&#129302; Bots: ${BOT_PCT}%</span>
          <span>&#128100; Humans: ${HUMAN_PCT}%</span>
        </div>
        <div class="bot-bar-outer">
          <div class="bot-bar-human" style="width:${HUMAN_PCT}%"></div>
          <div class="bot-bar-bot"   style="width:${BOT_PCT}%"></div>
        </div>
        <div class="bot-summary">
          <span><span class="bot-dot" style="background:var(--accent2)"></span>Human: ${HUMAN_REQS}</span>
          <span><span class="bot-dot" style="background:var(--accent4)"></span>Bot: ${BOT_REQS}</span>
        </div>
      </div>
      <div class="panel-head" style="margin-top:10px;">Known Search Engine Bots</div>
      <table>
        <thead><tr><th>Bot</th><th>Hits</th></tr></thead>
        <tbody>
          <tr><td>Googlebot</td><td class="num">${GOOGLEBOT}</td></tr>
          <tr><td>Bingbot</td><td class="num">${BINGBOT}</td></tr>
          <tr><td>Facebookbot</td><td class="num">${FACEBOOKBOT}</td></tr>
          <tr><td>Twitterbot</td><td class="num">${TWITTERBOT}</td></tr>
          <tr><td>SemrushBot</td><td class="num">${SEMRUSHBOT}</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</section>

$(if [[ -n "${GEO_TABLE}" ]]; then
cat << GEOF
<section>
  <div class="section-title"><span class="icon">&#127758;</span>Geographic Distribution</div>
  <div class="panel">
    <div class="panel-head">Top 20 Countries (via geoiplookup)</div>
    <div class="panel-body">
$(make_table "${GEO_TABLE}" "Requests" "Country")
    </div>
  </div>
</section>
GEOF
fi)

$(if [[ "${F2B_AVAILABLE}" -eq 1 ]]; then
cat << F2BEOF
<section>
  <div class="section-title"><span class="icon">&#128680;</span>Fail2Ban</div>
  <div class="cards" style="margin-bottom:20px;">
    <div class="card c3">
      <div class="card-label">Active Jails</div>
      <div class="card-value">${F2B_JAIL_COUNT}</div>
    </div>
    <div class="card c3">
      <div class="card-label">Currently Banned IPs</div>
      <div class="card-value">${F2B_TOTAL_BANNED}</div>
    </div>
  </div>
  <div class="grid-2">
    <div class="panel">
      <div class="panel-head">Jail Statistics</div>
      <div class="panel-body">
        <table>
          <thead><tr><th>Jail</th><th>Failed Attempts</th><th>Total Banned</th><th>Currently Banned</th></tr></thead>
          <tbody>${F2B_JAIL_ROWS}</tbody>
        </table>
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">Currently Banned IPs (most recent first)</div>
      <div class="panel-body">
        <table>
          <thead><tr><th>IP Address</th><th>Country</th></tr></thead>
          <tbody>${F2B_BANNED_ROWS:-<tr><td colspan='2' style='padding:14px;color:var(--muted)'>No IPs currently banned ✔</td></tr>}</tbody>
        </table>
      </div>
    </div>
  </div>
</section>
F2BEOF
fi)

<section>
  <div class="section-title"><span class="icon">&#128161;</span>Suggested Fail2Ban Filters</div>
  <div class="panel">
    <div class="panel-head">Attack patterns detected in log that may not be covered by active jails &bull; Copy command to enable blocking</div>
    <div class="panel-body">
$(if [[ -n "${SUGGEST_ROWS}" ]]; then
echo '<table>
  <thead><tr><th>Hits</th><th>Pattern</th><th>Enable Command</th></tr></thead>
  <tbody>'"${SUGGEST_ROWS}"'</tbody>
</table>'
else
echo '<p class="suggest-none">&#10004; No unhandled high-priority attack patterns detected — your current fail2ban configuration appears to be covering the active threats.</p>'
fi)
    </div>
  </div>
</section>

</div><!-- /.main -->

<footer>
  Apache &amp; WordPress Dashboard | ${SITE_ADDRESS} &bull; Generated ${GENERATED_AT} &bull; Auto-refresh every 2 min
</footer>

<!-- ── Inline Chart (Canvas) ─────────────────────────────────────────── -->
<script>
(function(){
  const data = { ${CHART_DATA} };
  const canvas = document.getElementById('hourChart');
  if(!canvas) return;
  const ctx = canvas.getContext('2d');
  const W = canvas.parentElement.clientWidth || 900;
  const H = 140;
  canvas.width  = W;
  canvas.height = H;

  const max = Math.max(...data.values, 1);
  const pad = {top:10, right:20, bottom:30, left:48};
  const barW = Math.floor((W - pad.left - pad.right) / data.labels.length);
  const chartH = H - pad.top - pad.bottom;

  // Grid lines
  ctx.strokeStyle = '#30363d';
  ctx.lineWidth = 1;
  for(let i=0;i<=4;i++){
    const y = pad.top + chartH - (chartH * i / 4);
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(W - pad.right, y); ctx.stroke();
    ctx.fillStyle = '#8b949e';
    ctx.font = '10px monospace';
    ctx.textAlign = 'right';
    ctx.fillText(Math.round(max * i / 4), pad.left - 6, y + 4);
  }

  // Bars
  data.values.forEach((v, i) => {
    const bH = Math.max(2, (v / max) * chartH);
    const x  = pad.left + i * barW + 2;
    const y  = pad.top + chartH - bH;
    // Gradient
    const grad = ctx.createLinearGradient(0, y, 0, y + bH);
    grad.addColorStop(0,   '#58a6ff');
    grad.addColorStop(0.5, '#3fb950');
    grad.addColorStop(1,   '#1f6feb');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.roundRect(x, y, barW - 4, bH, [3, 3, 0, 0]);
    ctx.fill();

    // X label (every 2 hours)
    if(i % 2 === 0){
      ctx.fillStyle = '#8b949e';
      ctx.font = '9px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(data.labels[i], x + (barW - 4) / 2, H - 6);
    }
  });
})();

// Copy-to-clipboard for suggested filter commands
function copyCmd(blockId) {
  const block = document.getElementById(blockId);
  if (!block) return;
  const text = block.querySelector('code').innerText;
  navigator.clipboard.writeText(text).then(function() {
    const btn = block.querySelector('.copy-btn');
    const orig = btn.innerHTML;
    btn.innerHTML = '&#10003; Copied!';
    btn.classList.add('copied');
    setTimeout(function() { btn.innerHTML = orig; btn.classList.remove('copied'); }, 2000);
  }).catch(function() {
    // Fallback for older browsers
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    const btn = block.querySelector('.copy-btn');
    const orig = btn.innerHTML;
    btn.innerHTML = '&#10003; Copied!';
    btn.classList.add('copied');
    setTimeout(function() { btn.innerHTML = orig; btn.classList.remove('copied'); }, 2000);
  });
}
</script>
</body>
</html>
HTMLEOF

echo "Dashboard written to: ${OUTPUT_FILE}"
echo "Stats: ${TOTAL_REQUESTS} total requests, ${TOTAL_TODAY} today, generated at ${GENERATED_AT}"

# ---------------------------------------------------------------------------
# Debug output
# ---------------------------------------------------------------------------
DEBUG_FILE="${OUTPUT_DIR}/debug.txt"
cat > "${DEBUG_FILE}" << DEBUGEOF
================================================================================
 Apache Stats Debug Output
 Generated: ${GENERATED_AT}
 Log file:  ${LOG_FILE}
================================================================================

--- ENVIRONMENT ---
Script dir:   ${SCRIPT_DIR}
Output dir:   ${OUTPUT_DIR}
Today string: ${TODAY}
Now (epoch):  ${NOW_EPOCH}

--- TRAFFIC COUNTS ---
Total requests (all time): ${TOTAL_REQUESTS}
Total requests (today):    ${TOTAL_TODAY}
Requests last  5 min:      ${REQ_5MIN}
Requests last 15 min:      ${REQ_15MIN}
Requests last 60 min:      ${REQ_60MIN}
Oldest log entry:          ${OLDEST_LOG_DISPLAY} (${OLDEST_LOG_AGE})
Oldest log epoch:          ${OLDEST_EPOCH:-unknown}

--- UNIQUE IPs ---
Unique IPs (all time): ${UNIQUE_IPS_ALL}
Unique IPs (today):    ${UNIQUE_IPS_TODAY}

--- BANDWIDTH ---
Total bytes (all):   ${TOTAL_BYTES}  (${TOTAL_BW})
Total bytes (today): ${TOTAL_BYTES_TODAY}  (${TOTAL_BW_TODAY})

--- STATUS CODE BREAKDOWN ---
${STATUS_BREAKDOWN:-"(empty)"}

--- TOP 20 IPs ---
${TOP_IPS:-"(empty)"}

--- TOP 20 URLs ---
${TOP_URLS:-"(empty)"}

--- TOP 20 PAGES (no static assets) ---
${TOP_PAGES:-"(empty)"}

--- TOP 20 404 URLs ---
Total 404s: ${TOTAL_404}
${TOP_404:-"(empty)"}

--- WORDPRESS ---
wp-login.php hits: ${WP_LOGIN}
xmlrpc.php hits:   ${XMLRPC}
wp-json hits:      ${WP_JSON}
wp-admin hits:     ${WP_ADMIN}
wp-cron hits:      ${WP_CRON}

--- BANDWIDTH BY HOUR (today) ---
${BW_BY_HOUR:-"(empty)"}

--- REQUESTS BY HOUR (today) ---
${REQ_BY_HOUR:-"(empty)"}
Peak hour: ${PEAK_HOUR:-"(none yet)"}

--- SUSPICIOUS IPs (>500 req today) ---
${SUSPICIOUS_IPS:-"(none)"}

--- BAD BOT ACTIVITY ---
wp-admin errors (unique IPs): ${BAD_BOT_WP_ADMIN}
xmlrpc errors  (unique IPs):  ${BAD_BOT_XMLRPC}

--- BOT / HUMAN SPLIT ---
Total requests: ${TOTAL_REQUESTS}
Bot requests:   ${BOT_REQS}  (${BOT_PCT}%)
Human requests: ${HUMAN_REQS}  (${HUMAN_PCT}%)

--- KNOWN GOOD BOTS ---
Googlebot:   ${GOOGLEBOT}
Bingbot:     ${BINGBOT}
Facebookbot: ${FACEBOOKBOT}
Twitterbot:  ${TWITTERBOT}
SemrushBot:  ${SEMRUSHBOT}

--- TOP 20 USER AGENTS ---
${TOP_UA:-"(empty — check log format is Combined, not Common)"}

--- GEO TABLE ---
${GEO_TABLE:-"(geoiplookup not installed or no data)"}

--- SITE ---
Site address:   ${SITE_ADDRESS}
WP config used: ${WP_CONFIG:-"(not found — used fallback)"}
Page refresh:   120 seconds

--- IP FILTERING ---
Excluded subnets/IPs: 10.98.0.0/16, 78.131.56.62, 127.0.0.0/8
Lines in TMP_ALL after filter:   $(wc -l < "${TMP_ALL}")
Lines in TMP_TODAY after filter: $(wc -l < "${TMP_TODAY}")

--- FAIL2BAN ---
Available:            ${F2B_AVAILABLE}
jail.local path:      ${F2B_JAIL_LOCAL:-"(not used)"}
Active jails:         ${F2B_JAIL_COUNT:-0}
Jail list (enabled):  ${F2B_JAIL_LIST:-"(none)"}
Currently banned IPs: ${F2B_TOTAL_BANNED}  (sum of per-jail counts)
Jail stats (HTML):
${F2B_JAIL_ROWS:-"(no data)"}
Banned IPs (ordered most-recent first):
${F2B_BANNED_IPS:-"(none)"}

--- SUGGESTED FAIL2BAN FILTERS ---
(each line: hits|label|description|command)
${SUGGESTED_FILTERS:-"(none — all detected patterns appear to be covered)"}

--- TOP 20 LARGEST RESPONSES (smart-sized) ---
${TOP_LARGE:-"(empty)"}

--- TOP 20 LARGEST RESPONSES (raw bytes) ---
${TOP_LARGE_RAW:-"(empty)"}

================================================================================
 End of debug output
================================================================================
DEBUGEOF

echo "Debug output written to: ${DEBUG_FILE}"
