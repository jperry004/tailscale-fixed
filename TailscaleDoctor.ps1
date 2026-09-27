<#
.SYNOPSIS
    Tailscale Doctor - installs, diagnoses and repairs Tailscale on Windows.

.DESCRIPTION
    Starts a small web server on 127.0.0.1 (random port, random access token) and
    opens a browser UI. The UI runs checks one at a time and offers fixes.
    Everything that touches the system happens in this script, running as
    Administrator. Nothing listens on the network; only this PC can connect.

    Run it with TailscaleDoctor.cmd (double-click). That handles elevation and
    execution policy for you.

.PARAMETER Port
    Port to listen on. 0 (default) picks a free port.

.PARAMETER NoBrowser
    Do not open the browser automatically. The URL is printed in the console.

.PARAMETER Cli
    No web UI: run every check, print the results, save a JSON report, and exit.

.PARAMETER ReportPath
    Where -Cli writes its JSON report. Defaults to %ProgramData%\TailscaleDoctor.

.PARAMETER NoElevate
    Do not try to relaunch as Administrator. Most fixes will fail without admin.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$Cli,
    [string]$ReportPath,
    [switch]$NoElevate
)

# NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads BOM-less files
# as the ANSI code page, so any non-ASCII character here could break parsing.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# Last line of defence: never vanish silently. Show the error and wait.
trap {
    Write-Host ''
    Write-Host ('FATAL ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    try { Add-Content -Path $script:LogFile -Value ('[FATAL] ' + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage) } catch { }
    if (-not $NoBrowser) { try { [void](Read-Host 'Press Enter to close') } catch { } }
    exit 1
}
$script:DoctorVersion = '1.0.0'
$script:IsWin = ($env:OS -eq 'Windows_NT')
$script:Running = $true
$script:RebootNeeded = $false
$script:LoginProc = $null

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal $id
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

$script:IsAdmin = Test-Admin
if ($script:IsWin -and -not $script:IsAdmin -and -not $NoElevate) {
    try {
        $hostExe = (Get-Process -Id $PID).Path
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
        if ($Port) { $argList += @('-Port', "$Port") }
        if ($NoBrowser) { $argList += '-NoBrowser' }
        if ($Cli) { $argList += '-Cli' }
        if ($ReportPath) { $argList += @('-ReportPath', ('"' + $ReportPath + '"')) }
        if ($Cli) { $argList = @('-NoExit') + $argList }
        Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs | Out-Null
        Write-Host 'Relaunched as Administrator in a new window.'
        exit 0
    } catch {
        Write-Warning ('Could not get Administrator rights (' + $_.Exception.Message + ').')
        Write-Warning 'Continuing without admin: diagnostics work, but most fixes will fail.'
    }
}

# Windows PowerShell 5.1 may default to TLS 1.0 for web requests. Tailscale's
# servers need TLS 1.2+, so enable it explicitly (this alone breaks many scripts).
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Paths and logging
# ---------------------------------------------------------------------------

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:WebDir = Join-Path $script:ScriptDir 'web'
$dataRoot = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
$script:DataDir = Join-Path $dataRoot 'TailscaleDoctor'
try { New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null } catch {
    $script:DataDir = Join-Path ([IO.Path]::GetTempPath()) 'TailscaleDoctor'
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
}
$script:LogFile = Join-Path $script:DataDir ('doctor-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:LogSeq = 0

function Protect-Secrets([string]$Text) {
    if (-not $Text) { return $Text }
    # Auth keys, OAuth client secrets, and anything after --auth-key/--authkey.
    $t = $Text -replace 'tskey-[A-Za-z0-9_\-]+', 'tskey-***REDACTED***'
    $t = $t -replace '(--auth-?key[= ])\S+', '$1***REDACTED***'
    return $t
}

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $Message = Protect-Secrets $Message
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:LogSeq++
    $entry = [ordered]@{ seq = $script:LogSeq; time = $ts; level = $Level; message = $Message }
    [void]$script:LogBuffer.Add($entry)
    while ($script:LogBuffer.Count -gt 2000) { $script:LogBuffer.RemoveAt(0) }
    try { Add-Content -Path $script:LogFile -Value ("[$ts] [$Level] $Message") -Encoding UTF8 } catch { }
    if ($Cli -or $Level -ne 'debug') {
        $color = switch ($Level) { 'error' { 'Red' } 'warn' { 'Yellow' } 'debug' { 'DarkGray' } default { 'Gray' } }
        try { Write-Host ("[$ts] $Message") -ForegroundColor $color } catch { }
    }
}

function Get-InnerMessage($err) {
    $ex = $null
    if ($err -is [Management.Automation.ErrorRecord]) { $ex = $err.Exception } elseif ($err -is [Exception]) { $ex = $err } else { return [string]$err }
    $msgs = @()
    while ($ex) {
        if ($ex.Message -and -not ($msgs -contains $ex.Message)) { $msgs += $ex.Message }
        $ex = $ex.InnerException
    }
    # The innermost message is usually the useful one; keep the outer for context.
    if ($msgs.Count -gt 1) { return ($msgs[-1] + ' (' + $msgs[0] + ')') }
    return ($msgs -join '; ')
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

$script:Cache = @{}
function Get-Cached([string]$Key, [int]$TtlSec, [scriptblock]$Script) {
    $e = $script:Cache[$Key]
    if ($e -and ((Get-Date) - $e.t).TotalSeconds -lt $TtlSec) { return $e.v }
    $v = & $Script
    $script:Cache[$Key] = @{ t = (Get-Date); v = $v }
    return $v
}
function Clear-Cache { $script:Cache = @{} }

function ConvertTo-ArgString([string]$Arg) {
    # Standard Windows (CommandLineToArgvW) quoting rules.
    if ($null -eq $Arg) { return '""' }
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Stop-ProcessTree([int]$ProcessId) {
    if ($script:IsWin) {
        try {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = 'taskkill.exe'
            $psi.Arguments = "/PID $ProcessId /T /F"
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $k = [Diagnostics.Process]::Start($psi)
            [void]$k.WaitForExit(10000)
        } catch { }
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
}

# Runs a program with a hard timeout. Never throws; never hangs longer than
# TimeoutSec (+ a few seconds to collect output). This is the core of the
# robustness story: the tailscale CLI can block forever when the daemon is sick.
function Invoke-Proc {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 30,
        [switch]$Quiet
    )
    $r = [ordered]@{ ok = $false; exitCode = $null; stdout = ''; stderr = ''; output = ''; timedOut = $false; error = $null; durationMs = 0; command = '' }
    $argString = (@($Arguments) | ForEach-Object { ConvertTo-ArgString $_ }) -join ' '
    $r.command = Protect-Secrets ((Split-Path -Leaf $FilePath) + ' ' + $argString).Trim()
    if (-not $Quiet) { Write-Log ('> ' + $r.command) 'debug' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = $null
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        try {
            $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
            $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
        } catch { }
        $p = [Diagnostics.Process]::Start($psi)
        try { $p.StandardInput.Close() } catch { }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $r.timedOut = $true
            Write-Log ("Command timed out after ${TimeoutSec}s, killing it: " + $r.command) 'warn'
            Stop-ProcessTree $p.Id
        } else {
            $p.WaitForExit()
        }
        try { if ($outTask.Wait(5000)) { $r.stdout = [string]$outTask.Result } } catch { }
        try { if ($errTask.Wait(5000)) { $r.stderr = [string]$errTask.Result } } catch { }
        if (-not $r.timedOut) {
            $r.exitCode = $p.ExitCode
            $r.ok = ($p.ExitCode -eq 0)
        } else {
            $r.error = "Timed out after $TimeoutSec seconds"
        }
    } catch {
        $r.error = Get-InnerMessage $_
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
    }
    $sw.Stop()
    $r.durationMs = [int]$sw.ElapsedMilliseconds
    $r.stdout = Protect-Secrets $r.stdout
    $r.stderr = Protect-Secrets $r.stderr
    $r.output = ((@($r.stdout, $r.stderr) | Where-Object { $_ -and $_.Trim() }) -join "`n").Trim()
    return $r
}

function Get-Tail([string]$Text, [int]$Lines = 15) {
    if (-not $Text) { return '' }
    $all = $Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    return (@($all) | Select-Object -Last $Lines) -join "`n"
}

function Read-SharedText([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $sr = New-Object IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Read-FileTail([string]$Path, [int]$MaxBytes = 262144) {
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $len = $fs.Length
            if ($len -eq 0) { return '' }
            # Detect UTF-16LE (MSI verbose logs): BOM, or NULs in the first bytes.
            $head = New-Object byte[] ([Math]::Min(512, $len))
            $hn = $fs.Read($head, 0, $head.Length)
            $nuls = 0; for ($i = 1; $i -lt $hn; $i += 2) { if ($head[$i] -eq 0) { $nuls++ } }
            $utf16 = ($hn -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) -or ($hn -gt 8 -and $nuls -gt ($hn / 4))
            $start = [Math]::Max(0, $len - $MaxBytes)
            if ($utf16 -and ($start % 2)) { $start++ }
            [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($len - $start)
            $read = $fs.Read($buf, 0, $buf.Length)
            if ($utf16) { return [Text.Encoding]::Unicode.GetString($buf, 0, $read) }
            return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return '' }
}

# Splits a command line like the one tailscale prints in its suggestions.
function Split-CommandLine([string]$Line) {
    $out = @(); $cur = ''; $inQ = $false; $has = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"' -or $ch -eq "'") { $inQ = -not $inQ; $has = $true; continue }
        if (-not $inQ -and [char]::IsWhiteSpace($ch)) {
            if ($has) { $out += $cur; $cur = ''; $has = $false }
            continue
        }
        $cur += $ch; $has = $true
    }
    if ($has) { $out += $cur }
    return , $out
}

# Maps raw error text from tailscale / Windows into plain-English explanations.
function Get-ErrorHints([string]$Text) {
    $h = New-Object System.Collections.ArrayList
    if (-not $Text) { return , @() }
    $t = $Text
    if ($t -match 'x509|certificate signed by unknown authority|certificate is not trusted|tls: failed to verify|certificate verify failed|not valid for') {
        [void]$h.Add('Certificate problem: something is intercepting the encrypted connection to Tailscale (antivirus "encrypted/HTTPS web scan", a corporate proxy, or a parental-control filter), or the PC clock is wrong.')
    }
    if ($t -match 'i/o timeout|context deadline exceeded|TLS handshake timeout|dial tcp.*timeout|Client\.Timeout|timed out') {
        [void]$h.Add('Network timeout: this PC cannot reach the Tailscale servers. Typical causes: antivirus/firewall (e.g. Bitdefender), router or DNS filter, or another VPN taking over the internet connection.')
    }
    if ($t -match 'connection refused|actively refused|connectex') {
        [void]$h.Add('Connection refused: a firewall or proxy is rejecting connections to Tailscale.')
    }
    if ($t -match 'no such host|server misbehaving|lookup \S+ on|getaddrinfo|No such host is known') {
        [void]$h.Add('DNS failure: this PC cannot look up Tailscale server names. Check the DNS check below; a DNS filter (router, Pi-hole, NextDNS, antivirus) may be blocking tailscale.com.')
    }
    if ($t -match "failed to connect to local tailscaled|Is Tailscale running|doesn't appear to be running|failed to connect to process|The system cannot find the file specified|pipe") {
        [void]$h.Add('The Tailscale background service (tailscaled) is not answering. Use "Restart Tailscale service".')
    }
    if ($t -match 'invalid key|key.*(does not exist|not found|not valid|invalid)|API key does not exist|authkey.*(expired|invalid)|auth key.*(expired|invalid|used)') {
        [void]$h.Add('The auth key was rejected: it is mistyped, expired, revoked, or a one-time key that was already used. Create a new key at https://login.tailscale.com/admin/settings/keys.')
    }
    if ($t -match 'requested tags .* (are invalid|not permitted)|tag.*not permitted|tagOwner') {
        [void]$h.Add('Tag rejected: the tag must be defined in your tailnet policy (ACL) with you (or the auth key) as a tagOwner before a device can use it.')
    }
    if ($t -match 'Access is denied|access denied|permission denied|requires elevation') {
        [void]$h.Add('Access denied: run Tailscale Doctor as Administrator. If Tailscale is locked to another Windows user (unattended mode), that user must sign out of Tailscale, or use "Reset Tailscale state".')
    }
    if ($t -match 'another user|in use by|profile .* belongs to') {
        [void]$h.Add('Tailscale on this PC is owned by a different Windows user. Sign out in Tailscale as that user, or use "Reset Tailscale state".')
    }
    if ($t -match 'requires mentioning all non-default flags') {
        [void]$h.Add('Tailscale refused because existing settings would change. The doctor retries with your existing settings automatically.')
    }
    if ($t -match 'node key (has )?expired|key expired|NodeKeyExpired') {
        [void]$h.Add('This device''s login expired. Log in again, and consider disabling key expiry for this machine in the admin console.')
    }
    if ($t -match 'NeedsMachineAuth|machine is not (yet )?authorized|needs approval') {
        [void]$h.Add('A tailnet admin must approve this device at https://login.tailscale.com/admin/machines.')
    }
    if ($t -match 'wintun|tun device|CreateAdapter|create adapter|network adapter') {
        [void]$h.Add('The Tailscale network adapter (Wintun) failed. Restart the service; if that fails, reinstall; if that fails, reboot.')
    }
    if ($t -match 'proxy') {
        [void]$h.Add('A proxy is involved. Check the Proxy check below: the Tailscale service runs as SYSTEM and uses the machine-wide (WinHTTP) proxy settings.')
    }
    if ($t -match 'unknown subcommand|flag provided but not defined|unknown flag') {
        [void]$h.Add('This Tailscale version is too old for this command. Use "Update Tailscale".')
    }
    return , @($h)
}

# ---------------------------------------------------------------------------
# Network primitives (all with hard timeouts)
# ---------------------------------------------------------------------------

function Resolve-HostSafe([string]$Name, [int]$TimeoutMs = 6000) {
    $r = [ordered]@{ name = $Name; ok = $false; addresses = @(); error = $null; ms = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ar = [Net.Dns]::BeginGetHostAddresses($Name, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $r.error = "DNS lookup timed out after $TimeoutMs ms"
        } else {
            $addrs = [Net.Dns]::EndGetHostAddresses($ar)
            $r.addresses = @($addrs | ForEach-Object { $_.IPAddressToString })
            $r.ok = ($r.addresses.Count -gt 0)
            if (-not $r.ok) { $r.error = 'No addresses returned' }
        }
    } catch { $r.error = Get-InnerMessage $_ }
    $r.ms = [int]$sw.ElapsedMilliseconds
    return $r
}

function Test-SuspiciousIp([string]$Ip) {
    # Addresses a public Tailscale server name should never resolve to: these
    # mean a DNS filter/sinkhole (router, Pi-hole, antivirus, parental control).
    return ($Ip -match '^(0\.|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' -or $Ip -eq '::' -or $Ip -eq '::1' -or $Ip -match '^(fe80|fc|fd)')
}

function Test-Tcp([string]$HostName, [int]$Port, [int]$TimeoutMs = 6000) {
    $r = [ordered]@{ target = "${HostName}:$Port"; ok = $false; ms = $null; error = $null }
    $c = $null
    try {
        $c = New-Object Net.Sockets.TcpClient
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $r.error = "timed out after $TimeoutMs ms (packets silently dropped: typical of a firewall)"
        } else {
            $c.EndConnect($ar)
            $r.ok = $true
            $r.ms = [int]$sw.ElapsedMilliseconds
        }
    } catch { $r.error = Get-InnerMessage $_ }
    finally { if ($c) { try { $c.Close() } catch { } } }
    return $r
}

$script:InterceptorPatterns = @(
    'Bitdefender', 'Kaspersky', 'ESET', 'Avast', 'AVG', 'Norton', 'Symantec', 'McAfee', 'Sophos',
    'Zscaler', 'Netskope', 'Fortinet', 'FortiGate', 'Umbrella', 'OpenDNS', 'Palo Alto', 'Check Point',
    'Trend Micro', 'Webroot', 'Barracuda', 'Forcepoint', 'Blue Coat', 'Untangle', 'pfSense', 'SonicWall',
    'WatchGuard', 'Kerio', 'Dr.Web', 'F-Secure', 'Panda', 'Malwarebytes', 'Fiddler', 'Charles Proxy',
    'mitmproxy', 'PortSwigger', 'Burp', 'Qustodio', 'Net Nanny', 'Securly', 'Lightspeed', 'GoGuardian',
    'iboss', 'Cloudflare for Teams', 'Gateway CA', 'Cisco', 'Sectigo Proxy', 'Avira', 'Total Defense',
    'Emsisoft', 'G DATA', 'Comodo Dragon', 'Cyberoam', 'Sangfor', 'Smoothwall', 'ContentKeeper', 'Menlo'
)
$script:PublicCaPatterns = @(
    'ISRG', "Let's Encrypt", 'DigiCert', 'GlobalSign', 'Sectigo', 'USERTrust', 'COMODO', 'Google Trust',
    'GTS ', 'Amazon', 'Baltimore', 'Starfield', 'Go Daddy', 'GoDaddy', 'Entrust', 'Microsoft', 'IdenTrust',
    'Certum', 'QuoVadis', 'Buypass', 'SSL.com', 'Actalis', 'SwissSign', 'Telia', 'Certigna', 'Cloudflare Inc'
)

# Opens a TLS connection and captures the certificate chain the PC actually
# receives. If an antivirus or proxy intercepts HTTPS, the chain ends in THEIR
# root instead of a public CA - that is the smoking gun for the Bitdefender case.
function Get-TlsInfo([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 10000) {
    $r = [ordered]@{ host = $HostName; ok = $false; subject = $null; issuer = $null; root = $null; chain = @(); policyErrors = $null; protocol = $null; notAfter = $null; interceptor = $null; publicCa = $false; error = $null }
    $tcp = $null; $ssl = $null
    $state = @{ subject = $null; issuer = $null; chain = @(); errors = $null; notAfter = $null }
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout = $TimeoutMs
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "TCP connect timed out after $TimeoutMs ms" }
        $tcp.EndConnect($ar)
        $cb = {
            param($sender, $cert, $chain, $errors)
            try {
                $c2 = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cert
                $state.subject = $c2.Subject
                $state.issuer = $c2.Issuer
                $state.notAfter = $c2.NotAfter.ToString('yyyy-MM-dd')
                $state.errors = [string]$errors
                $list = @()
                if ($chain) { foreach ($el in $chain.ChainElements) { $list += $el.Certificate.Subject } }
                $state.chain = $list
            } catch { }
            return $true
        }.GetNewClosure()
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ([Net.Security.RemoteCertificateValidationCallback]$cb))
        try {
            $ssl.AuthenticateAsClient($HostName, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
        } catch {
            if ($state.subject) { throw }
            # Retry letting the OS pick the protocol (TLS 1.3 on newer Windows).
            $ssl.Dispose(); $tcp.Close()
            $tcp = New-Object Net.Sockets.TcpClient
            $tcp.ReceiveTimeout = $TimeoutMs; $tcp.SendTimeout = $TimeoutMs
            $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "TCP connect timed out after $TimeoutMs ms" }
            $tcp.EndConnect($ar)
            $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ([Net.Security.RemoteCertificateValidationCallback]$cb))
            $ssl.AuthenticateAsClient($HostName)
        }
        $r.protocol = [string]$ssl.SslProtocol
        $r.ok = $true
        $r.subject = $state.subject; $r.issuer = $state.issuer; $r.chain = @($state.chain)
        $r.policyErrors = $state.errors; $r.notAfter = $state.notAfter
        if ($r.chain.Count -gt 0) { $r.root = $r.chain[-1] } else { $r.root = $r.issuer }
    } catch {
        $r.error = Get-InnerMessage $_
        if ($state.subject) {
            $r.subject = $state.subject; $r.issuer = $state.issuer; $r.chain = @($state.chain); $r.policyErrors = $state.errors
        }
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        if ($tcp) { try { $tcp.Close() } catch { } }
    }
    $all = (@($r.issuer, $r.root) + @($r.chain)) -join ' | '
    if ($all.Trim(' |')) {
        foreach ($pat in $script:InterceptorPatterns) {
            if ($all -match [regex]::Escape($pat)) { $r.interceptor = $pat; break }
        }
        foreach ($pat in $script:PublicCaPatterns) {
            if ([string]$r.root -match [regex]::Escape($pat) -or [string]$r.issuer -match [regex]::Escape($pat)) { $r.publicCa = $true; break }
        }
    }
    return $r
}

