# gaming-redists

Pure PowerShell 5.1 installer for all gaming redistributables on Windows 11.
No batch files, no options, no prompts. Always installs everything, always logs.

Designed for **autounattend.xml** imaging pipelines, SSH/remote sessions, and
one-liner use from a fresh Windows install.

---

## What it installs

| Group | Source |
|---|---|
| VC++ Redists 2005 – 2022+ (x86 + x64) | Dynamic via `winget search` |
| .NET Desktop Runtime (all current versions) | Dynamic via `winget search` |
| ASP.NET Core (all current versions) | Dynamic via `winget search` |
| DirectX | `Microsoft.DirectX` |
| XNA Framework | `Microsoft.XNARedist` |
| NanaZip | `M2Team.NanaZip` |
| PowerShell (latest) | `Microsoft.PowerShell` |

All packages are installed silently from the `winget` source with
`--accept-package-agreements --accept-source-agreements --disable-interactivity`.

---

## Usage

### Non-elevated shell (UAC pops once, then fully automated)

~~~powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/emilwojcik93/gaming-redists/main/Install-GameRedists.ps1').Content))
~~~

### Already-elevated shell / SSH / RDP

~~~powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File Install-GameRedists.ps1
~~~

### autounattend.xml — FirstLogonCommands

Add to the `FirstLogonCommands` pass (runs on first user logon — required for
WinGet and Microsoft Store packages to work correctly):

~~~xml
<FirstLogonCommands>
  <SynchronousCommand wcm:action="add">
    <Order>1</Order>
    <RequiresUserInput>false</RequiresUserInput>
    <CommandLine>powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "&amp; { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; &amp; ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/emilwojcik93/gaming-redists/main/Install-GameRedists.ps1').Content)) }"</CommandLine>
    <Description>Install Gaming Redistributables</Description>
  </SynchronousCommand>
</FirstLogonCommands>
~~~

> Compatible with [schneegans.de/windows/unattend-generator/](https://schneegans.de/windows/unattend-generator/).

---

## Logs

All output is transcribed to:

~~~
C:\Windows\Setup\Scripts\GameRedists_YYYYMMDD_HHmmss.log
~~~

The directory is created automatically if it does not exist (requires admin).

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All packages installed or already up-to-date |
| `1` | Fatal error — WinGet bootstrap or source health check failed |
| `2` | One or more packages failed after 3 retry attempts |

---

## WinGet bootstrap

If WinGet is missing or outdated (< 1.22.1000), the script installs it
automatically in tiers — no `curl.exe`, no binaries in the repo:

1. `aka.ms/getwinget` fast path (VCLibs + UI.Xaml + WinGet)
2. Detect missing `WindowsAppRuntime` version from exception → install from `aka.ms/windowsappsdk`
3. GitHub direct download fallback (`winget-cli/releases/latest`)

---

## Source reliability

The `winget` source can occasionally be unavailable or return
`Failed when searching source`. The script handles this with:

- Timed `winget source update` (60 s hard kill to avoid hangs)
- Probe search after update to confirm CDN reachability
- Automatic `winget source reset --force` + manual re-add to
  `https://cdn.winget.microsoft.com/cache` if the probe fails

---

## Requirements

- Windows 10 1809+ or Windows 11
- PowerShell 5.1 (inbox on all supported Windows versions)
- Internet access (packages downloaded at install time)
- Administrator privileges (self-elevation via UAC if not already elevated)

---

## CI

GitHub Actions runs on every push and pull request:

1. PS 5.1 syntax check
2. PSScriptAnalyzer (Warning + Error)
3. Unit tests with mocked winget/AppxPackage (no installs)
4. Live winget source reachability probe
5. Fixed package ID validation against the winget catalogue

[![Validate](https://github.com/emilwojcik93/gaming-redists/actions/workflows/validate.yml/badge.svg)](https://github.com/emilwojcik93/gaming-redists/actions/workflows/validate.yml)
