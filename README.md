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
| Installation | Not installed, missing/damaged files, service not registered | Download the latest signed MSI → silent install/repair (retries, removes a broken old install, falls back to curl/BITS/winget) |
| Windows service | Stopped, disabled, manual, stuck *Pending*, no crash recovery | Start / force-restart (kills a hung `tailscaled.exe`), set to Automatic, restart-on-crash |
| Service responding | CLI can't talk to the daemon (“failed to connect to process”), hung daemon | Restart the service |
| Network adapter | Missing or disabled Tailscale adapter | Enable it / restart the service |
| System clock | Clock off by minutes (this breaks TLS) | Resync, or set it from internet time if NTP is blocked |
| DNS | `tailscale.com` blocked or sinkholed by a DNS filter (compared with 1.1.1.1) | Flush DNS |
| Reachability | Internet works but Tailscale ports are blocked, or there's no internet at all | – (explains where the block is) |
| Proxy | Dead machine-wide (WinHTTP) proxy, which the SYSTEM service uses | Remove it (asks first) |
| **TLS interception** | Antivirus or proxy re-signing HTTPS to Tailscale (**the Bitdefender case**); shows whose certificate is in the way | – (gives exact per-vendor steps) |
| Security software | Bitdefender, Kaspersky, ESET, Avast, Norton, Zscaler, and more | Defender exclusion (optional) |
| Other VPNs | Another VPN connected or grabbing the default route | – |
| Windows Firewall | Rules blocking Tailscale, outbound blocked by default | Add allow rules, disable block rules |
| Control-plane handshake | `tailscale debug ts2021`, the decisive “can this PC register at all” test | – |
| Login state | NeedsLogin, NeedsMachineAuth, Stopped, stuck Starting, expiring key, health warnings | Log in (auth key or browser), connect, **unattended mode** |
| Netcheck | UDP blocked (relay-only), no DERP relay reachable | – |
| Version | Outdated client | Update |
| Policies | Registry policies (custom login server, unattended forbidden) | – |
| State files | Corrupted `server-state.conf` | Back up and reset (asks first) |
| Logs | Known error patterns in the recent `tailscaled` log | Bug-report ID for Tailscale support |

**About "Timeout waiting for Tailscale service to enter a Running state":** *Running* is Tailscale's internal login state, not the Windows service status. The doctor reports both separately and names the real blocker. Usually that's "not logged in" (NeedsLogin), which in turn is usually caused by a network or antivirus block that stops login from reaching `controlplane.tailscale.com`.

## Safety

- It listens only on `127.0.0.1`, on a random port, and every request needs a random per-run token. It also checks Host and Origin headers, so other websites and other PCs can't use it.
- Auth keys are passed only to the local `tailscale` CLI. They are never written to disk, and they're redacted from logs and reports.
- Downloaded installers are checked for a valid **Tailscale Inc.** Authenticode signature before running.
- Every external command runs with a hard timeout, so a hung `tailscale.exe` can't freeze the tool.
- Destructive actions (reset state, log out, removing a proxy, disabling firewall rules) always ask first.
- Log: `C:\ProgramData\TailscaleDoctor\doctor-YYYYMMDD.log`. Use **Save report** or **Copy summary** to send results to someone.

## Files

- `TailscaleDoctor.cmd`: launcher (picks 64-bit PowerShell, bypasses execution policy)
- `TailscaleDoctor.ps1`: all checks and fixes, plus the local web server
- `web/`: the browser UI (plain HTML/CSS/JS)