function Invoke-Http([string]$Url, [int]$TimeoutMs = 15000, [int]$MaxBody = 65536) {
    $r = [ordered]@{ url = $Url; ok = $false; status = $null; date = $null; contentType = $null; body = ''; error = $null; ms = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.UserAgent = "TailscaleDoctor/$script:DoctorVersion"
        $req.AllowAutoRedirect = $true
        try { $resp = $req.GetResponse() } catch {
            $ex = $_.Exception
            while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
            if ($ex -and $ex.Response) { $resp = $ex.Response } else { throw }
        }
        $r.status = [int]$resp.StatusCode
        $r.contentType = $resp.ContentType
        $d = $resp.Headers['Date']
        if ($d) { try { $r.date = [DateTime]::Parse($d, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') } catch { } }
        $st = $resp.GetResponseStream()
        $buf = New-Object byte[] $MaxBody
        $total = 0
        while ($total -lt $MaxBody) {
            $n = $st.Read($buf, $total, $MaxBody - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        $r.body = [Text.Encoding]::UTF8.GetString($buf, 0, $total)
        $r.ok = ($r.status -ge 200 -and $r.status -lt 400)
    } catch { $r.error = Get-InnerMessage $_ }
    finally { if ($resp) { try { $resp.Close() } catch { } } }
    $r.ms = [int]$sw.ElapsedMilliseconds
    return $r
}

function Save-UrlToFile([string]$Url, [string]$Path, [int]$TimeoutSec = 300) {
    $tmp = $Path + '.part'
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 60000
        $req.UserAgent = "TailscaleDoctor/$script:DoctorVersion"
        $resp = $req.GetResponse()
        try {
            $st = $resp.GetResponseStream()
            $fs = [IO.File]::Create($tmp)
            try {
                $buf = New-Object byte[] 131072
                $deadline = (Get-Date).AddSeconds($TimeoutSec)
                while ($true) {
                    $n = $st.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $fs.Write($buf, 0, $n)
                    if ((Get-Date) -gt $deadline) { throw "Download took longer than $TimeoutSec s" }
                }
            } finally { $fs.Dispose() }
        } finally { $resp.Close() }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $null
    } catch {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        return (Get-InnerMessage $_)
    }
}

function Get-ClockSkew {
    # Seconds the local clock is AHEAD of real time (negative = behind).
    # Uses plain-HTTP Microsoft endpoint first, so it works even when TLS is broken.
    return Get-Cached 'clockskew' 60 {
        foreach ($u in @('http://www.msftconnecttest.com/connecttest.txt', 'https://controlplane.tailscale.com/key?v=71', 'http://www.google.com/generate_204')) {
            $h = Invoke-Http $u 8000 1024
            if ($h.date) {
                $skew = [int](([DateTime]::UtcNow - $h.date).TotalSeconds)
                return [ordered]@{ ok = $true; skewSec = $skew; source = $u }
            }
        }
        return [ordered]@{ ok = $false; skewSec = $null; source = $null }
    }
}

# ---------------------------------------------------------------------------
# Tailscale discovery
# ---------------------------------------------------------------------------

function Get-OsArch {
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch -regex ([string]$a) {
        'ARM64' { return 'arm64' }
        'AMD64|x64' { return 'amd64' }
        'x86' { return 'x86' }
        default { return 'amd64' }
    }
}

function Get-ProgramFilesDirs {
    $d = @()
    # ProgramW6432 is the real 64-bit Program Files even from 32-bit PowerShell.
    foreach ($v in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($v -and -not ($d -contains $v)) { $d += $v }
    }
    return $d
}

function Get-UninstallEntries {
    $out = @()
    if (-not $script:IsWin) { return }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try {
            Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Tailscale*' } | ForEach-Object {
                $out += [ordered]@{ name = $_.DisplayName; version = $_.DisplayVersion; location = $_.InstallLocation; productCode = $_.PSChildName; uninstall = $_.UninstallString }
            }
        } catch { }
    }
    return $out
}

function Get-ServiceInfo {
    $r = [ordered]@{ exists = $false; state = $null; startMode = $null; path = $null; exePath = $null; processId = $null; error = $null }
    if (-not $script:IsWin) { $r.error = 'Not Windows'; return $r }
    try {
        $s = Get-CimInstance -ClassName Win32_Service -Filter "Name='Tailscale'" -ErrorAction Stop
        if ($s) {
            $r.exists = $true; $r.state = $s.State; $r.startMode = $s.StartMode; $r.path = $s.PathName; $r.processId = $s.ProcessId
        }
    } catch {
        try {
            $s = Get-Service -Name Tailscale -ErrorAction Stop
            $r.exists = $true; $r.state = [string]$s.Status; $r.startMode = [string]$s.StartType
        } catch { $r.error = Get-InnerMessage $_ }
    }
    if ($r.path) {
        $m = [regex]::Match($r.path, '^\s*"([^"]+)"|^\s*(\S+)')
        $r.exePath = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    }
    return $r
}

function Get-TsPaths {
    $r = [ordered]@{ cli = $null; daemon = $null; gui = $null; dir = $null }
    $dirs = @()
    foreach ($pf in (Get-ProgramFilesDirs)) { $dirs += (Join-Path $pf 'Tailscale') }
    foreach ($e in @(Get-UninstallEntries)) { if ($e.location) { $dirs += $e.location } }
    $svc = Get-ServiceInfo
    if ($svc.exePath) { $dirs += (Split-Path -Parent $svc.exePath) }
    try { $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue; if ($cmd) { $dirs += (Split-Path -Parent $cmd.Source) } } catch { }
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        $cli = Join-Path $d 'tailscale.exe'
        if (-not $r.cli -and (Test-Path -LiteralPath $cli)) { $r.cli = $cli; $r.dir = $d }
        $dm = Join-Path $d 'tailscaled.exe'
        if (-not $r.daemon -and (Test-Path -LiteralPath $dm)) { $r.daemon = $dm; if (-not $r.dir) { $r.dir = $d } }
        $gui = Join-Path $d 'tailscale-ipn.exe'
        if (-not $r.gui -and (Test-Path -LiteralPath $gui)) { $r.gui = $gui }
    }
    if (-not $r.dir -and $dirs.Count) { $r.dir = $dirs[0] }
    return $r
}

function Get-TsExe { return (Get-TsPaths).cli }

function Invoke-Ts([string[]]$TsArgs, [int]$TimeoutSec = 30) {
    $exe = Get-TsExe
    if (-not $exe) {
        return [ordered]@{ ok = $false; exitCode = $null; stdout = ''; stderr = ''; output = ''; timedOut = $false; error = 'tailscale.exe was not found. Install Tailscale first.'; durationMs = 0; command = 'tailscale ' + ($TsArgs -join ' ') }
    }
    return Invoke-Proc -FilePath $exe -Arguments $TsArgs -TimeoutSec $TimeoutSec
}

function Get-TsVersion {
    return Get-Cached 'tsversion' 30 {
        $v = Invoke-Ts @('version') 15
        if ($v.ok -and $v.stdout) {
            $line = ($v.stdout -split "`r?`n")[0].Trim()
            if ($line -match '^(\d+\.\d+\.\d+)') { return $Matches[1] }
            return $line
        }
        $exe = Get-TsExe
        if ($exe) { try { $fv = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion; if ($fv -match '(\d+\.\d+\.\d+)') { return $Matches[1] } } catch { } }
        return $null
    }
}

function Get-TsStatus {
    return Get-Cached 'status' 4 {
        $r = [ordered]@{ reachable = $false; json = $null; error = $null; raw = ''; timedOut = $false }
        if (-not (Get-TsExe)) { $r.error = 'tailscale.exe not found'; return $r }
        $p = Invoke-Ts @('status', '--json', '--peers=false') 20
        if ($p.output -match 'flag provided but not defined|unknown flag') { $p = Invoke-Ts @('status', '--json') 25 }
        $r.raw = Get-Tail $p.output 40
        $r.timedOut = $p.timedOut
        if ($p.timedOut) { $r.error = 'tailscale status did not answer within 20 seconds: the service is hung.'; return $r }
        $txt = ([string]$p.stdout).Trim()
        $i = $txt.IndexOf('{')
        if ($i -ge 0) {
            try {
                $r.json = $txt.Substring($i) | ConvertFrom-Json
                $r.reachable = $true
            } catch { $r.error = 'Could not parse tailscale status output: ' + (Get-InnerMessage $_) }
        } else {
            $r.error = if ($p.stderr.Trim()) { Get-Tail $p.stderr 10 } elseif ($p.error) { $p.error } else { 'No output from tailscale status (exit code ' + $p.exitCode + ')' }
        }
        return $r
    }
}

function Get-TsPrefs {
    return Get-Cached 'prefs' 4 {
        $p = Invoke-Ts @('debug', 'prefs') 15
        $txt = ([string]$p.stdout).Trim()
        $i = $txt.IndexOf('{')
        if ($i -ge 0) { try { return ($txt.Substring($i) | ConvertFrom-Json) } catch { } }
        return $null
    }
}

function Get-LatestRelease {
    return Get-Cached 'latest' 600 {
        $arch = Get-OsArch
        $r = [ordered]@{ ok = $false; version = $null; msi = $null; url = $null; error = $null }
        $h = Invoke-Http 'https://pkgs.tailscale.com/stable/?mode=json' 15000 262144
        if ($h.ok) {
            try {
                $j = $h.body | ConvertFrom-Json
                $r.version = @($j.MSIsVersion, $j.Version, $j.TarballsVersion) | Where-Object { $_ } | Select-Object -First 1
                if ($j.MSIs -and $j.MSIs.$arch) { $r.msi = $j.MSIs.$arch }
                $r.ok = $true
            } catch { $r.error = 'Could not parse release list: ' + (Get-InnerMessage $_) }
        } else { $r.error = if ($h.error) { $h.error } else { "HTTP $($h.status)" } }
        if (-not $r.msi) { $r.msi = "tailscale-setup-latest-$arch.msi" }
        $r.url = 'https://pkgs.tailscale.com/stable/' + $r.msi
        return $r
    }
}

function Compare-Version([string]$A, [string]$B) {
    try {
        $va = [version](($A -split '[^0-9.]')[0])
        $vb = [version](($B -split '[^0-9.]')[0])
        return $va.CompareTo($vb)
    } catch { return 0 }
}

function Get-TsLogDir {
    foreach ($base in @($env:ProgramData, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        foreach ($sub in @('Tailscale\Logs', 'Tailscale')) {
            $d = Join-Path $base $sub
            if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -File -Filter '*tailscaled*' -ErrorAction SilentlyContinue).Count) { return $d }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------

function New-Result([string]$Id, [string]$Title) {
    return [ordered]@{ id = $Id; title = $Title; status = 'ok'; summary = ''; details = @(); advice = @(); fixes = @(); data = [ordered]@{}; durationMs = 0 }
}

$script:Severity = @{ ok = 0; skip = 0; info = 1; warn = 2; fail = 3; error = 3 }
function Set-Status($R, [string]$Status, [string]$Summary) {
    if ($script:Severity[$Status] -ge $script:Severity[$R.status]) {
        $R.status = $Status
        if ($Summary) { $R.summary = $Summary }
    } elseif ($Summary -and -not $R.summary) { $R.summary = $Summary }
}

function New-Fix([string]$Action, [string]$Label, [switch]$Auto, [string]$Confirm, $Params, [switch]$Primary) {
    $f = [ordered]@{ action = $Action; label = $Label; auto = [bool]$Auto; primary = [bool]$Primary }
    if ($Confirm) { $f.confirm = $Confirm }
    if ($Params) { $f.params = $Params }
    return $f
}

function Add-Fix($R, $Fix) {
    foreach ($f in $R.fixes) { if ($f.action -eq $Fix.action) { return } }
    $R.fixes += , $Fix
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

function Test-System {
    $r = New-Result 'system' 'Windows and permissions'
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    $ver = [Environment]::OSVersion.Version
    $caption = if ($os) { $os.Caption } else { [Environment]::OSVersion.VersionString }
    $r.data.os = $caption
    $r.data.build = [string]$ver
    $r.data.arch = Get-OsArch
    $r.data.computer = $env:COMPUTERNAME
    $r.data.powershell = [string]$PSVersionTable.PSVersion
    $r.data.admin = $script:IsAdmin
    $r.details += "OS: $caption (build $ver, $($r.data.arch))"
    $r.details += "Computer name: $env:COMPUTERNAME"
    $r.details += "PowerShell: $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"
    $r.summary = "$caption, $($r.data.arch)"

    if (-not $script:IsWin) { Set-Status $r 'warn' 'Not running on Windows: most checks will be skipped or fail.' }
    elseif ($ver.Major -lt 10) { Set-Status $r 'fail' 'Windows 10 / Server 2016 or newer is required by current Tailscale versions.' }

    if (-not $script:IsAdmin) {
        Set-Status $r 'fail' 'Not running as Administrator: fixes will fail.'
        $r.advice += 'Close this window and the console, then right-click TailscaleDoctor.cmd and choose "Run as administrator".'
    } else { $r.details += 'Running as Administrator: yes' }

    if ($script:IsWin) {
        $pending = @()
        try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Windows servicing' } } catch { }
        try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' } } catch { }
        if ($script:RebootNeeded) { $pending += 'Tailscale installer' }
        if ($pending.Count) {
            Set-Status $r 'warn' ('A reboot is pending (' + ($pending -join ', ') + ').')
            $r.advice += 'Pending reboots can leave network drivers (including the Tailscale adapter) half-installed. If problems persist after fixes, reboot and run the doctor again.'
        }
        try {
            $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction Stop
            $freeMb = [int]($disk.FreeSpace / 1MB)
            $r.details += "Free space on ${sysDrive}: $freeMb MB"
            if ($freeMb -lt 500) { Set-Status $r 'warn' "Very low disk space on $sysDrive ($freeMb MB). Installs and Tailscale state writes can fail." }
        } catch { }
    }
    return $r
}

function Test-Install {
    $r = New-Result 'install' 'Tailscale installation'
    $paths = Get-TsPaths
    $svc = Get-ServiceInfo
    $entries = @(Get-UninstallEntries)
    $r.data.paths = $paths
    foreach ($e in $entries) { $r.details += "Installed program entry: $($e.name) $($e.version)" }
    if ($paths.cli) { $r.details += "CLI: $($paths.cli)" }
    if ($paths.daemon) { $r.details += "Service binary: $($paths.daemon)" }
    if ($paths.gui) { $r.details += "Tray app: $($paths.gui)" }

    if (-not $paths.cli -and -not $paths.daemon) {
        Set-Status $r 'fail' 'Tailscale is not installed.'
        Add-Fix $r (New-Fix 'install' 'Install Tailscale' -Auto -Primary)
        if ($svc.exists) { $r.details += 'A Tailscale service is registered but its files are missing (broken uninstall).' }
        return $r
    }
    if (-not $paths.cli) {
        Set-Status $r 'fail' 'tailscale.exe (command-line tool) is missing: the installation is damaged.'
        Add-Fix $r (New-Fix 'repair' 'Repair (reinstall) Tailscale' -Auto -Primary)
    }
    if (-not $paths.daemon) {
        Set-Status $r 'fail' 'tailscaled.exe (the service) is missing: the installation is damaged.'
        Add-Fix $r (New-Fix 'repair' 'Repair (reinstall) Tailscale' -Auto -Primary)
    }
    if ($svc.exePath -and -not (Test-Path -LiteralPath $svc.exePath)) {
        Set-Status $r 'fail' "The Tailscale service points to a file that does not exist ($($svc.exePath))."
        Add-Fix $r (New-Fix 'repair' 'Repair (reinstall) Tailscale' -Auto -Primary)
    }
    if (-not $svc.exists -and $script:IsWin) {
        Set-Status $r 'fail' 'Tailscale files exist but the Windows service is not registered.'
        Add-Fix $r (New-Fix 'repair' 'Repair (reinstall) Tailscale' -Auto -Primary)
    }
    $v = Get-TsVersion
    $r.data.version = $v
    if ($v) { $r.details += "Version: $v" }
    if ($r.status -eq 'ok') { $r.summary = "Installed" + $(if ($v) { ", version $v" } else { '' }) }
    Add-Fix $r (New-Fix 'repair' 'Reinstall Tailscale' -Confirm 'Reinstall Tailscale over the existing installation? Your login and settings are kept.')
    return $r
}

function Test-Service {
    $r = New-Result 'service' 'Tailscale Windows service'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $svc = Get-ServiceInfo
    $r.data.service = $svc
    if (-not $svc.exists) {
        $paths = Get-TsPaths
        Set-Status $r 'fail' 'The Tailscale service is not installed.'
        if ($paths.cli -or $paths.daemon) { Add-Fix $r (New-Fix 'repair' 'Repair (reinstall) Tailscale' -Auto -Primary) }
        else { Add-Fix $r (New-Fix 'install' 'Install Tailscale' -Auto -Primary) }
        return $r
    }
    $r.details += "State: $($svc.state)"
    $r.details += "Start type: $($svc.startMode)"
    if ($svc.path) { $r.details += "Command: $($svc.path)" }
    if ($svc.processId) { $r.details += "Process ID: $($svc.processId)" }

    switch -regex ([string]$svc.startMode) {
        'Disabled' {
            Set-Status $r 'fail' 'The service is DISABLED, so Tailscale can never start.'
            Add-Fix $r (New-Fix 'harden-service' 'Set service to Automatic' -Auto -Primary)
        }
        'Manual' {
            Set-Status $r 'warn' 'The service is set to Manual start: Tailscale will not start after a reboot.'
            Add-Fix $r (New-Fix 'harden-service' 'Set service to Automatic' -Auto)
        }
    }
    switch -regex ([string]$svc.state) {
        '^Running$' { if ($r.status -eq 'ok') { $r.summary = 'Running, starts automatically' } }
        'Pending' {
            Set-Status $r 'fail' "The service is stuck in '$($svc.state)'."
            Add-Fix $r (New-Fix 'restart-service' 'Force-restart the service' -Auto -Primary)
        }
        default {
            Set-Status $r 'fail' "The service is not running (state: $($svc.state))."
            Add-Fix $r (New-Fix 'start-service' 'Start the service' -Auto -Primary)
        }
    }

    # Recovery options: restart automatically if tailscaled ever crashes.
    $q = Invoke-Proc 'sc.exe' @('qfailure', 'Tailscale') 10 -Quiet
    $hasRecovery = ($q.stdout -match 'RESTART')
    $r.data.recovery = $hasRecovery
    if ($hasRecovery) { $r.details += 'Crash recovery: restarts automatically' }
    else {
        $r.details += 'Crash recovery: not configured'
        Set-Status $r 'warn' 'If the service crashes, Windows will not restart it (no recovery actions).'
        Add-Fix $r (New-Fix 'harden-service' 'Enable auto-restart on crash' -Auto)
    }

    # Recent Service Control Manager errors about Tailscale.
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddDays(-2); Level = @(1, 2, 3) } -MaxEvents 300 -ErrorAction Stop |
            Where-Object { $_.Message -match 'Tailscale' } | Select-Object -First 5
        foreach ($e in $ev) { $r.details += ("Event " + $e.TimeCreated.ToString('yyyy-MM-dd HH:mm') + ': ' + ($e.Message -replace '\s+', ' ')) }
        if (@($ev).Count -and $svc.state -ne 'Running') { $r.advice += 'Windows logged service errors above; they usually name the cause.' }
    } catch { }
    Add-Fix $r (New-Fix 'restart-service' 'Restart the service')
    return $r
}

function Test-Daemon {
    $r = New-Result 'daemon' 'Tailscale service responding'
    if (-not (Get-TsExe)) { $r.status = 'skip'; $r.summary = 'Tailscale is not installed'; return $r }
    $st = Get-TsStatus
    if ($st.reachable) {
        $r.summary = 'The service answers commands.'
        $r.details += "Backend state: $($st.json.BackendState)"
        if ($st.json.Version) { $r.details += "Daemon version: $($st.json.Version)" }
        return $r
    }
    $svc = Get-ServiceInfo
    if ($st.timedOut) { Set-Status $r 'fail' 'The service is running but hung: it does not answer within 20 seconds.' }
    elseif ($svc.exists -and $svc.state -ne 'Running') { Set-Status $r 'fail' 'The service is not running, so the CLI cannot talk to it.' }
    else { Set-Status $r 'fail' 'The Tailscale CLI cannot talk to the service.' }
    if ($st.error) { $r.details += "Error: $($st.error)" }
    if ($st.raw) { $r.details += "Output:`n$($st.raw)" }
    foreach ($h in (Get-ErrorHints ([string]$st.error + ' ' + $st.raw))) { $r.advice += $h }
    $r.advice += 'This is also what you see as "failed to connect to process" after killing Tailscale in Task Manager. Restarting the service fixes it.'
    if ($svc.exists) { Add-Fix $r (New-Fix 'restart-service' 'Restart Tailscale service' -Auto -Primary) }
    else { Add-Fix $r (New-Fix 'repair' 'Repair (reinstall) Tailscale' -Auto -Primary) }
    return $r
}

function Test-Backend {
    $r = New-Result 'backend' 'Login and connection state'
    if (-not (Get-TsExe)) { $r.status = 'skip'; $r.summary = 'Tailscale is not installed'; return $r }
    $st = Get-TsStatus
    if (-not $st.reachable) { $r.status = 'skip'; $r.summary = 'Service is not responding (see above)'; return $r }
    $j = $st.json
    $state = [string]$j.BackendState
    $r.data.backendState = $state
    $r.details += "BackendState: $state"
    if ($j.AuthURL) { $r.data.authUrl = $j.AuthURL; $r.details += "Pending login URL: $($j.AuthURL)" }
    if ($j.CurrentTailnet -and $j.CurrentTailnet.Name) { $r.details += "Tailnet: $($j.CurrentTailnet.Name)"; $r.data.tailnet = $j.CurrentTailnet.Name }
    if ($j.Self) {
        if ($j.Self.HostName) { $r.details += "Device name: $($j.Self.HostName)" }
        if ($j.Self.DNSName) { $r.details += "DNS name: $($j.Self.DNSName)" }
        if ($j.TailscaleIPs) { $r.details += ('Tailscale IPs: ' + (@($j.TailscaleIPs) -join ', ')); $r.data.ips = @($j.TailscaleIPs) }
        if ($j.Self.Tags) { $r.details += ('Tags: ' + (@($j.Self.Tags) -join ', ')) }
    }
    $r.details += 'Note: the tray app''s "Timeout waiting for Tailscale service to enter a Running state" refers to this BackendState, not the Windows service.'

    switch ($state) {
        'Running' {
            $r.summary = 'Connected' + $(if ($j.TailscaleIPs) { ' as ' + (@($j.TailscaleIPs)[0]) } else { '' })
        }
        'NeedsLogin' {
            Set-Status $r 'fail' 'Not logged in. Tailscale waits at "NeedsLogin" forever until you log in; this is what makes the tray app time out.'
            Add-Fix $r (New-Fix 'show-login' 'Log in now' -Primary)
            $r.advice += 'Log in with an auth key (best for business machines) or in the browser. If login hangs, fix any red network checks first: login needs to reach controlplane.tailscale.com.'
        }
        'NeedsMachineAuth' {
            Set-Status $r 'fail' 'Logged in, but a tailnet admin must approve this device.'
            $r.advice += 'Open https://login.tailscale.com/admin/machines, find this computer and click Approve. Or use a pre-approved auth key.'
        }
        'Stopped' {
            Set-Status $r 'fail' 'Logged in but disconnected (Tailscale was turned off).'
            Add-Fix $r (New-Fix 'connect' 'Connect' -Auto -Primary)
        }
        'Starting' {
            Set-Status $r 'fail' 'Stuck in "Starting": logged in but cannot reach Tailscale''s servers.'
            $r.advice += 'This almost always means a network block. Look at the DNS, Reachability, Secure connection, Security software and Control-plane handshake checks.'
            Add-Fix $r (New-Fix 'restart-service' 'Restart Tailscale service')
        }
        'NoState' {
            Set-Status $r 'fail' 'The service has not finished starting ("NoState").'
            Add-Fix $r (New-Fix 'restart-service' 'Restart Tailscale service' -Auto -Primary)
        }
        default { Set-Status $r 'warn' "Unexpected state '$state'." }
    }

    if ($j.Health) {
        foreach ($h in @($j.Health)) {
            if (-not $h) { continue }
            $r.details += "Tailscale health warning: $h"
            foreach ($x in (Get-ErrorHints $h)) { $r.advice += $x }
            if ($state -eq 'Running') { Set-Status $r 'warn' ('Connected, with warnings: ' + $h) }
        }
    }

    if ($j.Self -and $j.Self.KeyExpiry) {
        try {
            $exp = [DateTime]::Parse([string]$j.Self.KeyExpiry, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal')
            $days = [int]($exp - [DateTime]::UtcNow).TotalDays
            $r.details += ('Login (node key) expires: ' + $exp.ToString('yyyy-MM-dd') + " ($days days)")
            if ($days -lt 0) {
                Set-Status $r 'fail' 'This device''s login has EXPIRED.'
                Add-Fix $r (New-Fix 'show-login' 'Log in again' -Primary)
            } elseif ($days -lt 14) {
                Set-Status $r 'warn' "This device's login expires in $days days; it will then disconnect."
            }
            if ($days -lt 60) { $r.advice += 'For an always-on business machine, disable key expiry: admin console > Machines > this device > ... > Disable key expiry. Or use a tagged auth key.' }
        } catch { }
    }

    if ($state -eq 'Running' -or $state -eq 'Stopped' -or $state -eq 'Starting') {
        $prefs = Get-TsPrefs
        if ($prefs) {
            $r.data.unattended = [bool]$prefs.ForceDaemon
            $r.details += ('Unattended mode (stay connected when no one is signed in to Windows): ' + $(if ($prefs.ForceDaemon) { 'on' } else { 'off' }))
            if ($prefs.ControlURL -and $prefs.ControlURL -notmatch 'tailscale\.com') { $r.details += "Custom control server: $($prefs.ControlURL)" }
            if (-not $prefs.ForceDaemon) {
                Set-Status $r 'warn' $(if ($state -eq 'Running') { 'Connected, but it will disconnect when you sign out of Windows (unattended mode off).' } else { $null })
                Add-Fix $r (New-Fix 'enable-unattended' 'Turn on unattended mode' -Auto)
            }
        }
    }
    if ($state -eq 'Running' -and $j.Self -and ($j.Self.PSObject.Properties.Name -contains 'Online') -and -not $j.Self.Online) {
        Set-Status $r 'warn' 'Running, but the coordination server does not see this device as online yet.'
    }
    if ($state -ne 'NeedsLogin') {
        Add-Fix $r (New-Fix 'logout' 'Log out' -Confirm 'Log this device out of Tailscale? It will disconnect until someone logs in again.')
    }
    return $r
}

function Test-Adapter {
    $r = New-Result 'adapter' 'Tailscale network adapter'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    if (-not (Get-TsExe)) { $r.status = 'skip'; $r.summary = 'Tailscale is not installed'; return $r }
    $ad = @()
    try { $ad = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.InterfaceDescription -like 'Tailscale*' -or $_.Name -like 'Tailscale*' }) } catch {
        $r.status = 'warn'; $r.summary = 'Could not list network adapters: ' + (Get-InnerMessage $_); return $r
    }
    $st = Get-TsStatus
    $state = if ($st.reachable) { [string]$st.json.BackendState } else { '' }
    if (-not $ad.Count) {
        if ($state -eq 'Running') { Set-Status $r 'warn' 'Connected, but no Tailscale adapter is visible.' }
        else {
            Set-Status $r 'fail' 'The Tailscale network adapter does not exist.'
            $r.advice += 'The service creates the adapter when it starts. Restart the service; if it still is missing, reinstall; if still missing, reboot (a pending driver install may be blocking it).'
            Add-Fix $r (New-Fix 'restart-service' 'Restart Tailscale service' -Auto -Primary)
        }
        return $r
    }
    foreach ($a in $ad) {
        $r.details += "$($a.Name): $($a.InterfaceDescription), status $($a.Status), MTU $($a.MtuSize)"
        if ([string]$a.Status -eq 'Disabled' -or $a.AdminStatus -eq 'Down') {
            Set-Status $r 'fail' "The adapter '$($a.Name)' is disabled in Windows."
            Add-Fix $r (New-Fix 'enable-adapter' 'Enable the adapter' -Auto -Primary)
        }
    }
    if ($r.status -eq 'ok') {
        $up = @($ad | Where-Object { [string]$_.Status -eq 'Up' }).Count
        $r.summary = if ($up) { 'Present and up' } else { 'Present (down until Tailscale connects)' }
    }
    return $r
}

function Test-Clock {
    $r = New-Result 'clock' 'System clock'
    $skew = Get-ClockSkew
    $r.details += ('Local time (UTC): ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
    if ($skew.ok) {
        $r.data.skewSec = $skew.skewSec
        $r.details += "Difference from internet time: $($skew.skewSec) s (source $($skew.source))"
        $abs = [Math]::Abs($skew.skewSec)
        if ($abs -gt 300) {
            Set-Status $r 'fail' "The clock is off by $abs seconds. Secure connections (and Tailscale login) fail when the clock is wrong."
            Add-Fix $r (New-Fix 'time-resync' 'Fix the clock' -Auto -Primary)
        } elseif ($abs -gt 60) {
            Set-Status $r 'warn' "The clock is off by $abs seconds."
            Add-Fix $r (New-Fix 'time-resync' 'Fix the clock' -Auto)
        } else { $r.summary = 'Correct' + $(if ($abs) { " (off by $abs s)" } else { '' }) }
    } else {
        Set-Status $r 'info' 'Could not compare with internet time (no connectivity).'
    }
    if ($script:IsWin) {
        $w = Invoke-Proc 'w32tm.exe' @('/query', '/status') 10 -Quiet
        if ($w.ok) {
            foreach ($l in ($w.stdout -split "`r?`n")) { if ($l -match '^(Source|Last Successful Sync Time|Leap Indicator)') { $r.details += $l.Trim() } }
        } else {
            $r.details += 'Windows Time service is not running.'
            if ($r.status -ne 'ok') { $r.advice += 'The Windows Time service is not running; the fix starts it and syncs.' }
        }
    }
    return $r
}

$script:TsHosts = @('controlplane.tailscale.com', 'login.tailscale.com', 'log.tailscale.io', 'pkgs.tailscale.com')

function Test-Dns {
    $r = New-Result 'dns' 'DNS (name lookups)'
    $bad = @(); $failed = @()
    foreach ($h in $script:TsHosts) {
        $res = Resolve-HostSafe $h
        if ($res.ok) {
            $r.details += ("$h -> " + ($res.addresses -join ', ') + " ($($res.ms) ms)")
            $sus = @($res.addresses | Where-Object { Test-SuspiciousIp $_ })
            if ($sus.Count -and $sus.Count -eq $res.addresses.Count) { $bad += $h }
        } else {
            $r.details += "$h -> FAILED: $($res.error)"
            $failed += $h
        }
    }
    # Compare with public DNS to detect filtering.
    $publicOk = $null
    if ($script:IsWin -and ($failed.Count -or $bad.Count)) {
        try {
            $pd = Resolve-DnsName -Name 'controlplane.tailscale.com' -Server '1.1.1.1' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            $ips = @($pd | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
            $publicOk = ($ips.Count -gt 0)
            $r.details += ('Via public DNS 1.1.1.1: controlplane.tailscale.com -> ' + ($ips -join ', '))
        } catch { $publicOk = $false; $r.details += 'Via public DNS 1.1.1.1: failed (' + (Get-InnerMessage $_) + ')' }
    }
    try {
        $srv = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | ForEach-Object { "$($_.InterfaceAlias): " + ($_.ServerAddresses -join ', ') })
        foreach ($s in $srv) { $r.details += "DNS servers - $s" }
    } catch { }

    $critical = @($failed + $bad | Where-Object { $_ -in @('controlplane.tailscale.com', 'login.tailscale.com') })
    if ($bad.Count) {
        Set-Status $r 'fail' ('DNS is blocking Tailscale: ' + ($bad -join ', ') + ' resolve to a fake/blocked address.')
        $r.advice += 'A DNS filter is sinkholing tailscale.com. Check your router''s content filter, Pi-hole/AdGuard, NextDNS, OpenDNS/Umbrella, or antivirus web filtering, and allow *.tailscale.com and *.tailscale.io.'
    }
    if ($critical.Count -and -not $bad.Count) {
        if ($publicOk) {
            Set-Status $r 'fail' 'Your DNS server cannot resolve Tailscale, but public DNS can: your DNS is filtering it.'
            $r.advice += 'Allow *.tailscale.com in your DNS filter, or change this PC''s (or router''s) DNS servers to 1.1.1.1 / 8.8.8.8.'
        } else {
            Set-Status $r 'fail' 'Cannot resolve Tailscale server names.'
            $r.advice += 'Check that this PC has internet access. If websites work, a DNS filter may be blocking tailscale.com.'
        }
        Add-Fix $r (New-Fix 'flush-dns' 'Flush DNS cache' -Auto)
    } elseif ($failed.Count) {
        Set-Status $r 'warn' ('Some names failed to resolve: ' + ($failed -join ', '))
        Add-Fix $r (New-Fix 'flush-dns' 'Flush DNS cache')
    }
    if ($r.status -eq 'ok') { $r.summary = 'All Tailscale server names resolve correctly.' }
    return $r
}

function Test-Reach {
    $r = New-Result 'reach' 'Reachability of Tailscale servers'
    $baseline = @((Test-Tcp '1.1.1.1' 443 5000), (Test-Tcp 'www.microsoft.com' 443 6000))
    $internet = (@($baseline | Where-Object { $_.ok }).Count -gt 0)
    foreach ($b in $baseline) { $r.details += ('Internet baseline ' + $b.target + ': ' + $(if ($b.ok) { "OK ($($b.ms) ms)" } else { 'FAILED - ' + $b.error })) }

    $targets = @(
        @{ h = 'controlplane.tailscale.com'; p = 443; critical = $true },
        @{ h = 'controlplane.tailscale.com'; p = 80; critical = $false },
        @{ h = 'login.tailscale.com'; p = 443; critical = $true },
        @{ h = 'log.tailscale.io'; p = 443; critical = $false },
        @{ h = 'pkgs.tailscale.com'; p = 443; critical = $false }
    )
    $critFail = @(); $minorFail = @()
    foreach ($t in $targets) {
        $x = Test-Tcp $t.h $t.p 7000
        $r.details += ("$($x.target): " + $(if ($x.ok) { "OK ($($x.ms) ms)" } else { 'FAILED - ' + $x.error }))
        if (-not $x.ok) { if ($t.critical) { $critFail += $x.target } else { $minorFail += $x.target } }
    }
    $r.data.internet = $internet
    $r.data.controlOk = ($critFail.Count -eq 0)
    if (-not $internet -and $critFail.Count) {
        Set-Status $r 'fail' 'This PC has no working internet connection (or everything is blocked).'
        $r.advice += 'Check the network cable/Wi-Fi, captive portal (hotel/guest Wi-Fi login page), or a proxy that is required on this network.'
    } elseif ($critFail.Count) {
        Set-Status $r 'fail' ('Internet works, but Tailscale is blocked: ' + ($critFail -join ', ') + ' unreachable.')
        $r.advice += 'Something on this PC or network singles out Tailscale. In order of likelihood: antivirus firewall (Bitdefender, Kaspersky, ESET, Norton...), router/business firewall rules, a DNS filter, or another VPN. See the Security software and VPN checks.'
        $r.advice += 'If this is the only symptom: test from another network (phone hotspot). If it works there, the block is on your router/ISP; if not, it is on this PC.'
    } elseif ($minorFail.Count) {
        Set-Status $r 'warn' ('Some non-critical Tailscale endpoints are unreachable: ' + ($minorFail -join ', '))
        if ($minorFail -match 'pkgs') { $r.advice += 'pkgs.tailscale.com is only needed to download/update Tailscale.' }
        if ($minorFail -match ':80') { $r.advice += 'Port 80 to the control server is used as a fast path; 443 works, which is enough.' }
    } else { $r.summary = 'All Tailscale servers reachable.' }
    return $r
}

function Test-Tls {
    $r = New-Result 'tls' 'Secure connection (TLS interception)'
    $hosts = @('controlplane.tailscale.com', 'login.tailscale.com')
    $any = $false
    foreach ($h in $hosts) {
        $t = Get-Cached "tls:$h" 60 { Get-TlsInfo $h }
        if (-not $t.ok -and -not $t.issuer) {
            $r.details += "${h}: could not complete TLS - $($t.error)"
            continue
        }
        $any = $true
        $r.details += "${h}: certificate issued by '$($t.issuer)'"
        if ($t.root) { $r.details += "${h}: root CA '$($t.root)'" }
        if ($t.protocol) { $r.details += "${h}: protocol $($t.protocol)" }
        if ($t.policyErrors -and $t.policyErrors -ne 'None') { $r.details += "${h}: Windows reports certificate problem: $($t.policyErrors)" }
        if ($t.interceptor) {
            $r.data.interceptor = $t.interceptor
            Set-Status $r 'fail' "HTTPS to Tailscale is being intercepted by $($t.interceptor) (certificate root: '$($t.root)'). Tailscale pins its server keys, so this breaks login/connection (hang, then timeout)."
        } elseif (-not $t.publicCa) {
            Set-Status $r 'fail' "HTTPS to Tailscale is signed by an unknown authority ('$($t.root)'): something is intercepting it."
        } elseif ($t.policyErrors -and $t.policyErrors -ne 'None') {
            Set-Status $r 'warn' "Certificate problem reported by Windows: $($t.policyErrors)"
        }
    }
    if ($r.status -eq 'fail') {
        $r.advice += 'Turn off HTTPS/SSL/"encrypted web" scanning for *.tailscale.com (or entirely, to test) in your antivirus or proxy. The Security software check lists exact steps for detected products.'
    }
    # Actual HTTP request to the control plane's key endpoint.
    $k = Invoke-Http 'https://controlplane.tailscale.com/key?v=71' 15000
    if ($k.status) {
        $r.details += "GET controlplane /key: HTTP $($k.status) in $($k.ms) ms"
        if ($k.status -eq 200 -and $k.body -match 'mkey:') { if ($r.status -eq 'ok') { $r.summary = 'Genuine Tailscale certificate, control server answers correctly.' } }
        elseif ($k.body -match '<html') {
            Set-Status $r 'fail' 'The control server request returned a web page instead of Tailscale data: a proxy, captive portal or filter is answering instead.'
            $r.details += ('Response start: ' + ($k.body.Substring(0, [Math]::Min(300, $k.body.Length)) -replace '\s+', ' '))
        } else { Set-Status $r 'warn' "Unexpected control server response (HTTP $($k.status))." }
    } elseif ($k.error) {
        $r.details += "GET controlplane /key failed: $($k.error)"
        foreach ($x in (Get-ErrorHints $k.error)) { $r.advice += $x }
        if ($any) { Set-Status $r 'warn' 'TLS handshake worked but the HTTPS request failed.' }
    }
    if (-not $any -and $r.status -eq 'ok') {
        Set-Status $r 'fail' 'Could not open a secure connection to Tailscale at all.'
        $r.advice += 'See the Reachability and DNS checks: the servers are not reachable from this PC.'
    }
    return $r
}

function Test-Proxy {
    $r = New-Result 'proxy' 'Proxy settings'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $found = $false
    $w = Invoke-Proc 'netsh.exe' @('winhttp', 'show', 'proxy') 10 -Quiet
    $wOut = ($w.stdout -replace '\s+', ' ').Trim()
    $r.details += "Machine (WinHTTP) proxy - used by the Tailscale service: $wOut"
    $machineProxy = $null
    if ($w.stdout -match 'Proxy Server\(s\)\s*:\s*(\S+)') { $machineProxy = $Matches[1]; $found = $true }
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) { $r.details += "Your user proxy: $($ie.ProxyServer)"; $found = $true }
        if ($ie.AutoConfigURL) { $r.details += "Your user proxy script (PAC): $($ie.AutoConfigURL)"; $found = $true }
    } catch { }
    foreach ($v in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
        foreach ($scope in @('Machine', 'User', 'Process')) {
            $val = [Environment]::GetEnvironmentVariable($v, $scope)
            if ($val) { $r.details += "Environment $v ($scope) = $val"; $found = $true }
        }
    }
    if ($machineProxy) {
        $hp = $machineProxy -split ';' | Select-Object -First 1
        $hp = $hp -replace '^[a-z]+=', '' -replace '^https?://', ''
        $parts = $hp -split ':'
        $port = if ($parts.Count -gt 1) { [int]($parts[-1] -replace '\D', '') } else { 80 }
        $t = Test-Tcp $parts[0] $port 5000
        if (-not $t.ok) {
            Set-Status $r 'fail' "The machine-wide proxy ($hp) is unreachable, so the Tailscale service cannot get out."
            Add-Fix $r (New-Fix 'reset-winhttp-proxy' 'Remove machine-wide proxy' -Confirm 'Remove the machine-wide (WinHTTP) proxy setting? Only do this if this network does not require a proxy.')
        } else {
            Set-Status $r 'info' "A machine-wide proxy is set ($hp). Tailscale's service will use it."
            $r.advice += 'Proxies that inspect HTTPS break Tailscale. Ask your IT to bypass *.tailscale.com and *.tailscale.io.'
        }
    }
    if (-not $found) { $r.summary = 'No proxy configured (direct connection).' }
    elseif ($r.status -eq 'ok') { $r.status = 'info'; $r.summary = 'A proxy is configured for your user only; the Tailscale service does not use it.' }
    return $r
}

