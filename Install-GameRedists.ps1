#Requires -Version 5.1
<#
.SYNOPSIS
    Silently installs all gaming redistributable packages via WinGet.

.DESCRIPTION
    Installs VC++ Redists, .NET Desktop Runtime, ASP.NET Core, DirectX,
    XNA, NanaZip, and the latest PowerShell. Always logs to
    C:\Windows\Setup\Scripts. Designed for autounattend.xml, imaging
    pipelines, and SSH/remote sessions.

    No options, no prompts, no custom colours. Pure PowerShell 5.1.

.NOTES
    Requires Windows 10 1809+ / Windows 11.
    Run as Administrator, or the script will self-elevate via UAC.

.LINK
    https://github.com/emilwojcik93/gaming-redists
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:LOG_DIR      = 'C:\Windows\Setup\Scripts'
$script:LOG_FILE     = Join-Path $script:LOG_DIR ("GameRedists_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:WINGET_MIN   = [Version]'1.22.1000'
$script:SOURCE_NAME  = 'winget'
$script:SOURCE_URL   = 'https://cdn.winget.microsoft.com/cache'
$script:SOURCE_TYPE  = 'Microsoft.PreIndexed.Package'

# Known "already up-to-date" exit codes from winget
$script:WINGET_UPTODATE = @(
    [int]-1978335189,
    [int]-1978335135,
    [int]-1978334963,
    [int]-1978334962,
    [int]-1978335153
)

# Fixed extras — always installed regardless of discovery
$script:FIXED_PACKAGES = @(
    'Microsoft.DirectX',
    'Microsoft.XNARedist',
    'M2Team.NanaZip',
    'Microsoft.PowerShell'
)

# ---------------------------------------------------------------------------
# Self-elevation
# ---------------------------------------------------------------------------
function Invoke-SelfElevation {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Host "Not running as Administrator. Re-launching elevated..."

    $argList = '-ExecutionPolicy Bypass -NoProfile'
    if ($PSCommandPath) {
        $argList += " -File `"$PSCommandPath`""
    } else {
        $argList += " -Command `"& { & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/emilwojcik93/gaming-redists/main/Install-GameRedists.ps1').Content)) }`""
    }

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru
    if ($null -eq $proc) {
        Write-Error "Elevation failed. Run the script as Administrator."
        exit 1
    }
    $proc.WaitForExit()
    exit $proc.ExitCode
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Initialize-Log {
    if (-not (Test-Path $script:LOG_DIR)) {
        New-Item -ItemType Directory -Path $script:LOG_DIR -Force | Out-Null
    }
    Start-Transcript -Path $script:LOG_FILE -Append -NoClobber | Out-Null
    Write-Log "=== Gaming Redists installer started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Write-Log "Log: $script:LOG_FILE"
    Write-Log "PS version: $($PSVersionTable.PSVersion)"
    Write-Log "OS: $([Environment]::OSVersion.VersionString)"
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Stop-Log {
    param([int]$ExitCode)
    Write-Log "=== Completed with exit code $ExitCode at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    try { Stop-Transcript | Out-Null } catch {}
}

# ---------------------------------------------------------------------------
# WinGet bootstrap (Assert-WinGet)
# ---------------------------------------------------------------------------
function Assert-WinGet {
    [OutputType([bool])]
    param()

    # Tier 1: already good
    if (Test-WinGetReady) {
        Write-Log "WinGet is ready (>= $script:WINGET_MIN)."
        return $true
    }

    Write-Log "WinGet missing or outdated. Installing dependencies..." 'WARN'

    # Tier 2: fast path via aka.ms
    try {
        Write-Progress -Activity 'WinGet Setup' -Status 'Installing VCLibs...' -PercentComplete 20
        Add-AppxPackage -Path 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -ErrorAction Stop

        Write-Progress -Activity 'WinGet Setup' -Status 'Installing UI.Xaml...' -PercentComplete 50
        Add-AppxPackage -Path 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx' -ErrorAction Stop

        Write-Progress -Activity 'WinGet Setup' -Status 'Installing WinGet...' -PercentComplete 80
        Add-AppxPackage -Path 'https://aka.ms/getwinget' -ErrorAction Stop

        Write-Progress -Activity 'WinGet Setup' -Completed
        if (Test-WinGetReady) {
            Write-Log "WinGet installed via fast path."
            return $true
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Fast path failed: $errMsg" 'WARN'

        # Tier 3: WindowsAppRuntime missing — extract version and install it
        if ($errMsg -match 'Microsoft\.WindowsAppRuntime\.(\d+\.\d+)') {
            $runtimeVer = $Matches[1]
            Write-Log "Installing WindowsAppRuntime $runtimeVer..."
            try {
                $runtimeUrl = "https://aka.ms/windowsappsdk/$runtimeVer/latest/windowsappruntimeinstall-x64.exe"
                $runtimeExe = Join-Path $env:TEMP "WindowsAppRuntimeInstall_$runtimeVer.exe"
                Invoke-WebRequest -Uri $runtimeUrl -OutFile $runtimeExe -UseBasicParsing -ErrorAction Stop
                Start-Process -FilePath $runtimeExe -ArgumentList '--quiet' -Wait -ErrorAction Stop
                Remove-Item $runtimeExe -Force -ErrorAction SilentlyContinue

                Write-Progress -Activity 'WinGet Setup' -Status 'Retrying WinGet install...' -PercentComplete 90
                Add-AppxPackage -Path 'https://aka.ms/getwinget' -ErrorAction Stop
                Write-Progress -Activity 'WinGet Setup' -Completed

                if (Test-WinGetReady) {
                    Write-Log "WinGet installed via Tier 3 (WindowsAppRuntime $runtimeVer)."
                    return $true
                }
            } catch {
                Write-Log "Tier 3 failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    # Tier 4: GitHub direct download fallback
    Write-Log "Trying GitHub direct download fallback..." 'WARN'
    try {
        $msixUrl  = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        $msixPath = Join-Path $env:TEMP 'WinGet.msixbundle'
        Invoke-WebRequest -Uri $msixUrl -OutFile $msixPath -UseBasicParsing -ErrorAction Stop
        Add-AppxPackage -Path $msixPath -ForceApplicationShutdown -ErrorAction Stop
        Remove-Item $msixPath -Force -ErrorAction SilentlyContinue
        Write-Progress -Activity 'WinGet Setup' -Completed

        if (Test-WinGetReady) {
            Write-Log "WinGet installed via Tier 4 (GitHub fallback)."
            return $true
        }
    } catch {
        Write-Log "Tier 4 failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Progress -Activity 'WinGet Setup' -Completed
    Write-Log "WinGet could not be installed after all attempts." 'ERROR'
    return $false
}

function Test-WinGetReady {
    [OutputType([bool])]
    param()
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
        if ($null -eq $pkg) { return $false }
        $ver = [Version]$pkg.Version
        if ($ver -lt $script:WINGET_MIN) { return $false }
        # Verify the binary is callable
        $out = & winget --version 2>&1 | Out-String
        return ($out -match '^v\d+\.\d+')
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# WinGet source health (Assert-WinGetSource)
# ---------------------------------------------------------------------------
function Assert-WinGetSource {
    [OutputType([bool])]
    param()

    # Step 1: source must be listed
    $sourceList = & winget source list 2>&1 | Out-String
    if ($sourceList -notmatch $script:SOURCE_NAME) {
        Write-Log "WinGet '$($script:SOURCE_NAME)' source missing from source list." 'WARN'
        return Invoke-SourceRecovery
    }

    # Step 2: timed source update (60 s hard timeout — source update can hang indefinitely)
    Write-Log "Updating WinGet sources (60 s timeout)..."
    $updateProc = Start-Process -FilePath 'winget' `
        -ArgumentList "source update --accept-source-agreements" `
        -NoNewWindow -PassThru -ErrorAction SilentlyContinue
    if ($null -ne $updateProc) {
        if (-not $updateProc.WaitForExit(60000)) {
            Write-Log "winget source update timed out — killing process." 'WARN'
            try { $updateProc.Kill() } catch {}
        }
    }

    # Step 3: probe search — detect "Failed when searching source"
    if (-not (Test-WinGetSourceProbe)) {
        Write-Log "Probe search failed — '$($script:SOURCE_NAME)' source returns errors." 'WARN'
        return Invoke-SourceRecovery
    }

    return $true
}

function Test-WinGetSourceProbe {
    [OutputType([bool])]
    param()
    try {
        $out = & winget search 'Microsoft.VCRedist.2015+.x64' --source $script:SOURCE_NAME `
            --accept-source-agreements 2>&1 | Out-String
        if ($out -match 'Failed when searching source') { return $false }
        return ($out -match 'Microsoft\.VCRedist')
    } catch {
        return $false
    }
}

function Invoke-SourceRecovery {
    [OutputType([bool])]
    param()

    # Attempt 1: reset (restores default sources)
    Write-Log "Attempting source recovery — winget source reset --force..."
    try {
        & winget source reset --force --accept-source-agreements 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        if (Test-WinGetSourceProbe) {
            Write-Log "Source recovered via reset."
            return $true
        }
    } catch {
        Write-Log "Source reset failed: $($_.Exception.Message)" 'WARN'
    }

    # Attempt 2: manual re-add
    Write-Log "Attempting manual source re-add..."
    try {
        & winget source remove $script:SOURCE_NAME 2>&1 | Out-Null
        & winget source add --name $script:SOURCE_NAME --type $script:SOURCE_TYPE `
            $script:SOURCE_URL --accept-source-agreements 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        if (Test-WinGetSourceProbe) {
            Write-Log "Source recovered via manual re-add."
            return $true
        }
    } catch {
        Write-Log "Manual source re-add failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "WinGet source '$($script:SOURCE_NAME)' could not be recovered." 'ERROR'
    return $false
}

# ---------------------------------------------------------------------------
# Package discovery (Get-WinGetIds)
# ---------------------------------------------------------------------------
function Get-WinGetIds {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]   $Query,
        [Parameter(Mandatory)][string[]] $MatchPattern,
        [string[]] $ExcludePattern = @()
    )

    try {
        $raw = & winget search $Query --source $script:SOURCE_NAME `
            --accept-source-agreements 2>&1

        $ids = $raw | ForEach-Object {
            # Package IDs in winget output follow the pattern Vendor.Product.Version
            # They start after the display name column; match any token that looks like an ID
            if ($_ -match '\b([A-Za-z0-9][\w.-]{4,})\b') {
                $Matches[1]
            }
        } | Where-Object { $_ } | Select-Object -Unique

        $ids = $ids | Where-Object {
            $id = $_
            $include = $MatchPattern  | Where-Object { $id -match $_ }
            $exclude = $ExcludePattern | Where-Object { $id -match $_ }
            ($null -ne $include -and $include.Count -gt 0) -and
            ($null -eq $exclude -or $exclude.Count -eq 0)
        }

        return @($ids)
    } catch {
        Write-Log "Get-WinGetIds failed for '$Query': $($_.Exception.Message)" 'WARN'
        return @()
    }
}

# ---------------------------------------------------------------------------
# Install one package with retry (Invoke-WinGetInstall)
# ---------------------------------------------------------------------------
function Invoke-WinGetInstall {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Id,
        [int] $MaxRetries = 3,
        [int] $RetryDelaySec = 5
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++

        if ($PSCmdlet.ShouldProcess($Id, 'winget install')) {
            $output = & winget install --id $Id `
                --source $script:SOURCE_NAME `
                --silent `
                --accept-package-agreements `
                --accept-source-agreements `
                --disable-interactivity 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } else {
            # -WhatIf: report but don't install
            Write-Log "  [WhatIf] Would install: $Id"
            return 'WhatIf'
        }

        # Mid-run source error — trigger recovery once then retry
        if ($output -match 'Failed when searching source') {
            Write-Log "  Source error during install of '$Id' — attempting recovery..." 'WARN'
            $recovered = Invoke-SourceRecovery
            if (-not $recovered) { return 'Failed' }
            continue
        }

        if ($exitCode -eq 0)                          { return 'Installed' }
        if ($script:WINGET_UPTODATE -contains $exitCode) { return 'AlreadyUpToDate' }

        # Real failure — retry with delay
        if ($attempt -lt $MaxRetries) {
            Write-Log "  '$Id' failed (exit $exitCode) — retry $attempt/$MaxRetries in ${RetryDelaySec}s..." 'WARN'
            Start-Sleep -Seconds $RetryDelaySec
        }
    }

    Write-Log "  '$Id' failed after $MaxRetries attempts." 'ERROR'
    return 'Failed'
}

# ---------------------------------------------------------------------------
# Install a batch of packages with progress (Invoke-WinGetBatch)
# ---------------------------------------------------------------------------
function Invoke-WinGetBatch {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]   $GroupName,
        [Parameter(Mandatory)][string[]] $Ids,
        [Parameter(Mandatory)][int]      $StartIndex,
        [Parameter(Mandatory)][int]      $TotalCount
    )

    $results = @{ Installed = 0; AlreadyUpToDate = 0; Failed = 0; FailedIds = @() }
    $i = $StartIndex

    foreach ($id in $Ids) {
        $pct = [int](($i / $TotalCount) * 100)
        Write-Progress -Activity 'Gaming Redists' `
            -Status "$GroupName  —  $id" `
            -PercentComplete $pct `
            -CurrentOperation "Package $i of $TotalCount"

        Write-Log "  Installing $id..."
        $status = Invoke-WinGetInstall -Id $id
        Write-Log "  $id  ->  $status"

        switch ($status) {
            'Installed'      { $results.Installed++ }
            'AlreadyUpToDate'{ $results.AlreadyUpToDate++ }
            'WhatIf'         { }
            default          { $results.Failed++; $results.FailedIds += $id }
        }
        $i++
    }

    return $results
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Invoke-SelfElevation

    Initialize-Log

    # --- WinGet bootstrap ---
    Write-Progress -Activity 'Gaming Redists' -Status 'Bootstrapping WinGet...' -PercentComplete 0
    if (-not (Assert-WinGet)) {
        Stop-Log -ExitCode 1
        exit 1
    }

    # --- Source health ---
    Write-Progress -Activity 'Gaming Redists' -Status 'Checking WinGet source...' -PercentComplete 2
    if (-not (Assert-WinGetSource)) {
        Stop-Log -ExitCode 1
        exit 1
    }

    # --- Discover packages ---
    Write-Progress -Activity 'Gaming Redists' -Status 'Discovering packages...' -PercentComplete 5

    Write-Log "Discovering VC++ packages..."
    $vcIds = Get-WinGetIds -Query 'Microsoft.VCRedist' `
        -MatchPattern   @('^Microsoft\.VCRedist\.') `
        -ExcludePattern @('arm', 'Uninstaller', 'Developer')

    Write-Log "Discovering .NET Desktop Runtime packages..."
    $dotnetIds = Get-WinGetIds -Query 'Microsoft.DotNet.DesktopRuntime' `
        -MatchPattern   @('^Microsoft\.DotNet\.DesktopRuntime') `
        -ExcludePattern @('arm')

    Write-Log "Discovering ASP.NET Core packages..."
    $aspnetIds = Get-WinGetIds -Query 'Microsoft.DotNet.AspNetCore' `
        -MatchPattern   @('^Microsoft\.DotNet\.AspNetCore') `
        -ExcludePattern @('arm')

    $allIds     = $vcIds + $dotnetIds + $aspnetIds + $script:FIXED_PACKAGES
    $totalCount = $allIds.Count

    Write-Log ("Found {0} VC++, {1} .NET Runtime, {2} ASP.NET, {3} extras = {4} total" -f
        $vcIds.Count, $dotnetIds.Count, $aspnetIds.Count, $script:FIXED_PACKAGES.Count, $totalCount)

    if ($totalCount -eq 0) {
        Write-Log "No packages discovered. Verify WinGet source is healthy." 'ERROR'
        Stop-Log -ExitCode 1
        exit 1
    }

    # --- Install ---
    $totals = @{ Installed = 0; AlreadyUpToDate = 0; Failed = 0; FailedIds = @() }
    $idx    = 0

    foreach ($group in @(
        @{ Name = 'VC++ Redists';         Ids = $vcIds             },
        @{ Name = '.NET Desktop Runtime'; Ids = $dotnetIds         },
        @{ Name = 'ASP.NET Core';         Ids = $aspnetIds         },
        @{ Name = 'Extras';               Ids = $script:FIXED_PACKAGES }
    )) {
        if ($group.Ids.Count -eq 0) { continue }
        Write-Log "--- $($group.Name) ---"

        $r = Invoke-WinGetBatch -GroupName $group.Name -Ids $group.Ids `
            -StartIndex $idx -TotalCount $totalCount

        $totals.Installed      += $r.Installed
        $totals.AlreadyUpToDate += $r.AlreadyUpToDate
        $totals.Failed         += $r.Failed
        $totals.FailedIds      += $r.FailedIds
        $idx += $group.Ids.Count
    }

    Write-Progress -Activity 'Gaming Redists' -Completed

    # --- Summary ---
    Write-Log "=== Summary ==="
    Write-Log ("  Installed       : {0}" -f $totals.Installed)
    Write-Log ("  Already up-to-date: {0}" -f $totals.AlreadyUpToDate)
    Write-Log ("  Failed          : {0}" -f $totals.Failed)

    if ($totals.Failed -gt 0) {
        foreach ($fid in $totals.FailedIds) {
            Write-Log "  FAILED: $fid" 'WARN'
        }
    }

    $exitCode = if ($totals.Failed -gt 0) { 2 } else { 0 }
    Stop-Log -ExitCode $exitCode
    exit $exitCode
}

Main
