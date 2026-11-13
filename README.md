# webstats

A self-contained Bash script that analyses Apache and WordPress access logs and generates a colourful, auto-refreshing HTML dashboard. Designed for Debian/Ubuntu servers running Apache 2.4 with WordPress.

---

## Features

- Traffic overview: total requests, recent requests, unique visitor IPs, bandwidth, and age of oldest log entry
- Hourly request chart and HTTP status code breakdown
- Top IPs, URLs, pages, 404 URLs, largest responses, and user agents
- WordPress endpoint metrics and bot/human traffic split
- Suspicious IPs, bad bot activity, and known good bot counts
- Optional geographic distribution via `geoiplookup`
- Optional Fail2ban statistics and suggested filters
- Configurable IP exclusions and support for rotated logs
- Auto-refreshing dashboard and debug output

## Requirements

### Required

| Package | Purpose | Install |
|---------|---------|---------|
| Bash 4.0+ | Script runtime | Pre-installed |
| awk (mawk or gawk) | Log parsing | Pre-installed |
| bc | Bandwidth calculations | `apt install bc` |

### Optional

| Package | Purpose | Install |
|---------|---------|---------|
| geoip-bin | Country lookups | `apt install geoip-bin geoip-database` |
| fail2ban | Security statistics | `apt install fail2ban` |

### Apache log format

Combined Log Format is required for user-agent and referrer data. Check your virtualhost configuration:

```apache
CustomLog ${APACHE_LOG_DIR}/access.log combined
```

If it says `common`, change it to `combined`, then validate and restart Apache:

```bash
apachectl configtest
systemctl restart apache2
```

Without Combined format the dashboard still works, but user-agent data, the bot/human split, and known good bot counts will be empty.

---

## Installation

Install the script at `/opt/scripts/webstats.sh`:

```bash
mkdir -p /opt/scripts
curl -o /opt/scripts/webstats.sh \
  https://raw.githubusercontent.com/ash34/webstats/main/webstats.sh
chmod +x /opt/scripts/webstats.sh
```

The script writes the dashboard and debug file to `/opt/scripts/output/` when installed at this path.

## Configuration

Configuration variables are near the top of the script. Most can also be overridden with environment variables at runtime.

### Site address

The dashboard domain is detected in this order: `SITE_ADDRESS`, `WP_HOME` or `WP_SITEURL` in common WordPress configuration paths, Apache `ServerName`, then `localhost`.

Override it at runtime:

```bash
SITE_ADDRESS="example.com" /opt/scripts/webstats.sh
```

To set a permanent default, edit the `SITE_ADDRESS` assignment near the top of the script. Bare domains and subdomains are supported.

### Log file

Defaults to `/var/log/apache2/access.log`. Override it with:

```bash
APACHE_LOG="/var/log/apache2/mysite_access.log" /opt/scripts/webstats.sh
```

### Output directory

By default, output is written to an `output/` directory alongside the script. For an installation at `/opt/scripts/webstats.sh`, this is `/opt/scripts/output/`. To change it, edit `OUTPUT_DIR` near the top of the script.

### IP exclusion

Edit the `filter_excluded_ips` function to configure excluded addresses and subnets. The default exclusions are defined in the script.

### Fail2ban jail filtering

The script reads `/etc/fail2ban/jail.local` and includes running jails that are enabled there. If `jail.local` does not exist, all running jails are included.

---

## Running the script

```bash
/opt/scripts/webstats.sh
```

Expected output:

```
Dashboard written to: /opt/scripts/output/index.html
Debug output written to: /opt/scripts/output/debug.txt
Stats: 4821 total requests, 312 today, generated at 2026-04-30 10:36:49 CEST
```

### Serving the dashboard

Symlink the output directory into your web root:

```bash
ln -s /opt/scripts/output /var/www/html/webstats
```

Then browse to `http://yourserver/webstats/`. Alternatively, point a dedicated Apache virtualhost at the output directory. Restrict access by IP or authentication: the dashboard contains information about server traffic and security configuration.

---

## Scheduling

Run the script regularly so statistics are refreshed throughout the day.