$script:VendorSteps = [ordered]@{
    'Bitdefender' = @(
        'Open Bitdefender > Protection > Online Threat Prevention > Settings: turn OFF "Encrypted web scan" (test), or keep it on and add exceptions for *.tailscale.com and *.tailscale.io.',
        'Protection > Firewall (paid tiers) > Settings/Rules > Applications: add C:\Program Files\Tailscale\tailscaled.exe and tailscale-ipn.exe with Permission "Allow", network "Any".',
        'Protection > Antivirus > Settings > Manage exceptions: add the folder C:\Program Files\Tailscale\ for all modules.',
        'Back here: click "Restart the service", then log in.'
    )
    'Kaspersky' = @(
        'Kaspersky > Settings > Network settings: set "Do not scan encrypted connections" or add *.tailscale.com to trusted addresses.',
        'Settings > Threats and Exclusions > Specify trusted applications: add C:\Program Files\Tailscale\tailscaled.exe with "Do not scan encrypted traffic" and "Do not restrict application activity".'
    )
    'ESET' = @(
        'ESET > Setup > Advanced setup > Web and email > SSL/TLS: add *.tailscale.com to excluded addresses, or add tailscaled.exe to excluded applications.',
        'Setup > Network protection > Firewall: allow tailscaled.exe (or switch to automatic mode).'
    )
    'Avast' = @('Avast > Menu > Settings > Protection > Core Shields > Web Shield: uncheck "Enable HTTPS scanning" (test) or add *.tailscale.com to exceptions.', 'Add C:\Program Files\Tailscale\ to General > Exceptions.')
    'AVG' = @('AVG > Menu > Settings > Basic protection > Web Shield: disable HTTPS scanning (test) or add *.tailscale.com to exceptions.', 'Add C:\Program Files\Tailscale\ to exceptions.')
    'Norton' = @('Norton > Settings > Firewall > Program Control: set tailscaled.exe to "Allow".', 'Settings > Antivirus > Scans and Risks > Exclusions: add C:\Program Files\Tailscale\.')
    'McAfee' = @('McAfee > Firewall > Internet connections for programs: add tailscaled.exe with full access.', 'Web protection: add *.tailscale.com as a trusted site.')
    'Sophos' = @('Sophos Central (admin): add a web exclusion for *.tailscale.com (disable SSL/TLS decryption) and allow tailscaled.exe.')
    'Zscaler' = @('Ask IT to add *.tailscale.com and *.tailscale.io to the SSL inspection bypass list in Zscaler, and allow UDP 41641 / 3478.')
    'Netskope' = @('Ask IT to add a Netskope steering/SSL-decryption exception for *.tailscale.com and *.tailscale.io.')
    'Trend Micro' = @('Trend Micro > Settings > Exception lists: add C:\Program Files\Tailscale\ and trust *.tailscale.com.')
    'Malwarebytes' = @('Malwarebytes > Settings > Allow list: add C:\Program Files\Tailscale\ (application) and *.tailscale.com (website).')
    'Webroot' = @('Webroot > PC Security > Firewall > Application: set tailscaled.exe to Allow.')
    'F-Secure' = @('F-Secure > Settings > Excluded apps: add tailscaled.exe; Browsing protection: allow *.tailscale.com.')
    'Fortinet' = @('FortiClient/FortiGate: add *.tailscale.com to the SSL deep inspection exemptions and allow tailscaled.exe.')
    'Cisco' = @('Cisco Umbrella/Secure Client: add *.tailscale.com to the selective decryption bypass list.')
}

