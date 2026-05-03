# webstats

A self-contained Bash script that analyses Apache and WordPress access logs and generates a colourful, auto-refreshing HTML dashboard. Designed for Debian/Ubuntu servers running Apache 2.4 with WordPress.

---

## Features

- **Traffic overview** — total requests (all-time and today), requests in the last 5, 15 and 60 minutes, unique visitor IPs, total bandwidth served, and the age of the oldest log entry in the dataset
- **Hourly request chart** — canvas bar chart of requests per hour for the current day
- **HTTP status code breakdown** — colour-coded badges (2xx green, 3xx blue, 4xx amber, 5xx red)
- **Top 20 IPs, URLs and pages** — the pages view excludes static assets (CSS, JS, images, fonts)
- **Top 20 404 not-found URLs** — useful for spotting broken links or active scanning
- **Top 20 largest responses** — human-readable sizes (B / KB / MB / GB) with a maximum of 3 significant digits
- **WordPress-specific metrics** — `wp-login.php`, `xmlrpc.php`, `wp-json`, `wp-admin` and `wp-cron` hit counts
- **Bot and human traffic split** — heuristic detection across a broad pattern list
- **Known good bot counts** — Googlebot, Bingbot, Facebookbot, Twitterbot, SemrushBot
- **Top 20 user agents**
- **Security** — suspicious IPs (>500 requests today), bad bot activity targeting `wp-admin` and `xmlrpc`
- **Geographic distribution** — country breakdown via `geoiplookup` (optional)
- **Fail2ban integration** — active jails cross-referenced with `jail.local`, per-jail statistics sorted by failed attempts, currently banned IPs with country lookup ordered by most-recently-banned
- **Suggested fail2ban filters** — detects attack patterns not covered by active jails and provides copy-to-clipboard commands to enable blocking
- **IP exclusion** — subnets and individual addresses excluded from all statistics (internal networks, loopback, known-safe IPs)
- **Rotated log support** — includes `.log.1` and `.log.gz` rotated archives in all-time totals
- **Auto-refresh** — page refreshes every 2 minutes
- **Debug output** — `output/debug.txt` written alongside the dashboard for troubleshooting

---

## Requirements

### Required

| Package | Purpose | Install |
|---------|---------|---------|
| bash 4.0+ | Script runtime | Pre-installed |
| awk (mawk or gawk) | Log parsing | Pre-installed |
| bc | Bandwidth calculations | `apt install bc` |

### Optional but recommended

| Package | Purpose | Install |
|---------|---------|---------|
| geoip-bin | Country lookups | `apt install geoip-bin geoip-database` |
| fail2ban | Security statistics | `apt install fail2ban` |

### Apache log format

The script requires **Combined Log Format** to populate user agent and referrer data. Check your virtualhost configuration:

```apache
CustomLog ${APACHE_LOG_DIR}/access.log combined
```

If it says `common` instead of `combined`, change it and restart Apache:

```bash
apachectl configtest
systemctl restart apache2
```

Without Combined format the dashboard still works, but user agent data, the bot/human split, and known good bot counts will all be empty.

---

## Installation

```bash
# Create the scripts directory
mkdir -p /opt/scripts

# Clone the repository
git clone https://github.com/yourusername/apache_stats.git /opt/scripts/apache_stats

# Make the script executable
chmod +x /opt/scripts/apache_stats/apache_stats.sh
```

Or download the script directly:

```bash
curl -o /opt/scripts/apache_stats.sh \
  https://raw.githubusercontent.com/yourusername/apache_stats/main/apache_stats.sh
chmod +x /opt/scripts/apache_stats.sh
```

---

## Configuration

All configuration variables are at the top of the script. Most can also be overridden with environment variables at runtime without editing the file.

### Site address

The dashboard title includes your site's domain name, detected automatically in this order:

1. `SITE_ADDRESS` environment variable (highest priority)
2. `WP_HOME` or `WP_SITEURL` from `wp-config.php` (checked in common WordPress install paths)
3. `ServerName` from Apache's enabled site configurations
4. Falls back to `localhost`

