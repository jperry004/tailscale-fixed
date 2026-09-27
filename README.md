# Tailscale Doctor (Windows)

Installs Tailscale if it's missing, checks everything that can stop it from working, and fixes what can be fixed automatically. Anything it can't fix, it explains in plain English.

## How to use

1. Download or extract this whole folder. Keep `web\` next to the script.
2. Double-click **`TailscaleDoctor.cmd`** and click **Yes** on the admin prompt.
3. Your browser opens the doctor page. Click **Fix everything automatically**.
4. If it asks you to log in, paste an **auth key**, or use **Browser sign-in**.

Keep the black console window open while you use the page. Closing it stops the doctor.

It needs nothing extra: it uses the PowerShell that ships with Windows 10/11 and Server 2016+. It has no dependencies, needs no Node or Python, and doesn't load anything from a CDN.

**No browser, or the page won't load?** Run it in text mode:

```
powershell -ExecutionPolicy Bypass -File TailscaleDoctor.ps1 -Cli
```

This prints every check and saves a JSON report to `C:\ProgramData\TailscaleDoctor\`.

## What it checks (in order) and what it can fix

| Check | Finds | Automatic fix |
|---|---|---|
| Windows and permissions | Not admin, old Windows, pending reboot, low disk | – |
| Windows services Tailscale needs | IP Helper, Base Filtering Engine, DNS Client, Network List, Windows Installer, and others disabled by "debloat" tools (a cause of *"Service 'Tailscale' failed to start… sufficient privileges"*) | Restore default start types and start them (also runs automatically before any install) |
| Installation | Not installed, missing/damaged files, service not registered | Download the latest signed MSI → silent install/repair (retries, removes a broken old install, falls back to curl/BITS/winget) |
| Windows service | Stopped, disabled, manual, stuck *Pending*, no crash recovery | Start / force-restart (kills a hung `tailscaled.exe`), set to Automatic, restart-on-crash |
| Service responding | CLI can't talk to the daemon (“failed to connect to process”), hung daemon, an extra `tailscaled.exe` fighting the service, **TPM can't decrypt the state** (after a BIOS/TPM update, motherboard swap, disk migration or VM restore) | Restart the service; TPM recovery (moves the unreadable state aside, asks first) |
| Network adapter | Missing or disabled Tailscale adapter | Enable it / restart the service |
| System clock | Clock off by minutes (this breaks TLS) | Resync, or set it from internet time if NTP is blocked |
| DNS | `tailscale.com` blocked or sinkholed by a DNS filter (compared with 1.1.1.1) | Flush DNS |
| Reachability | Internet works but Tailscale ports are blocked, or there's no internet at all | – (explains where the block is) |
| Proxy | Dead machine-wide (WinHTTP) proxy, which the SYSTEM service uses | Remove it (asks first) |
| **TLS interception** | Antivirus or proxy re-signing HTTPS to Tailscale (**the Bitdefender case**); shows whose certificate is in the way | – (gives exact per-vendor steps) |
| Security software | Bitdefender, Kaspersky, ESET, Avast, Norton, Zscaler, and more | Defender exclusion (optional) |
| Other VPNs and routing | Another VPN connected or grabbing the default route; network "flapping" (Teredo/IPv6), which makes Tailscale reconnect constantly with high CPU in DNS Client | Disable Teredo |
| Windows Firewall | Rules blocking Tailscale, outbound blocked by default | Add allow rules, disable block rules |
| Control-plane handshake | `tailscale debug ts2021`, the decisive “can this PC register at all” test | – |
| Login state | NeedsLogin, NeedsMachineAuth, Stopped, stuck Starting, expiring key, health warnings, **offline exit node** (no internet at all) | Log in (auth key or browser), connect, **unattended mode**, stop using the exit node |
| Device names (MagicDNS) | Names like `my-server` don't resolve: DNS turned off, Tailscale resolver down, or domain Group Policy NRPT rules overriding Tailscale's | Re-apply Tailscale DNS, turn Tailscale DNS on |
| Reaching this PC | Tailscale network marked **Public** (blocks RDP, file sharing, ping), `set-network-category-failed`, ping blocked | Mark it Private; allow ping from Tailscale addresses only |
| Netcheck | UDP blocked (relay-only), no DERP relay reachable | – |
| Version | Outdated client | Update |
| Policies | Registry policies (custom login server, unattended forbidden) | – |
| State files | Corrupted `server-state.conf` | Back up and reset (asks first) |
| Self-healing watchdog | Nothing fixes Tailscale when it's stuck after sleep, a crash or a network change | Installs a SYSTEM scheduled task (at startup, every 10 minutes, and after wake from sleep) that starts or restarts the service only when it's stopped, hung or stuck. It never logs in or changes settings |
| Logs | Known error patterns in the recent `tailscaled` log | Bug-report ID for Tailscale support |

**About "Timeout waiting for Tailscale service to enter a Running state":** *Running* is Tailscale's internal login state, not the Windows service status. The doctor reports both separately and names the real blocker. Usually that's "not logged in" (NeedsLogin), which in turn is usually caused by a network or antivirus block that stops login from reaching `controlplane.tailscale.com`.

## Safety

- It listens only on `127.0.0.1`, on a random port, and every request needs a random per-run token. It also checks Host and Origin headers, so other websites and other PCs can't use it.
- Auth keys are passed only to the local `tailscale` CLI. They are never written to disk, and they're redacted from logs and reports.
- Downloaded installers are checked for a valid **Tailscale Inc.** Authenticode signature before running.
- Every external command runs with a hard timeout, so a hung `tailscale.exe` can't freeze the tool.
- Only one copy runs at a time. Launching it again reopens the running one.
- `C:\ProgramData\TailscaleDoctor` is restricted so only Administrators and SYSTEM can change it, because the watchdog runs from there. Old logs are cleaned up after 30 days.
- Every WMI query has a timeout. A failing check shows as an error on its own row and never stops the others.
- Destructive actions (reset state, log out, removing a proxy, disabling firewall rules) always ask first.
- Log: `C:\ProgramData\TailscaleDoctor\doctor-YYYYMMDD.log`. Use **Save report** or **Copy summary** to send results to someone.

## Tests / development

`TailscaleDoctor.ps1 -LoadOnly` loads all functions without starting anything, so checks and actions can be called directly (`Invoke-Check backend`, `Invoke-Action connect`) against a real or fake `tailscale.exe`.

## Files

- `TailscaleDoctor.cmd`: launcher (picks 64-bit PowerShell, bypasses execution policy)
- `TailscaleDoctor.ps1`: all checks and fixes, plus the local web server
- `web/`: the browser UI (plain HTML/CSS/JS)