function Get-SecurityProducts {
    return Get-Cached 'secprod' 120 {
        $found = New-Object System.Collections.ArrayList
        if (-not $script:IsWin) { return , @() }
        try {
            $av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
            foreach ($a in $av) {
                # productState bits 12-13: 0x1000 = enabled.
                $enabled = (([int]$a.productState -band 0x1000) -ne 0)
                [void]$found.Add([ordered]@{ name = $a.displayName; kind = 'Antivirus'; enabled = $enabled })
            }
        } catch { }
        try {
            $fw = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop
            foreach ($a in $fw) { [void]$found.Add([ordered]@{ name = $a.displayName; kind = 'Firewall'; enabled = ((([int]$a.productState -band 0x1000) -ne 0)) }) }
        } catch { }
        $procMap = @{ 'vsserv' = 'Bitdefender'; 'bdservicehost' = 'Bitdefender'; 'bdagent' = 'Bitdefender'; 'avp' = 'Kaspersky'; 'ekrn' = 'ESET'; 'AvastSvc' = 'Avast'; 'AVGSvc' = 'AVG';
            'NortonSecurity' = 'Norton'; 'ns' = 'Norton'; 'mcshield' = 'McAfee'; 'SophosNtpService' = 'Sophos'; 'ZSATunnel' = 'Zscaler'; 'ZSAService' = 'Zscaler'; 'stAgentSvc' = 'Netskope';
            'FortiTray' = 'Fortinet'; 'acumbrellaagent' = 'Cisco Umbrella'; 'vpnagent' = 'Cisco'; 'MBAMService' = 'Malwarebytes'; 'WRSA' = 'Webroot'; 'PccNTMon' = 'Trend Micro'; 'fshoster32' = 'F-Secure' }
        try {
            $names = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
            foreach ($k in $procMap.Keys) {
                if ($names -contains $k) {
                    $v = $procMap[$k]
                    $exists = $false
                    foreach ($f in $found) { if ($f.name -match [regex]::Escape(($v -split ' ')[0])) { $exists = $true } }
                    if (-not $exists) { [void]$found.Add([ordered]@{ name = $v; kind = 'Running security/network software'; enabled = $true }) }
                }
            }
        } catch { }
        return , @($found)
    }
}