To override at runtime:

```bash
SITE_ADDRESS="example.com" /opt/scripts/apache_stats.sh
```

To set a permanent default, edit line ~24 of the script:

```bash
SITE_ADDRESS="${SITE_ADDRESS:-example.com}"
```

Both bare domains (`example.com`) and subdomains (`sub.example.com`) are supported.

### Log file path

Defaults to `/var/log/apache2/access.log`. Override with:

```bash
APACHE_LOG="/var/log/apache2/mysite_access.log" /opt/scripts/apache_stats.sh
```

### Output directory

Defaults to `./output/` relative to the script's location. To change it, edit `OUTPUT_DIR` near the top of the script:

```bash
OUTPUT_DIR="/var/www/html/stats"
```

### IP exclusion

The script excludes specified addresses from all statistics. Edit the `filter_excluded_ips` function to suit your network. The defaults exclude:

- `10.98.0.0/16` — example internal subnet
- `73.11.2.2` — example known-safe IP
- `127.0.0.0/8` — loopback

### Fail2ban jail filtering

The script reads `/etc/fail2ban/jail.local` and includes only jails with `enabled = true`. Jails with `enabled = false` are silently excluded. If `jail.local` does not exist, all running jails are included.

---

## Running the script

```bash
/opt/scripts/apache_stats.sh
```

Expected output:

```
Dashboard written to: /opt/scripts/output/index.html
Debug output written to: /opt/scripts/output/debug.txt
Stats: 4821 total requests, 312 today, generated at 2026-04-30 10:36:49 CEST
```

### Serving the dashboard

Symlink the `output/` directory into your web root:

```bash
ln -s /opt/scripts/output /var/www/html/stats
```

Then browse to `http://yourserver/stats/`.

Alternatively, point a dedicated Apache virtualhost at the output directory. **Restrict access by IP** so the dashboard is not publicly accessible — it contains information about your server's traffic and security posture.

---

## Scheduling

The script is designed to run on a regular schedule so statistics accumulate throughout the day. Two approaches are supported.

---

### Option A — cron

Edit root's crontab with `crontab -e` and add:

```cron
*/2 * * * * /opt/scripts/apache_stats.sh >> /var/log/apache_stats.log 2>&1
```

This runs every 2 minutes, matching the page's auto-refresh interval. Errors are captured in `/var/log/apache_stats.log`.

To run every 5 minutes instead:

```cron
*/5 * * * * /opt/scripts/apache_stats.sh >> /var/log/apache_stats.log 2>&1
```

Verify the entry is active:

```bash
crontab -l
```

---

### Option B — systemd service and timer

Systemd timers are the recommended modern alternative to cron. Benefits over cron include better logging via `journalctl`, dependency management, and precise scheduling with catch-up on missed runs.

**Step 1 — Create the service unit**

Create `/etc/systemd/system/apache-stats.service`:

```ini
[Unit]
Description=Apache & WordPress Log Dashboard Generator
Documentation=https://github.com/yourusername/apache_stats
After=network.target apache2.service

[Service]
Type=oneshot
ExecStart=/opt/scripts/apache_stats.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=apache-stats
User=root
```

**Step 2 — Create the timer unit**

Create `/etc/systemd/system/apache-stats.timer`:

```ini
[Unit]
Description=Run Apache Stats dashboard generator every 2 minutes
Requires=apache-stats.service

[Timer]
# Run 30 seconds after boot so the dashboard is populated quickly after a restart
OnBootSec=30
# Then repeat every 2 minutes
OnUnitActiveSec=2min
AccuracySec=10s
# Re-run any missed executions (e.g. after system was suspended)
Persistent=true

[Install]
WantedBy=timers.target
```

**Step 3 — Enable and start**

```bash
systemctl daemon-reload
systemctl enable apache-stats.timer
systemctl start apache-stats.timer
```

**Verify the timer is running:**

```bash
systemctl status apache-stats.timer
systemctl list-timers apache-stats.timer
```

**View logs:**