### Option A — cron

Add to root's crontab with `crontab -e`:

```cron
*/2 * * * * /opt/scripts/webstats.sh >> /var/log/webstats.log 2>&1
```

This runs every two minutes. Use `*/5` instead of `*/2` to run every five minutes. Verify with `crontab -l`.

### Option B — systemd service and timer

Create `/etc/systemd/system/webstats.service`:

```ini
[Unit]
Description=Apache & WordPress Log Dashboard Generator
Documentation=https://github.com/ash34/webstats
After=network.target apache2.service

[Service]
Type=oneshot
ExecStart=/opt/scripts/webstats.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=webstats
User=root
```

Create `/etc/systemd/system/webstats.timer`:

```ini
[Unit]
Description=Run Apache Stats dashboard generator every 2 minutes
Requires=webstats.service

[Timer]
OnBootSec=30
OnUnitActiveSec=2min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start the timer:

```bash
systemctl daemon-reload
systemctl enable webstats.timer
systemctl start webstats.timer
```

Check its status with `systemctl status webstats.timer` or `systemctl list-timers webstats.timer`. View logs with `journalctl -u webstats.service -f`. Run immediately with `systemctl start webstats.service`.

---

## Clearing the log and starting fresh

To reset the log without losing Apache's open file handle:

```bash
truncate -s 0 /var/log/apache2/access.log
```

Do not use `rm` on the active log. To reset the dashboard and regenerate it:

```bash
rm /opt/scripts/output/index.html
/opt/scripts/webstats.sh
```

## Output files

| File | Description |
|------|-------------|
| `/opt/scripts/output/index.html` | Dashboard to open in a browser |
| `/opt/scripts/output/debug.txt` | Plain-text dump of computed values for troubleshooting |

## Troubleshooting

**Dashboard shows zero requests:** Check that the log exists, is readable, and uses Combined format:

```bash
ls -lh /var/log/apache2/access.log
tail -5 /var/log/apache2/access.log
cat /opt/scripts/output/debug.txt
```

**User agents are empty or the bot split is 0%:** Apache may be logging in Common rather than Combined format; see [Apache log format](#apache-log-format).

**All-time total equals today's total:** This is expected after log truncation or a recent setup. Check that rotated logs are accumulating with `ls -lh /var/log/apache2/access.log*`.

**Site address shows `localhost`:** Set it explicitly, for example `SITE_ADDRESS="example.com" /opt/scripts/webstats.sh`.

**`bc: command not found`:** Install it with `apt install bc`.

**Fail2ban section is missing:** Check that `fail2ban-client` is installed and reachable with `which fail2ban-client` and `fail2ban-client status`.

**Suggested Fail2ban filters section is empty:** Detected patterns may already be covered by active jails, or there may not be enough traffic to meet the thresholds.

## Security considerations

- The script reads `/var/log/apache2/` and `/etc/fail2ban/`, so it typically runs as root. If you prefer not to run it as root, grant a dedicated user read access and adjust the service accordingly.
- Restrict access to `/opt/scripts/output/` using Apache IP restrictions or HTTP basic authentication.
- Suggested Fail2ban commands are informational only; they must be copied and run manually. The dashboard does not execute them.

## Compatibility

| Component | Tested version |
|-----------|---------------|
| Debian | 12 (Bookworm) |
| TurnKey GNU/Linux | 18.0 |
| Apache | 2.4 |
| Bash | 5.2 |
| awk | mawk 1.3.4 |
| fail2ban | 1.0+ |

The script uses POSIX-compatible awk and standard Bash 4+ features, and should work on modern Debian or Ubuntu systems.

## Roadmap

- Python rewrite for better performance on high-traffic servers
- Live mode with a lightweight web server
- Email or webhook alerts when attack thresholds are exceeded
- Multi-site support
- Automatic Fail2ban rule activation via a local companion API

## Licence

MIT — see [LICENSE](LICENSE) for details.

## Contributing

Pull requests are welcome. Please test against a real Apache Combined Format access log before submitting. Include relevant `output/debug.txt` information in bug reports.