function Test-Security {
    $r = New-Result 'security' 'Security software (antivirus / firewall)'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $prods = @(Get-SecurityProducts)
    foreach ($p in $prods) { $r.details += "$($p.kind): $($p.name)" + $(if ($p.enabled) { ' (active)' } else { ' (inactive)' }) }
    $thirdParty = @($prods | Where-Object { $_.name -notmatch 'Windows Defender|Microsoft Defender|Windows Firewall' -and $_.enabled })
    $r.data.products = @($prods | ForEach-Object { $_.name })

    $tls = Get-Cached 'tls:controlplane.tailscale.com' 60 { Get-TlsInfo 'controlplane.tailscale.com' }
    $reach = (Test-Tcp 'controlplane.tailscale.com' 443 6000).ok
    $shown = @{}
    $showVendor = {
        param($name)
        foreach ($k in $script:VendorSteps.Keys) {
            if ($name -match [regex]::Escape($k) -and -not $shown.ContainsKey($k)) {
                $shown[$k] = $true
                foreach ($s in $script:VendorSteps[$k]) { $r.advice += "[$k] $s" }
            }
        }
    }
    if ($tls.interceptor) {
        Set-Status $r 'fail' "$($tls.interceptor) is intercepting encrypted traffic to Tailscale. This is the cause of login hanging/timing out."
        & $showVendor $tls.interceptor
    } elseif (-not $reach -and $thirdParty.Count) {
        Set-Status $r 'fail' ('Tailscale''s server is unreachable and third-party security software is active (' + (($thirdParty | ForEach-Object { $_.name }) -join ', ') + '): its firewall is the prime suspect.')
    } elseif ($thirdParty.Count) {
        Set-Status $r 'info' ('Third-party security software detected: ' + (($thirdParty | ForEach-Object { $_.name }) -join ', ') + '. Not currently blocking the control server.')
    } else { $r.summary = 'Only Microsoft Defender detected (does not interfere with Tailscale).' }
    foreach ($p in $thirdParty) { & $showVendor $p.name }

    $defender = @($prods | Where-Object { $_.name -match 'Defender' -and $_.enabled })
    if ($defender.Count) { Add-Fix $r (New-Fix 'defender-exclusion' 'Add Tailscale to Microsoft Defender exclusions') }
    if ($thirdParty.Count -and $r.status -eq 'fail') {
        $r.advice += 'Security software cannot be reconfigured from here (it protects itself against that). Follow the steps above, then click "Run full check" again.'
        $r.advice += 'Quick test: temporarily pause the antivirus'' web protection and firewall for 10 minutes, then run the check. If it passes, add the permanent exceptions and turn protection back on.'
    }
    return $r
}

function Test-Vpn {
    $r = New-Result 'vpn' 'Other VPNs and routing'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $pattern = 'WireGuard|TAP-Windows|OpenVPN|Wintun|AnyConnect|Cisco|GlobalProtect|PANGP|Juniper|Pulse|Fortinet|FortiClient|NordLynx|NordVPN|ProtonVPN|Mullvad|ExpressVPN|Surfshark|Private Internet Access|ZeroTier|Hamachi|WARP|Cloudflare|Zscaler|Netskope|Check Point|SonicWall|WatchGuard|Hotspot Shield|Windscribe|CyberGhost|IPVanish|Radmin|Twingate|NetBird|Nebula|Hyper-V|vEthernet'
    $vpns = @()
    try {
        $ads = @(Get-NetAdapter -ErrorAction Stop | Where-Object { ($_.InterfaceDescription -match $pattern -or $_.Name -match $pattern) -and $_.InterfaceDescription -notlike 'Tailscale*' -and $_.Name -notlike 'Tailscale*' })
        foreach ($a in $ads) {
            $isVirtualSwitch = ($a.InterfaceDescription -match 'Hyper-V' -or $a.Name -match 'vEthernet')
            $r.details += "Adapter: $($a.Name) ($($a.InterfaceDescription)) - $($a.Status)"
            if ([string]$a.Status -eq 'Up' -and -not $isVirtualSwitch) { $vpns += $a }
        }
    } catch { $r.details += 'Could not list adapters: ' + (Get-InnerMessage $_) }

    $defaultIf = $null
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1') })
        $ifMetrics = @{}
        try { Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { $ifMetrics[$_.ifIndex] = $_.InterfaceMetric } } catch { }
        $sorted = $routes | Sort-Object @{ Expression = { if ($_.DestinationPrefix -ne '0.0.0.0/0') { -1 } else { [int]$_.RouteMetric + [int]$ifMetrics[$_.ifIndex] } } }
        foreach ($rt in $sorted) { $r.details += "Route $($rt.DestinationPrefix) via $($rt.NextHop) on '$($rt.InterfaceAlias)' (metric $([int]$rt.RouteMetric + [int]$ifMetrics[$rt.ifIndex]))" }
        $split = @($routes | Where-Object { $_.DestinationPrefix -ne '0.0.0.0/0' -and $_.InterfaceAlias -notlike 'Tailscale*' })
        if ($split.Count) {
            Set-Status $r 'warn' "Another VPN ('$($split[0].InterfaceAlias)') has taken over all internet traffic."
        }
        $first = $sorted | Select-Object -First 1
        if ($first) { $defaultIf = $first.InterfaceAlias; $r.data.defaultInterface = $defaultIf }
        if (-not $routes.Count) { Set-Status $r 'fail' 'This PC has no default route: no internet connection.' }
    } catch { $r.details += 'Could not read routes: ' + (Get-InnerMessage $_) }

    if ($vpns.Count) {
        $names = ($vpns | ForEach-Object { $_.Name }) -join ', '
        Set-Status $r 'warn' "Another VPN is connected ($names). VPNs commonly block or reroute Tailscale traffic."
        $r.advice += 'Disconnect the other VPN and run the check again. If Tailscale then works, configure that VPN for split tunneling (exclude 100.64.0.0/10 and *.tailscale.com) or ask its admin.'
    }
    if ($r.status -eq 'ok') { $r.summary = 'No conflicting VPN detected' + $(if ($defaultIf) { "; internet goes through '$defaultIf'." } else { '.' }) }
    return $r
}

function Test-Firewall {
    $r = New-Result 'firewall' 'Windows Firewall'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $daemon = (Get-TsPaths).daemon
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        foreach ($p in $profiles) {
            $r.details += "Profile $($p.Name): enabled=$($p.Enabled), default outbound=$($p.DefaultOutboundAction), default inbound=$($p.DefaultInboundAction)"
            if ($p.Enabled -and [string]$p.DefaultOutboundAction -eq 'Block') {
                Set-Status $r 'warn' "Profile '$($p.Name)' blocks outbound traffic by default; Tailscale needs an allow rule."
                if ($daemon) { Add-Fix $r (New-Fix 'firewall-allow' 'Add firewall allow rules for Tailscale' -Auto -Primary) }
            }
        }
    } catch { $r.details += 'Could not read firewall profiles: ' + (Get-InnerMessage $_) }

    try {
        $blocks = @(Get-NetFirewallRule -Enabled True -Action Block -ErrorAction Stop | Where-Object {
                $af = $_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                ($af.Program -match 'tailscale') -or ($_.DisplayName -match 'tailscale')
            })
        if ($blocks.Count) {
            foreach ($b in $blocks) { $r.details += "BLOCK rule: $($b.DisplayName) ($($b.Direction))" }
            Set-Status $r 'fail' ("$($blocks.Count) firewall rule(s) explicitly BLOCK Tailscale.")
            Add-Fix $r (New-Fix 'firewall-remove-blocks' 'Disable rules that block Tailscale' -Auto -Primary -Confirm 'Disable the Windows Firewall rules that block Tailscale?')
        }
        $allows = @(Get-NetFirewallRule -Enabled True -Action Allow -ErrorAction Stop | Where-Object { $_.DisplayName -match 'Tailscale' })
        $r.details += "Allow rules mentioning Tailscale: $($allows.Count)"
    } catch { $r.details += 'Could not read firewall rules: ' + (Get-InnerMessage $_) }
    if ($daemon) { Add-Fix $r (New-Fix 'firewall-allow' 'Add firewall allow rules for Tailscale') }
    if ($r.status -eq 'ok') { $r.summary = 'Windows Firewall is not blocking Tailscale.' }
    return $r
}

function Test-Ts2021 {
    $r = New-Result 'ts2021' 'Control-plane handshake (tailscale debug ts2021)'
    if (-not (Get-TsExe)) { $r.status = 'skip'; $r.summary = 'Tailscale is not installed'; return $r }
    $p = Invoke-Ts @('debug', 'ts2021') 35
    $out = Get-Tail $p.output 25
    if ($out) { $r.details += $out }
    if ($p.output -match 'unknown subcommand|flag provided but not defined|Usage:') { $r.status = 'skip'; $r.summary = 'Not supported by this Tailscale version.'; return $r }
    if ($p.ok) {
        $r.summary = 'This PC completes the encrypted handshake with Tailscale''s control server.'
        return $r
    }
    if ($p.timedOut) { Set-Status $r 'fail' 'The handshake with Tailscale''s control server hung (no answer in 35 s).' }
    else { Set-Status $r 'fail' 'The handshake with Tailscale''s control server failed.' }
    $r.advice += 'This is the decisive test: registration and login need this handshake. While it fails, neither auth keys nor browser login can work.'
    foreach ($h in (Get-ErrorHints ($p.output + ' ' + $p.error))) { $r.advice += $h }
    if ($p.output -match 'fetching keys' -and $p.output -match 'timeout') {
        $r.advice += 'Pattern "fetching keys ... i/o timeout": the connection to controlplane.tailscale.com never completes. If Reachability shows port 443 OK, antivirus HTTPS inspection is the cause; if it fails, a firewall/router/ISP is blocking it.'
    }
    return $r
}

function Test-Netcheck {
    $r = New-Result 'netcheck' 'Relay and UDP connectivity (tailscale netcheck)'
    if (-not (Get-TsExe)) { $r.status = 'skip'; $r.summary = 'Tailscale is not installed'; return $r }
    $p = Invoke-Ts @('netcheck') 40
    $out = Get-Tail $p.output 40
    if ($out) { $r.details += $out }
    if ($p.timedOut -or (-not $p.ok -and -not $p.stdout)) {
        Set-Status $r 'warn' 'netcheck did not complete.'
        foreach ($h in (Get-ErrorHints ($p.output + ' ' + $p.error))) { $r.advice += $h }
        return $r
    }
    $udp = $null
    if ($p.stdout -match 'UDP:\s*(true|false)') { $udp = ($Matches[1] -eq 'true') }
    $derp = $null
    if ($p.stdout -match 'Nearest DERP:\s*(.+)') { $derp = $Matches[1].Trim() }
    $r.data.udp = $udp; $r.data.derp = $derp
    if ($udp -eq $false) {
        Set-Status $r 'warn' 'UDP is blocked: Tailscale will work, but only through relays (slower).'
        $r.advice += 'Allow outbound UDP (port 41641 and 3478) for tailscaled.exe in your firewall/antivirus and router for direct, fast connections.'
    }
    if (-not $derp -or $derp -match 'unknown') {
        Set-Status $r 'fail' 'No Tailscale relay (DERP) server is reachable.'
        $r.advice += 'Relays use HTTPS (TCP 443) to *.tailscale.com. The same firewall/antivirus fixes as above apply.'
    }
    if ($r.status -eq 'ok') { $r.summary = "UDP works; nearest relay: $derp" }
    return $r
}