```bash
# Follow live output
journalctl -u apache-stats.service -f

# View today's runs
journalctl -u apache-stats.service --since today

# View last 10 runs
journalctl -u apache-stats.service -n 50
```

**Trigger a run immediately without waiting for the timer:**

```bash
systemctl start apache-stats.service
```

**Stop and disable:**

```bash
systemctl stop apache-stats.timer
systemctl disable apache-stats.timer
```

---

## Clearing the log and starting fresh

To reset the log file without losing the file handle (Apache keeps the file open):

```bash
truncate -s 0 /var/log/apache2/access.log
```

Do **not** use `rm` — Apache would continue writing to the deleted inode until restarted, silently losing log data.

To also reset the dashboard:

```bash
rm /opt/scripts/output/index.html
/opt/scripts/apache_stats.sh
```

---

## Output files

| File | Description |
|------|-------------|
| `output/index.html` | The dashboard — open in any browser |
| `output/debug.txt` | Plain-text dump of every computed variable, for troubleshooting |

The debug file is always written alongside the dashboard. When a statistic looks wrong, checking the corresponding section in `debug.txt` will show the raw value before it was rendered into HTML, making it straightforward to identify parsing or calculation issues.

---

## Troubleshooting

**Dashboard shows zero requests**

Check that the log file exists and is readable, and that Combined log format is in use:

```bash
ls -lh /var/log/apache2/access.log
tail -5 /var/log/apache2/access.log
cat /opt/scripts/output/debug.txt
```

**User agents are empty / bot split is always 0%**

Apache is logging in Common format rather than Combined. See [Apache log format](#apache-log-format) above.

**All-time total equals today's total**

Expected when the log was recently truncated or the server was just set up. Once Apache's log rotation runs (usually nightly) and rotated files accumulate, the all-time total will grow beyond today's count. Check available history with:

```bash
ls -lh /var/log/apache2/access.log*
```

**Site address shows "localhost"**

The script could not auto-detect a domain. Set it explicitly:

```bash
SITE_ADDRESS="example.com" /opt/scripts/apache_stats.sh
```

**`bc: command not found`**

```bash
apt install bc
```

**Fail2ban section is missing from the dashboard**

`fail2ban-client` is not installed or not reachable. Verify with:

```bash
which fail2ban-client
fail2ban-client status
```

**Suggested fail2ban filters section is empty**

Either all detected attack patterns are already covered by active jails (which is the desired state), or there is insufficient traffic in the current log data to trigger the thresholds.

---

## Security considerations

- The script reads `/var/log/apache2/` and `/etc/fail2ban/` and so typically runs as root. If you prefer not to run as root, create a dedicated user with read access to those paths and adjust the service unit accordingly.
- Restrict access to the `output/` directory. It contains information about your server's traffic patterns and security configuration. Use Apache IP restrictions or HTTP basic auth.
- The suggested fail2ban commands shown in the dashboard are informational only. They must be manually copied and run in a terminal. The dashboard does not execute any commands automatically.

---

## Compatibility

| Component | Tested version |
|-----------|---------------|
| Debian | 12 (Bookworm) |
| TurnKey GNU/Linux | 18.0 |
| Apache | 2.4 |
| Bash | 5.2 |
| awk | mawk 1.3.4 |
| fail2ban | 1.0+ |

The script uses only POSIX-compatible awk (no gawk extensions) and standard Bash 4+ features, so it should work on any reasonably modern Debian or Ubuntu system.

---

## Roadmap

- Python rewrite for better performance on high-traffic servers (100k+ requests per day)
- Live mode with a lightweight web server for real-time updates
- Email or webhook alerting when attack thresholds are exceeded
- Multi-site support with multiple log files and separate dashboards
- Automatic fail2ban rule activation via a local companion API

---

## Licence

MIT — see [LICENSE](LICENSE) for details.

---

## Contributing

Pull requests are welcome. Please test against a real Apache Combined Format access log before submitting. The `output/debug.txt` file is the primary tool for verifying that statistics are computed correctly — include relevant debug output in any bug reports.