function Test-Update {
    $r = New-Result 'update' 'Tailscale version'
    $cur = Get-TsVersion
    if (-not $cur) { $r.status = 'skip'; $r.summary = 'Tailscale is not installed'; return $r }
    $lat = Get-LatestRelease
    $r.details += "Installed: $cur"
    if (-not $lat.ok -or -not $lat.version) {
        Set-Status $r 'info' 'Could not check for the latest version.'
        if ($lat.error) { $r.details += "Error: $($lat.error)" }
        return $r
    }
    $r.details += "Latest: $($lat.version)"
    $cmp = Compare-Version $cur $lat.version
    if ($cmp -lt 0) {
        $curV = [version](($cur -split '[^0-9.]')[0]); $latV = [version](($lat.version -split '[^0-9.]')[0])
        $old = ($latV.Major -gt $curV.Major) -or ($latV.Minor - $curV.Minor -ge 10)
        Set-Status $r $(if ($old) { 'warn' } else { 'info' }) "Update available: $cur -> $($lat.version)"
        Add-Fix $r (New-Fix 'update' "Update to $($lat.version)" -Auto:$old)
        if ($old) { $r.advice += 'This version is quite old; many Windows connectivity bugs have been fixed since. Update.' }
    } else { $r.summary = "Up to date ($cur)" }
    return $r
}

function Test-Policy {
    $r = New-Result 'policy' 'Tailscale policies (registry)'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $any = $false
    foreach ($k in @('HKLM:\SOFTWARE\Policies\Tailscale', 'HKCU:\SOFTWARE\Policies\Tailscale', 'HKLM:\SOFTWARE\Tailscale IPN')) {
        try {
            if (-not (Test-Path $k)) { continue }
            $props = (Get-ItemProperty -Path $k -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
            foreach ($p in $props) {
                $any = $true
                $val = [string]$p.Value
                if ($p.Name -match 'AuthKey|Secret|Token') { $val = '***' }
                $r.details += "$k : $($p.Name) = $val"
                if ($p.Name -eq 'LoginURL' -and $val -and $val -notmatch 'tailscale\.com') { Set-Status $r 'warn' "A policy points Tailscale at a custom control server ($val)." }
                if ($p.Name -eq 'UnattendedMode' -and $val -eq 'never') { Set-Status $r 'warn' 'A policy forbids unattended mode: Tailscale disconnects when you sign out of Windows.' }
            }
        } catch { }
    }
    if (-not $any) { $r.summary = 'No policies set (defaults).' }
    elseif ($r.status -eq 'ok') { $r.status = 'info'; $r.summary = 'Policies are set (see details). None appear to block Tailscale.' }
    $r.advice += 'Note: there is no installer/MSI property that logs you in. Reinstalling or switching installers (.exe vs .msi) never fixes a login problem by itself.'
    return $r
}

function Test-State {
    $r = New-Result 'state' 'Tailscale state files'
    if (-not $script:IsWin) { $r.status = 'skip'; $r.summary = 'Windows only'; return $r }
    $dir = Join-Path ([string]$env:ProgramData) 'Tailscale'
    if (-not (Test-Path -LiteralPath $dir)) { $r.summary = 'No state yet (fresh install).'; return $r }
    $f = Join-Path $dir 'server-state.conf'
    if (Test-Path -LiteralPath $f) {
        $fi = Get-Item -LiteralPath $f
        $r.details += "server-state.conf: $($fi.Length) bytes, modified $($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
        $txt = Read-SharedText $f
        if ($fi.Length -eq 0 -or -not $txt.Trim()) {
            Set-Status $r 'fail' 'The Tailscale state file is empty (corrupted).'
        } else {
            try { $null = $txt | ConvertFrom-Json; $r.summary = 'State file is valid.' } catch {
                Set-Status $r 'fail' 'The Tailscale state file is corrupted (not valid JSON).'
            }
        }
    } else { $r.summary = 'No saved state (not logged in yet).' }
    if ($r.status -eq 'fail') {
        $r.advice += 'Resetting the state backs up the old files and starts clean. You will need to log in again.'
        Add-Fix $r (New-Fix 'reset-state' 'Reset Tailscale state' -Auto -Primary -Confirm 'Reset Tailscale state? The old state is backed up, and this device must log in again.')
    } else {
        Add-Fix $r (New-Fix 'reset-state' 'Reset Tailscale state (last resort)' -Confirm 'Reset Tailscale state? The old state is backed up to ProgramData\TailscaleDoctor, and this device must log in again (it may appear as a new machine in the admin console).')
    }
    return $r
}

$script:LogPatterns = @(
    @{ re = 'x509|certificate signed by unknown authority'; msg = 'Certificate errors: HTTPS interception (antivirus/proxy) or wrong clock.'; sev = 'fail' },
    @{ re = 'i/o timeout|context deadline exceeded|TLS handshake timeout'; msg = 'Network timeouts reaching Tailscale servers.'; sev = 'warn' },
    @{ re = 'no such host|server misbehaving'; msg = 'DNS lookup failures.'; sev = 'warn' },
    @{ re = 'wintun|CreateAdapter|tun: '; msg = 'Network adapter (Wintun) errors.'; sev = 'warn' },
    @{ re = 'Access is denied'; msg = 'Access denied errors (permissions or security software blocking).'; sev = 'warn' },
    @{ re = 'node key expired|NodeKeyExpired'; msg = 'The node key expired: log in again.'; sev = 'warn' },
    @{ re = 'panic:|fatal error:'; msg = 'The Tailscale service crashed recently.'; sev = 'warn' },
    @{ re = 'proxy'; msg = 'Proxy-related messages.'; sev = 'info' }
)

function Test-Logs {
    $r = New-Result 'logs' 'Tailscale service logs'
    $dir = Get-TsLogDir
    if (-not $dir) { $r.status = 'skip'; $r.summary = 'No Tailscale log folder found.'; return $r }
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'tailscaled' -and $_.Extension -in @('.txt', '.log') } | Sort-Object LastWriteTime -Descending)
    if (-not $files.Count) { $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) }
    if (-not $files.Count) { $r.status = 'skip'; $r.summary = 'Log folder is empty.'; return $r }
    $f = $files[0]
    $r.details += "Log: $($f.FullName) (modified $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
    $text = Read-FileTail $f.FullName 262144
    $lines = @($text -split "`r?`n" | Select-Object -Last 1500)
    $hits = @()
    foreach ($pat in $script:LogPatterns) {
        $m = @($lines | Where-Object { $_ -match $pat.re })
        if ($m.Count) {
            $hits += $pat.msg
            $latest = ([string]$m[-1]).Trim()
            if ($latest.Length -gt 300) { $latest = $latest.Substring(0, 300) + '...' }
            $r.details += "[$($m.Count)x] $($pat.msg) Latest: $latest"
        }
    }
    $r.data.tail = (@($lines | Where-Object { $_.Trim() } | Select-Object -Last 60) -join "`n")
    # Logs are supporting evidence only: they keep old errors after a problem is fixed.
    if ($hits.Count) { Set-Status $r 'info' ('Recent log entries mention: ' + ($hits -join ' ')) }
    else { $r.summary = 'No known error patterns in recent logs.' }
    Add-Fix $r (New-Fix 'bugreport' 'Create a bug report ID for Tailscale support')
    return $r
}

$script:Checks = @(
    @{ id = 'system'; title = 'Windows and permissions'; fn = ${function:Test-System} },
    @{ id = 'install'; title = 'Tailscale installation'; fn = ${function:Test-Install} },
    @{ id = 'service'; title = 'Tailscale Windows service'; fn = ${function:Test-Service} },
    @{ id = 'daemon'; title = 'Tailscale service responding'; fn = ${function:Test-Daemon} },
    @{ id = 'adapter'; title = 'Tailscale network adapter'; fn = ${function:Test-Adapter} },
    @{ id = 'clock'; title = 'System clock'; fn = ${function:Test-Clock} },
    @{ id = 'dns'; title = 'DNS (name lookups)'; fn = ${function:Test-Dns} },
    @{ id = 'reach'; title = 'Reachability of Tailscale servers'; fn = ${function:Test-Reach} },
    @{ id = 'proxy'; title = 'Proxy settings'; fn = ${function:Test-Proxy} },
    @{ id = 'tls'; title = 'Secure connection (TLS interception)'; fn = ${function:Test-Tls} },
    @{ id = 'security'; title = 'Security software (antivirus / firewall)'; fn = ${function:Test-Security} },
    @{ id = 'vpn'; title = 'Other VPNs and routing'; fn = ${function:Test-Vpn} },
    @{ id = 'firewall'; title = 'Windows Firewall'; fn = ${function:Test-Firewall} },
    @{ id = 'ts2021'; title = 'Control-plane handshake'; fn = ${function:Test-Ts2021} },
    @{ id = 'backend'; title = 'Login and connection state'; fn = ${function:Test-Backend} },
    @{ id = 'netcheck'; title = 'Relay and UDP connectivity'; fn = ${function:Test-Netcheck} },
    @{ id = 'update'; title = 'Tailscale version'; fn = ${function:Test-Update} },
    @{ id = 'policy'; title = 'Tailscale policies'; fn = ${function:Test-Policy} },
    @{ id = 'state'; title = 'Tailscale state files'; fn = ${function:Test-State} },
    @{ id = 'logs'; title = 'Tailscale service logs'; fn = ${function:Test-Logs} }
)

function Invoke-Check([string]$Id) {
    $def = $script:Checks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $def) { throw "Unknown check '$Id'" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $res = & $def.fn
        if (-not $res) { throw 'Check returned nothing' }
    } catch {
        $res = New-Result $def.id $def.title
        $res.status = 'error'
        $res.summary = 'The check itself failed: ' + (Get-InnerMessage $_)
        $res.details += ('At: ' + $_.InvocationInfo.PositionMessage)
        Write-Log "Check '$Id' threw: $(Get-InnerMessage $_)" 'error'
    }
    $res.durationMs = [int]$sw.ElapsedMilliseconds
    $res.order = [array]::IndexOf(@($script:Checks | ForEach-Object { $_.id }), $Id)
    Write-Log ("Check {0,-9} {1,-5} {2}" -f $Id, $res.status.ToUpper(), $res.summary) $(if ($res.status -in @('fail', 'error')) { 'warn' } else { 'info' })
    return $res
}

# ---------------------------------------------------------------------------
# Actions (fixes)
# ---------------------------------------------------------------------------

function New-ActionResult { return [ordered]@{ ok = $false; message = ''; steps = @(); hints = @(); data = [ordered]@{} } }
function Add-Step($A, [string]$Text, [string]$Level = 'info') {
    $A.steps += , (Protect-Secrets $Text)
    Write-Log $Text $Level
}

function Wait-ServiceState([string]$State, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { $s = Get-Service -Name Tailscale -ErrorAction Stop; if ([string]$s.Status -eq $State) { return $true } } catch { return $false }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Wait-LocalApi($A, [int]$TimeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Clear-Cache
        $st = Get-TsStatus
        if ($st.reachable) {
            Add-Step $A "Service is answering (BackendState: $($st.json.BackendState))."
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Add-Step $A "Service did not answer within $TimeoutSec s." 'warn'
    return $false
}

function Get-RecentScmErrors {
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddMinutes(-10) } -MaxEvents 50 -ErrorAction Stop |
            Where-Object { $_.Message -match 'Tailscale' -and $_.Level -le 3 } | ForEach-Object { ($_.Message -replace '\s+', ' ') })
    } catch { return @() }
}

function Set-ServiceHardening($A) {
    $ok = $true
    try { Set-Service -Name Tailscale -StartupType Automatic -ErrorAction Stop; Add-Step $A 'Service start type set to Automatic.' }
    catch {
        $p = Invoke-Proc 'sc.exe' @('config', 'Tailscale', 'start=', 'auto') 15
        if ($p.ok) { Add-Step $A 'Service start type set to Automatic (sc.exe).' } else { $ok = $false; Add-Step $A ('Could not set start type: ' + $p.output) 'error' }
    }
    $p = Invoke-Proc 'sc.exe' @('failure', 'Tailscale', 'reset=', '86400', 'actions=', 'restart/5000/restart/10000/restart/30000') 15
    if ($p.ok) { Add-Step $A 'Crash recovery: restart after 5 s / 10 s / 30 s.' } else { $ok = $false; Add-Step $A ('Could not set recovery actions: ' + $p.output) 'error' }
    $p = Invoke-Proc 'sc.exe' @('failureflag', 'Tailscale', '1') 15
    if ($p.ok) { Add-Step $A 'Recovery also applies to non-crash failures.' }
    return $ok
}

function Restart-TailscaleService($A, [switch]$StartOnly) {
    if (-not $script:IsWin) { Add-Step $A 'Not Windows.' 'error'; return $false }
    try { $svc = Get-Service -Name Tailscale -ErrorAction Stop } catch {
        Add-Step $A 'The Tailscale service is not installed. Use Install/Repair.' 'error'; return $false
    }
    if ([string]$svc.StartType -eq 'Disabled') {
        Add-Step $A 'Service was disabled; enabling it.'
        [void](Set-ServiceHardening $A)
    }
    if (-not $StartOnly -or [string]$svc.Status -match 'Pending') {
        if ([string]$svc.Status -ne 'Stopped') {
            Add-Step $A 'Stopping Tailscale service...'
            try { Stop-Service -Name Tailscale -Force -NoWait -ErrorAction Stop } catch { Add-Step $A ('Stop request failed: ' + (Get-InnerMessage $_)) 'warn' }
            if (-not (Wait-ServiceState 'Stopped' 20)) {
                Add-Step $A 'Service did not stop in 20 s; force-killing tailscaled.exe.' 'warn'
                Get-Process -Name tailscaled -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
                if (-not (Wait-ServiceState 'Stopped' 15)) { Add-Step $A 'Service still not stopped. A reboot may be required.' 'error' }
            } else { Add-Step $A 'Service stopped.' }
        }
    }
    # Leftover tailscaled processes (e.g. started by hand) hold the LocalAPI pipe.
    $stray = @(Get-Process -Name tailscaled -ErrorAction SilentlyContinue)
    if ($stray.Count -and [string](Get-Service Tailscale).Status -eq 'Stopped') {
        Add-Step $A "Killing $($stray.Count) leftover tailscaled process(es)."
        foreach ($p in $stray) { Stop-ProcessTree $p.Id }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Add-Step $A "Starting Tailscale service (attempt $attempt)..."
        try { Start-Service -Name Tailscale -ErrorAction Stop } catch { Add-Step $A ('Start failed: ' + (Get-InnerMessage $_)) 'warn' }
        if (Wait-ServiceState 'Running' 30) {
            Add-Step $A 'Service is running.'
            if (Wait-LocalApi $A 45) { return $true }
        }
        foreach ($e in (Get-RecentScmErrors | Select-Object -First 3)) { Add-Step $A "Windows event: $e" 'warn' }
        Get-Process -Name tailscaled -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
        Start-Sleep -Seconds 3
    }
    $A.hints += 'The service will not start. Try "Repair (reinstall) Tailscale", then reboot. Security software can also block tailscaled.exe from starting - check its quarantine/blocked list.'
    return $false
}

function Install-Tailscale($A, [string]$Mode) {
    if (-not $script:IsWin) { Add-Step $A 'Installation is only supported on Windows.' 'error'; return $false }
    $arch = Get-OsArch
    $script:Cache.Remove('latest')
    $lat = Get-LatestRelease
    if ($lat.version) { Add-Step $A "Latest Tailscale: $($lat.version) ($arch)" } else { Add-Step $A "Could not read the release list ($($lat.error)); using the 'latest' installer link." 'warn' }
    $dlDir = Join-Path $script:DataDir 'downloads'
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $msi = Join-Path $dlDir $lat.msi
    $haveMsi = $false
    $code = $null
    $script:UninstallTried = $false

    $verify = {
        param($path)
        try {
            $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop
            $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
            if ([string]$sig.Status -eq 'Valid' -and $signer -match 'Tailscale') { return "OK: signed by $signer" }
            return "BAD: signature status $($sig.Status), signer '$signer'"
        } catch { return 'BAD: ' + (Get-InnerMessage $_) }
    }

    if ((Test-Path -LiteralPath $msi) -and ((& $verify $msi) -like 'OK*') -and $lat.msi -notmatch 'latest') {
        Add-Step $A "Using already-downloaded installer $($lat.msi)."
        $haveMsi = $true
    } else {
        foreach ($method in @('dotnet', 'curl', 'bits')) {
            Add-Step $A "Downloading $($lat.url) ($method)..."
            $err = $null
            try {
                switch ($method) {
                    'dotnet' { $err = Save-UrlToFile $lat.url $msi 600 }
                    'curl' {
                        $c = Invoke-Proc 'curl.exe' @('-fSL', '--retry', '3', '--connect-timeout', '20', '-o', $msi, $lat.url) 600
                        if (-not $c.ok) { $err = (Get-Tail $c.output 3) + $c.error }
                    }
                    'bits' { Start-BitsTransfer -Source $lat.url -Destination $msi -ErrorAction Stop }
                }
            } catch { $err = Get-InnerMessage $_ }
            if (-not $err -and (Test-Path -LiteralPath $msi) -and (Get-Item -LiteralPath $msi).Length -gt 1MB) {
                $v = & $verify $msi
                Add-Step $A "Downloaded $([int]((Get-Item -LiteralPath $msi).Length / 1MB)) MB. Signature $v"
                if ($v -like 'OK*') { $haveMsi = $true; break }
                Add-Step $A 'The download is not a genuine Tailscale installer (possibly replaced by a proxy/filter). Deleting it.' 'error'
                Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
            } else {
                Add-Step $A "Download via $method failed: $err" 'warn'
                foreach ($h in (Get-ErrorHints $err)) { $A.hints += $h }
            }
        }
    }

    if ($haveMsi) {
        $log = Join-Path $script:DataDir ('msi-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        $msiArgs = @('/i', $msi, '/qn', '/norestart', '/l*v', $log)
        if ($Mode -eq 'repair') { $msiArgs += @('REINSTALL=ALL', 'REINSTALLMODE=amus') }
        for ($try = 1; $try -le 5; $try++) {
            Add-Step $A "Running the installer (attempt $try; this can take a few minutes)..."
            $p = Invoke-Proc 'msiexec.exe' $msiArgs 900
            $code = $p.exitCode
            if ($code -eq 0) { Add-Step $A 'Installer finished successfully.'; break }
            if ($code -eq 3010 -or $code -eq 1641) { Add-Step $A 'Installed. Windows wants a reboot to finish (you can continue for now).' 'warn'; $script:RebootNeeded = $true; $code = 0; break }
            if ($code -eq 1618) { Add-Step $A 'Another installation (e.g. Windows Update) is running. Waiting 30 s and retrying...' 'warn'; Start-Sleep -Seconds 30; continue }
            if ($code -eq 1605 -and $Mode -eq 'repair') { Add-Step $A 'Nothing to repair (not registered as installed); doing a normal install.' 'warn'; $msiArgs = @('/i', $msi, '/qn', '/norestart', '/l*v', $log); $Mode = 'install'; continue }
            $meaning = switch ($code) {
                1602 { 'cancelled' } 1603 { 'fatal error during installation' } 1612 { 'installation source missing (old install damaged)' }
                1619 { 'installer package could not be opened' } 1620 { 'installer package could not be opened' } 1625 { 'blocked by group policy' }
                1638 { 'another version is already installed' } 1639 { 'invalid command line' } default { if ($p.timedOut) { 'timed out' } else { 'error' } }
            }
            Add-Step $A "Installer failed with code $code ($meaning)." 'error'
            $tail = @(Read-FileTail $log 400000 | ForEach-Object { $_ -split "`r?`n" } | Where-Object { $_ -match 'Return value 3|Error \d{4}|error code|CustomAction .* returned actual error' } | Select-Object -Last 8)
            foreach ($l in $tail) { Add-Step $A ('MSI log: ' + $l.Trim()) 'warn' }
            $A.data.msiLog = $log
            if ($code -in @(1612, 1638) -and -not $script:UninstallTried) {
                $script:UninstallTried = $true
                # Classic fix for a damaged previous install: remove it, then install.
                $entries = @(Get-UninstallEntries | Where-Object { $_.productCode -match '^\{' })
                foreach ($e in $entries) {
                    Add-Step $A "Removing the damaged existing installation ($($e.name) $($e.version))..." 'warn'
                    $u = Invoke-Proc 'msiexec.exe' @('/x', $e.productCode, '/qn', '/norestart') 600
                    Add-Step $A "Removal exit code: $($u.exitCode)"
                }
                $msiArgs = @('/i', $msi, '/qn', '/norestart', '/l*v', $log)
                continue
            }
            break
        }
        if ($code -ne 0) { $haveMsi = $false; Add-Step $A "Full installer log: $log" }
    }

    if (-not $haveMsi -or $code -ne 0) {
        $wg = $null
        try { $wg = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source } catch { }
        if ($wg) {
            Add-Step $A 'Trying winget as a fallback...'
            $wArgs = if ($Mode -eq 'update' -or $Mode -eq 'repair') { @('upgrade', '--id', 'Tailscale.Tailscale', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
            else { @('install', '--id', 'Tailscale.Tailscale', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
            $w = Invoke-Proc $wg $wArgs 900
            Add-Step $A ('winget: ' + (Get-Tail $w.output 5))
            if (-not $w.ok -and $wArgs[0] -eq 'upgrade') {
                $wArgs[0] = 'install'; $wArgs += '--force'
                $w = Invoke-Proc $wg $wArgs 900
                Add-Step $A ('winget: ' + (Get-Tail $w.output 5))
            }
        } else { Add-Step $A 'winget is not available for a fallback install.' 'warn' }
    }

    Clear-Cache
    $paths = Get-TsPaths
    if (-not $paths.cli -or -not $paths.daemon) {
        Add-Step $A 'Tailscale is still not installed.' 'error'
        $A.hints += 'If downloads fail: download the installer on another device from https://tailscale.com/download/windows, copy it here, and run it. If downloads are blocked, the same security software/firewall is probably blocking Tailscale itself.'
        return $false
    }
    Add-Step $A "Tailscale is installed: $($paths.cli)"
    $h = New-ActionResult
    [void](Set-ServiceHardening $h)
    [void](Restart-TailscaleService $h -StartOnly)
    $A.steps += $h.steps; $A.hints += $h.hints
    return $true
}

function Get-LoginArgs($P) {
    $a = @()
    if ($P.unattended) { $a += '--unattended' }
    if ($P.hostname) {
        $hn = ([string]$P.hostname).Trim()
        if ($hn -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]{0,62}$') { throw "Invalid device name '$hn': use letters, digits and dashes only." }
        $a += "--hostname=$hn"
    }
    if ($P.tags) {
        $tags = @(([string]$P.tags) -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { if ($_ -notmatch '^tag:') { "tag:$_" } else { $_ } })
        foreach ($t in $tags) { if ($t -notmatch '^tag:[A-Za-z0-9][A-Za-z0-9\-]*$') { throw "Invalid tag '$t'." } }
        if ($tags.Count) { $a += ('--advertise-tags=' + ($tags -join ',')) }
    }
    if ($P.acceptRoutes) { $a += '--accept-routes' }
    return , $a
}

function Invoke-TsWithFallback($A, [string[]]$Primary, [int]$TimeoutSec) {
    $p = Invoke-Ts $Primary $TimeoutSec
    if (-not $p.ok -and $p.output -match 'requires mentioning all non-default flags') {
        Add-Step $A 'Tailscale wants the existing settings repeated; retrying with them.' 'warn'
        $m = [regex]::Match($p.output, '(?m)^\s*tailscale(?:\.exe)? up(?<rest>.*)$')
        if ($m.Success) {
            # Keep every existing setting tailscale listed, but let ours win.
            $merged = [ordered]@{}
            foreach ($tok in @(Split-CommandLine $m.Groups['rest'].Value) + @($Primary | Select-Object -Skip 1)) {
                if ($tok -notmatch '^--') { continue }
                $merged[($tok -split '=', 2)[0]] = $tok
            }
            $p = Invoke-Ts (@('up') + @($merged.Values)) $TimeoutSec
        }
        if (-not $p.ok -and $p.output -match 'requires mentioning all non-default flags') {
            Add-Step $A 'Retrying with --reset (other custom settings return to defaults).' 'warn'
            $p = Invoke-Ts (@('up', '--reset') + @($Primary | Select-Object -Skip 1)) $TimeoutSec
        }
    }
    return $p
}

function Invoke-KeyLogin($A, $P) {
    $key = ([string]$P.authKey).Trim()
    if (-not $key) { throw 'Paste an auth key first.' }
    if ($key -notmatch '^tskey-') { Add-Step $A 'Warning: auth keys normally start with "tskey-". Trying anyway.' 'warn' }
    if ($key -match '\s') { throw 'The auth key contains spaces; copy it again.' }
    $extra = Get-LoginArgs $P
    $st = Get-TsStatus
    if (-not $st.reachable) {
        Add-Step $A 'The service is not answering; restarting it first.' 'warn'
        if (-not (Restart-TailscaleService $A)) { throw 'The Tailscale service is not running. Fix the service first.' }
    }
    Add-Step $A 'Logging in with the auth key (up to 90 s)...'
    $args1 = @('up', "--auth-key=$key", '--timeout=75s') + $extra
    $p = Invoke-TsWithFallback $A $args1 95
    if ($p.output -match 'flag provided but not defined.*timeout') { $p = Invoke-TsWithFallback $A (@('up', "--auth-key=$key") + $extra) 95 }
    Clear-Cache
    $st = Get-TsStatus
    $state = if ($st.reachable) { [string]$st.json.BackendState } else { 'unknown' }
    if ($p.output) { Add-Step $A ('Tailscale says: ' + (Get-Tail $p.output 6)) }
    if ($state -eq 'Running') { Add-Step $A 'Logged in and connected.'; return $true }
    if ($state -eq 'NeedsMachineAuth') { Add-Step $A 'Logged in; waiting for an admin to approve this device in the admin console.' 'warn'; $A.hints += 'Approve it at https://login.tailscale.com/admin/machines'; return $true }
    Add-Step $A "Login did not complete (state: $state)." 'error'
    foreach ($h in (Get-ErrorHints ($p.output + ' ' + $p.error))) { $A.hints += $h }
    if ($p.timedOut -or $p.output -match 'timeout|deadline') { $A.hints += 'Login timed out: this is a network block, not a key problem. Run the full check and fix the red network items (Secure connection / Security software / Reachability).' }
    return $false
}

function Start-BrowserLogin($A, $P) {
    $exe = Get-TsExe
    if (-not $exe) { throw 'Tailscale is not installed.' }
    $tsArgs = @('login') + (Get-LoginArgs $P)
    $st = Get-TsStatus
    if (-not $st.reachable) {
        Add-Step $A 'The service is not answering; restarting it first.' 'warn'
        if (-not (Restart-TailscaleService $A)) { throw 'The Tailscale service is not running. Fix the service first.' }
    }
    if ($script:LoginProc -and -not $script:LoginProc.HasExited) { try { Stop-ProcessTree $script:LoginProc.Id } catch { } }
    $out = Join-Path $script:DataDir 'login-out.txt'; $err = Join-Path $script:DataDir 'login-err.txt'
    Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    Add-Step $A 'Requesting a login link from Tailscale (up to 45 s)...'
    # Runs detached from this request (it keeps waiting until the login is
    # approved), with output going to files we can poll. No console window.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /s /c ""' + $exe + '" ' + ((@($tsArgs | ForEach-Object { ConvertTo-ArgString $_ })) -join ' ') + ' > "' + $out + '" 2> "' + $err + '""'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $script:LoginProc = $proc
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $text = (Read-SharedText $out) + "`n" + (Read-SharedText $err)
        $m = [regex]::Match($text, 'https://[^\s"<>]+')
        if ($m.Success) {
            $A.data.url = $m.Value
            Add-Step $A 'Got a login link. Open it, sign in, and approve; this page updates automatically.'
            return $true
        }
        if ($proc.HasExited) {
            Clear-Cache
            $st = Get-TsStatus
            if ($st.reachable -and $st.json.BackendState -eq 'Running') { Add-Step $A 'Already logged in and connected.'; return $true }
            if ($st.reachable -and $st.json.AuthURL) { $A.data.url = $st.json.AuthURL; Add-Step $A 'Got a login link.'; return $true }
            Add-Step $A ('Tailscale exited: ' + (Get-Tail $text 6)) 'error'
            foreach ($h in (Get-ErrorHints $text)) { $A.hints += $h }
            return $false
        }
    }
    Clear-Cache
    $st = Get-TsStatus
    if ($st.reachable -and $st.json.AuthURL) { $A.data.url = $st.json.AuthURL; Add-Step $A 'Got a login link.'; return $true }
    Add-Step $A 'No login link after 45 s: Tailscale cannot reach its login server.' 'error'
    $A.hints += 'This is a network block, not an account problem. Run the full check and fix the red network items first.'
    try { Stop-ProcessTree $proc.Id } catch { }
    return $false
}

function Invoke-Action([string]$Name, $P) {
    $A = New-ActionResult
    if ($null -eq $P) { $P = [pscustomobject]@{} }
    Write-Log "=== Action: $Name ===" 'info'
    try {
        switch ($Name) {
            'install' { $A.ok = Install-Tailscale $A 'install' }
            'repair' { $A.ok = Install-Tailscale $A 'repair' }
            'update' { $A.ok = Install-Tailscale $A 'update' }
            'start-service' { $A.ok = Restart-TailscaleService $A -StartOnly }
            'restart-service' { $A.ok = Restart-TailscaleService $A }
            'harden-service' { $A.ok = Set-ServiceHardening $A }
            'enable-adapter' {
                $ad = @(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -like 'Tailscale*' -or $_.Name -like 'Tailscale*' })
                foreach ($a in $ad) { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop; Add-Step $A "Enabled adapter '$($a.Name)'." }
                $A.ok = $true
            }
            'connect' {
                $p = Invoke-TsWithFallback $A @('up', '--timeout=60s') 80
                if ($p.output) { Add-Step $A ('Tailscale says: ' + (Get-Tail $p.output 6)) }
                Clear-Cache
                $st = Get-TsStatus
                $A.ok = ($st.reachable -and $st.json.BackendState -eq 'Running')
                if (-not $A.ok) {
                    foreach ($h in (Get-ErrorHints $p.output)) { $A.hints += $h }
                    if ($st.reachable -and $st.json.BackendState -eq 'NeedsLogin') { $A.hints += 'Tailscale needs you to log in.' }
                }
            }
            'login-key' { $A.ok = Invoke-KeyLogin $A $P }
            'login-browser' { $A.ok = Start-BrowserLogin $A $P }
            'login-poll' {
                Clear-Cache
                $st = Get-TsStatus
                $A.data.backendState = if ($st.reachable) { [string]$st.json.BackendState } else { $null }
                $A.data.loginRunning = [bool]($script:LoginProc -and -not $script:LoginProc.HasExited)
                $A.ok = ($A.data.backendState -in @('Running', 'NeedsMachineAuth'))
            }
            'enable-unattended' {
                $p = Invoke-Ts @('set', '--unattended=true') 30
                if (-not $p.ok -and $p.output -match 'unknown|not defined|flag') {
                    Add-Step $A '"tailscale set" is not available in this version; using "tailscale up".' 'warn'
                    $p = Invoke-TsWithFallback $A @('up', '--unattended') 60
                }
                if ($p.output) { Add-Step $A ('Tailscale says: ' + (Get-Tail $p.output 4)) }
                Clear-Cache
                $prefs = Get-TsPrefs
                $A.ok = [bool]($prefs -and $prefs.ForceDaemon)
                if ($A.ok) { Add-Step $A 'Unattended mode is on: Tailscale stays connected when no one is signed in to Windows.' }
                else { foreach ($h in (Get-ErrorHints $p.output)) { $A.hints += $h } }
            }
            'logout' {
                $p = Invoke-Ts @('logout') 30
                Add-Step $A ('Tailscale says: ' + (Get-Tail $p.output 4))
                $A.ok = $p.ok
            }
            'firewall-allow' {
                $paths = Get-TsPaths
                if (-not $paths.daemon) { throw 'tailscaled.exe not found.' }
                foreach ($prog in @($paths.daemon, $paths.gui, $paths.cli)) {
                    if (-not $prog) { continue }
                    $leaf = Split-Path -Leaf $prog
                    foreach ($dir in @('Inbound', 'Outbound')) {
                        $name = "Tailscale Doctor - allow $leaf ($dir)"
                        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
                        New-NetFirewallRule -DisplayName $name -Direction $dir -Program $prog -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                        Add-Step $A "Added rule: $name"
                    }
                }
                $A.ok = $true
            }
            'firewall-remove-blocks' {
                $blocks = @(Get-NetFirewallRule -Enabled True -Action Block | Where-Object {
                        $af = $_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                        ($af.Program -match 'tailscale') -or ($_.DisplayName -match 'tailscale')
                    })
                foreach ($b in $blocks) { Disable-NetFirewallRule -Name $b.Name -ErrorAction Stop; Add-Step $A "Disabled block rule: $($b.DisplayName)" }
                $A.ok = $true
            }
            'time-resync' {
                try { Set-Service -Name w32time -StartupType Automatic -ErrorAction Stop } catch { }
                try { Start-Service -Name w32time -ErrorAction Stop; Add-Step $A 'Windows Time service running.' } catch { Add-Step $A ('Could not start Windows Time: ' + (Get-InnerMessage $_)) 'warn' }
                $p = Invoke-Proc 'w32tm.exe' @('/config', '/update', '/syncfromflags:manual', '/manualpeerlist:time.windows.com,0x9 pool.ntp.org,0x9 time.cloudflare.com,0x9') 20
                $p = Invoke-Proc 'w32tm.exe' @('/resync', '/force') 30
                Add-Step $A ('w32tm: ' + (Get-Tail $p.output 3))
                Start-Sleep -Seconds 2
                $script:Cache.Remove('clockskew')
                $s = Get-ClockSkew
                if ($s.ok -and [Math]::Abs($s.skewSec) -gt 120) {
                    Add-Step $A "Clock still off by $($s.skewSec) s (NTP probably blocked). Setting it from an internet time source." 'warn'
                    Set-Date -Date ((Get-Date).AddSeconds(-$s.skewSec)) | Out-Null
                    $script:Cache.Remove('clockskew'); $s = Get-ClockSkew
                }
                if ($s.ok) { Add-Step $A "Clock is now off by $($s.skewSec) s." }
                $A.ok = (-not $s.ok) -or ([Math]::Abs($s.skewSec) -le 120)
            }
            'flush-dns' {
                try { Clear-DnsClientCache -ErrorAction Stop } catch { }
                $p = Invoke-Proc 'ipconfig.exe' @('/flushdns') 15
                Add-Step $A 'DNS cache flushed.'
                $A.ok = $true
            }
            'reset-winhttp-proxy' {
                $p = Invoke-Proc 'netsh.exe' @('winhttp', 'reset', 'proxy') 15
                Add-Step $A ('netsh: ' + (Get-Tail $p.output 3))
                $h = New-ActionResult
                [void](Restart-TailscaleService $h)
                $A.steps += $h.steps
                $A.ok = $p.ok
            }
            'defender-exclusion' {
                $paths = Get-TsPaths
                Add-MpPreference -ExclusionPath $paths.dir -ErrorAction Stop
                Add-MpPreference -ExclusionProcess @('tailscaled.exe', 'tailscale.exe', 'tailscale-ipn.exe') -ErrorAction Stop
                Add-Step $A "Microsoft Defender will not scan $($paths.dir) or Tailscale's processes."
                $A.ok = $true
            }
            'reset-state' {
                $dir = Join-Path $env:ProgramData 'Tailscale'
                $backup = Join-Path $script:DataDir ('state-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Add-Step $A 'Stopping the service...'
                try { Stop-Service -Name Tailscale -Force -ErrorAction Stop } catch { Add-Step $A ('Stop: ' + (Get-InnerMessage $_)) 'warn' }
                if (-not (Wait-ServiceState 'Stopped' 20)) { Get-Process -Name tailscaled -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }; Start-Sleep -Seconds 3 }
                if (Test-Path -LiteralPath $dir) {
                    New-Item -ItemType Directory -Force -Path $backup | Out-Null
                    foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne 'Logs' })) {
                        Move-Item -LiteralPath $item.FullName -Destination $backup -Force -ErrorAction Stop
                    }
                    Add-Step $A "Old state moved to $backup"
                }
                $A.ok = Restart-TailscaleService $A -StartOnly
                if ($A.ok) { Add-Step $A 'Tailscale starts fresh. Log in now.' }
            }
            'bugreport' {
                $p = Invoke-Ts @('bugreport') 60
                $id = [regex]::Match($p.output, 'BUG-[A-Za-z0-9\-]+').Value
                if ($id) { Add-Step $A "Bug report ID: $id (give this to Tailscale support)"; $A.data.bugreport = $id; $A.ok = $true }
                else { Add-Step $A ('Could not create a bug report: ' + (Get-Tail $p.output 4)) 'error' }
            }
            default { throw "Unknown action '$Name'" }
        }
    } catch {
        $A.ok = $false
        Add-Step $A ('Error: ' + (Get-InnerMessage $_)) 'error'
        foreach ($h in (Get-ErrorHints (Get-InnerMessage $_))) { $A.hints += $h }
    }
    Clear-Cache
    $A.message = if ($A.ok) { 'Done' } else { 'Did not fully succeed' }
    $A.hints = @($A.hints | Select-Object -Unique)
    Write-Log "=== Action $Name finished: $($A.message) ===" $(if ($A.ok) { 'info' } else { 'warn' })
    return $A
}

# ---------------------------------------------------------------------------
# CLI mode
# ---------------------------------------------------------------------------

if ($Cli) {
    Write-Host "Tailscale Doctor $script:DoctorVersion - command-line mode`n" -ForegroundColor Cyan
    $results = @()
    foreach ($c in $script:Checks) {
        Write-Host ("Checking: " + $c.title + ' ...') -ForegroundColor DarkGray
        $results += , (Invoke-Check $c.id)
    }
    Write-Host ''
    foreach ($res in $results) {
        $color = switch ($res.status) { 'ok' { 'Green' } 'info' { 'Cyan' } 'warn' { 'Yellow' } 'skip' { 'DarkGray' } default { 'Red' } }
        Write-Host ("[{0,-5}] {1}: {2}" -f $res.status.ToUpper(), $res.title, $res.summary) -ForegroundColor $color
        if ($res.status -in @('fail', 'error', 'warn')) {
            foreach ($a in $res.advice) { Write-Host ("        -> " + $a) }
            foreach ($f in $res.fixes) { if ($f.auto -or $f.primary) { Write-Host ("        fix: " + $f.label) -ForegroundColor DarkCyan } }
        }
    }
    $out = if ($ReportPath) { $ReportPath } else { Join-Path $script:DataDir ('report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json') }
    try {
        $report = [ordered]@{ tool = "TailscaleDoctor $script:DoctorVersion"; created = (Get-Date).ToString('o'); computer = $env:COMPUTERNAME; results = $results }
        [IO.File]::WriteAllText($out, (Protect-Secrets ($report | ConvertTo-Json -Depth 10)), (New-Object Text.UTF8Encoding $false))
        Write-Host "`nReport saved: $out" -ForegroundColor Cyan
    } catch { Write-Warning ('Could not save report: ' + (Get-InnerMessage $_)) }
    exit 0
}

# ---------------------------------------------------------------------------
# Web server
# ---------------------------------------------------------------------------

function New-Token {
    $b = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b); $rng.Dispose()
    return ([BitConverter]::ToString($b) -replace '-', '').ToLower()
}

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Send-Bytes($Ctx, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $res = $Ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $ContentType
    $res.Headers['Cache-Control'] = 'no-store'
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['X-Frame-Options'] = 'DENY'
    $res.Headers['Referrer-Policy'] = 'no-referrer'
    $res.Headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Send-Json($Ctx, $Obj, [int]$Status = 200) {
    $json = $Obj | ConvertTo-Json -Depth 12 -Compress
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes([string]$json))
}

$script:StaticFiles = @{
    '/' = @('index.html', 'text/html; charset=utf-8')
    '/index.html' = @('index.html', 'text/html; charset=utf-8')
    '/app.js' = @('app.js', 'application/javascript; charset=utf-8')
    '/style.css' = @('style.css', 'text/css; charset=utf-8')
    '/favicon.svg' = @('favicon.svg', 'image/svg+xml')
}

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    # DNS-rebinding protection: only accept our exact host names.
    $hostHdr = [string]$req.Headers['Host']
    if ($hostHdr -ne "127.0.0.1:$script:ActualPort" -and $hostHdr -ne "localhost:$script:ActualPort") {
        Send-Json $Ctx @{ ok = $false; error = 'Bad host' } 403; return
    }
    if ($req.HttpMethod -eq 'GET' -and $script:StaticFiles.ContainsKey($path)) {
        $f = $script:StaticFiles[$path]
        $file = Join-Path $script:WebDir $f[0]
        if (-not (Test-Path -LiteralPath $file)) { Send-Json $Ctx @{ ok = $false; error = "Missing file web\$($f[0]). Re-extract Tailscale Doctor." } 500; return }
        Send-Bytes $Ctx 200 $f[1] ([IO.File]::ReadAllBytes($file)); return
    }
    if (-not $path.StartsWith('/api/')) { Send-Json $Ctx @{ ok = $false; error = 'Not found' } 404; return }

    if ([string]$req.Headers['X-Doctor-Token'] -ne $script:Token) { Send-Json $Ctx @{ ok = $false; error = 'Invalid or missing token. Open the link printed in the Tailscale Doctor console window.' } 403; return }
    $origin = [string]$req.Headers['Origin']
    if ($origin -and $origin -ne "http://127.0.0.1:$script:ActualPort" -and $origin -ne "http://localhost:$script:ActualPort") { Send-Json $Ctx @{ ok = $false; error = 'Bad origin' } 403; return }

    $body = $null
    if ($req.HttpMethod -eq 'POST') {
        if ($req.ContentLength64 -gt 65536) { Send-Json $Ctx @{ ok = $false; error = 'Request too large' } 413; return }
        $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
        $raw = $sr.ReadToEnd(); $sr.Close()
        if ($raw.Trim()) { try { $body = $raw | ConvertFrom-Json } catch { Send-Json $Ctx @{ ok = $false; error = 'Invalid JSON' } 400; return } }
    }

    switch ($path) {
        '/api/info' {
            Send-Json $Ctx @{ ok = $true; data = [ordered]@{
                    version = $script:DoctorVersion; computer = $env:COMPUTERNAME; admin = $script:IsAdmin; windows = $script:IsWin
                    logFile = $script:LogFile; dataDir = $script:DataDir
                    checks = @($script:Checks | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title } })
                }
            }
        }
        '/api/check' {
            if (-not $body -or -not $body.id) { Send-Json $Ctx @{ ok = $false; error = 'Missing id' } 400; return }
            if ($body.fresh) { Clear-Cache }
            Send-Json $Ctx @{ ok = $true; data = (Invoke-Check ([string]$body.id)) }
        }
        '/api/action' {
            if (-not $body -or -not $body.action) { Send-Json $Ctx @{ ok = $false; error = 'Missing action' } 400; return }
            $params = if ($body.params) { $body.params } else { [pscustomobject]@{} }
            Send-Json $Ctx @{ ok = $true; data = (Invoke-Action ([string]$body.action) $params) }
        }
        '/api/log' {
            $since = 0
            try { $since = [int]$req.QueryString['since'] } catch { }
            $items = @($script:LogBuffer | Where-Object { $_.seq -gt $since })
            Send-Json $Ctx @{ ok = $true; data = $items }
        }
        '/api/shutdown' {
            Send-Json $Ctx @{ ok = $true; data = 'bye' }
            $script:Running = $false
        }
        default { Send-Json $Ctx @{ ok = $false; error = 'Unknown endpoint' } 404 }
    }
}

$script:Token = New-Token
$listener = $null
$script:UrlHost = '127.0.0.1'
for ($i = 0; $i -lt 10 -and -not $listener; $i++) {
    $tryPort = if ($Port -and $i -eq 0) { $Port } else { Get-FreePort }
    # Without admin rights Windows only lets us register "localhost" prefixes.
    foreach ($set in @(@('127.0.0.1', 'localhost'), @('localhost'))) {
        $l = New-Object Net.HttpListener
        foreach ($hn in $set) { $l.Prefixes.Add("http://${hn}:$tryPort/") }
        try { $l.Start(); $listener = $l; $script:ActualPort = $tryPort; $script:UrlHost = $set[0]; break }
        catch { Write-Log "Could not listen on port ${tryPort} ($($set -join ',')): $(Get-InnerMessage $_)" 'warn'; try { $l.Close() } catch { } }
    }
}
if (-not $listener) {
    Write-Host 'Could not start the local web server. Falling back to command-line mode.' -ForegroundColor Red
    & $PSCommandPath -Cli -NoElevate
    exit 1
}

$url = "http://$($script:UrlHost):$script:ActualPort/?t=$script:Token"
try { $Host.UI.RawUI.WindowTitle = 'Tailscale Doctor - keep this window open' } catch { }
Write-Host ''
Write-Host '  Tailscale Doctor is running.' -ForegroundColor Cyan
Write-Host "  Open: $url" -ForegroundColor White
Write-Host '  Keep this window open while you use it. Close it (or press Ctrl+C) to quit.' -ForegroundColor DarkGray
Write-Host "  Log file: $script:LogFile" -ForegroundColor DarkGray
Write-Host ''
Write-Log "Tailscale Doctor $script:DoctorVersion started (admin=$script:IsAdmin, port=$script:ActualPort)"

if (-not $NoBrowser) {
    $opened = $false
    if ($script:IsWin) {
        # explorer.exe opens the default browser as the normal (non-elevated) user.
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $url + '"') -ErrorAction Stop; $opened = $true } catch { }
    }
    if (-not $opened) { try { Start-Process $url -ErrorAction Stop } catch { Write-Host '  Could not open a browser automatically; copy the link above.' -ForegroundColor Yellow } }
}

try {
    while ($script:Running) {
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(300)) { if (-not $script:Running) { break } }
        if (-not $task.IsCompleted) { break }
        $ctx = $null
        try { $ctx = $task.GetAwaiter().GetResult() } catch { Write-Log ('Listener error: ' + (Get-InnerMessage $_)) 'warn'; continue }
        try { Invoke-Request $ctx }
        catch {
            Write-Log ('Request failed: ' + (Get-InnerMessage $_)) 'error'
            try { Send-Json $ctx @{ ok = $false; error = ('Internal error: ' + (Get-InnerMessage $_)) } 500 } catch { }
        } finally {
            try { $ctx.Response.Close() } catch { }
        }
    }
} finally {
    Write-Log 'Shutting down.'
    try { $listener.Stop(); $listener.Close() } catch { }
    if ($script:LoginProc -and -not $script:LoginProc.HasExited) {
        # Leave a pending browser login running: it completes on its own once approved.
    }
}
