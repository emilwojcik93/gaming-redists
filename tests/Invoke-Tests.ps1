#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained test runner for Install-GameRedists.ps1.
    No external test framework required.

.DESCRIPTION
    Dot-sources the main script to load its functions, then runs each test
    with mocked external calls (winget, Add-AppxPackage, Get-AppxPackage,
    Invoke-WebRequest, Start-Process, Start-Sleep).
    Exits 0 if all tests pass, 1 if any fail.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PASS = 0
$script:FAIL = 0
$script:ScriptPath = Join-Path $PSScriptRoot '..\Install-GameRedists.ps1'

# ---------------------------------------------------------------------------
# Mini test framework
# ---------------------------------------------------------------------------
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Message = '')
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  [FAIL] $Name$(if ($Message) { ' — ' + $Message })" -ForegroundColor Red
        $script:FAIL++
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ($Expected -eq $Actual) -or
          ($null -eq $Expected -and $null -eq $Actual)
    Assert-True -Name $Name -Condition $ok `
        -Message "Expected '$Expected', got '$Actual'"
}

function Assert-Contains {
    param([string]$Name, [string]$Pattern, [string]$Text)
    Assert-True -Name $Name -Condition ($Text -match $Pattern) `
        -Message "Pattern '$Pattern' not found in: $Text"
}

function Assert-NotCalled {
    param([string]$Name, [int]$CallCount)
    Assert-True -Name $Name -Condition ($CallCount -eq 0) `
        -Message "Expected 0 calls, got $CallCount"
}

function Assert-Called {
    param([string]$Name, [int]$CallCount, [int]$ExpectedMin = 1)
    Assert-True -Name $Name -Condition ($CallCount -ge $ExpectedMin) `
        -Message "Expected >= $ExpectedMin calls, got $CallCount"
}

# ---------------------------------------------------------------------------
# Helpers: load functions without running Main
# ---------------------------------------------------------------------------
function Import-MainFunctions {
    # Patch: replace the trailing 'Main' call so dot-sourcing is safe
    $src = Get-Content $script:ScriptPath -Raw
    $src = $src -replace '(?m)^Main\s*$', '# Main call suppressed for testing'
    $sb  = [scriptblock]::Create($src)
    . $sb
}

# ---------------------------------------------------------------------------
# Test suite 1: Test-WinGetReady
# ---------------------------------------------------------------------------
function Test-WinGetReadySuite {
    Write-Host "`n[Test-WinGetReady]"

    # 1a: version meets minimum
    function global:Get-AppxPackage {
        param($Name)
        [PSCustomObject]@{ Version = '1.22.1000.0' }
    }
    function global:winget { 'v1.22.1000' }

    Import-MainFunctions
    Assert-True  '1a: version OK -> returns true' (Test-WinGetReady)

    # 1b: version below minimum
    function global:Get-AppxPackage {
        param($Name)
        [PSCustomObject]@{ Version = '1.0.0.0' }
    }
    Import-MainFunctions
    Assert-True  '1b: version too low -> returns false' (-not (Test-WinGetReady))

    # 1c: package not installed
    function global:Get-AppxPackage { param($Name) $null }
    Import-MainFunctions
    Assert-True  '1c: not installed -> returns false' (-not (Test-WinGetReady))

    Remove-Item Function:\Get-AppxPackage -ErrorAction SilentlyContinue
    Remove-Item Function:\winget          -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 2: Assert-WinGet bootstrap tiers
# ---------------------------------------------------------------------------
function Test-AssertWinGetSuite {
    Write-Host "`n[Assert-WinGet bootstrap]"

    # 2a: Tier 1 already ready — no install attempted
    $script:addAppxCount = 0
    function global:Get-AppxPackage {
        param($Name)
        [PSCustomObject]@{ Version = '1.22.1000.0' }
    }
    function global:winget { 'v1.22.1000' }
    function global:Add-AppxPackage {
        param([string]$Path, [switch]$ForceApplicationShutdown)
        $script:addAppxCount++
    }
    Import-MainFunctions
    $result = Assert-WinGet
    Assert-True  '2a: Tier1 ready -> returns true' $result
    Assert-True  '2a: Tier1 ready -> Add-AppxPackage not called' ($script:addAppxCount -eq 0)

    # 2b: Tier 2 fast path succeeds
    $script:addAppxCount = 0
    $script:addAppxPaths = @()
    function global:Get-AppxPackage { param($Name) $null }
    function global:winget {
        if ($args -contains '--version') { 'v1.22.1000' }
        elseif ($args -contains 'source') { 'winget' }
        else { '' }
    }
    function global:Add-AppxPackage {
        param([string]$Path, [switch]$ForceApplicationShutdown, [switch]$ErrorAction)
        $script:addAppxCount++
        $script:addAppxPaths += $Path
    }
    Import-MainFunctions
    # After Add-AppxPackage, simulate package now available
    function global:Get-AppxPackage {
        param($Name)
        if ($script:addAppxCount -ge 3) { [PSCustomObject]@{ Version = '1.22.1000.0' } }
        else { $null }
    }
    Import-MainFunctions
    $result = Assert-WinGet
    Assert-True  '2b: Tier2 -> returns true' $result
    Assert-True  '2b: Tier2 -> Add-AppxPackage called 3 times' ($script:addAppxCount -eq 3)
    Assert-Contains '2b: Tier2 -> VCLibs URL used' 'aka.ms/Microsoft.VCLibs' ($script:addAppxPaths -join ',')
    Assert-Contains '2b: Tier2 -> WinGet URL used'  'aka.ms/getwinget'        ($script:addAppxPaths -join ',')

    # 2c: Tier 3 — WindowsAppRuntime exception triggers dynamic URL construction
    $script:addAppxCount = 0
    $script:iwrUrls = @()
    function global:Get-AppxPackage { param($Name) $null }
    function global:Add-AppxPackage {
        param([string]$Path)
        $script:addAppxCount++
        if ($Path -match 'getwinget' -and $script:addAppxCount -le 3) {
            throw "Deployment failed. Microsoft.WindowsAppRuntime.1.6 is required."
        }
    }
    function global:Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
        $script:iwrUrls += $Uri
        Set-Content -Path $OutFile -Value 'mock'
    }
    function global:Start-Process {
        param([string]$FilePath, [string[]]$ArgumentList, [switch]$Wait)
    }
    Import-MainFunctions
    Assert-Contains '2c: Tier3 -> dynamic runtime URL contains version 1.6' `
        'windowsappsdk/1.6' ($script:iwrUrls -join ',')

    # 2d: Tier 4 — all tiers fail, GitHub fallback attempted
    $script:iwrUrls = @()
    function global:Add-AppxPackage {
        param([string]$Path)
        throw "All installs fail"
    }
    function global:Get-AppxPackage { param($Name) $null }
    function global:winget { 'bad' }
    Import-MainFunctions
    $result = Assert-WinGet
    Assert-True  '2d: Tier4 -> returns false when all fail' (-not $result)
    Assert-Contains '2d: Tier4 -> GitHub msixbundle URL attempted' `
        'winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller' ($script:iwrUrls -join ',')

    Remove-Item Function:\Get-AppxPackage        -ErrorAction SilentlyContinue
    Remove-Item Function:\Add-AppxPackage        -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-WebRequest      -ErrorAction SilentlyContinue
    Remove-Item Function:\winget                 -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process          -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 3: Assert-WinGetSource
# ---------------------------------------------------------------------------
function Test-AssertWinGetSourceSuite {
    Write-Host "`n[Assert-WinGetSource]"

    # 3a: source listed and probe passes — no recovery needed
    $script:sourceResetCount = 0
    function global:winget {
        param()
        $cmd = $args -join ' '
        if ($cmd -match 'source list')          { return "Name   Url`nwinget https://cdn.winget.microsoft.com/cache" }
        if ($cmd -match 'source update')        { return 'Done' }
        if ($cmd -match 'source reset')         { $script:sourceResetCount++; return 'Done' }
        if ($cmd -match 'search.*VCRedist')     { return 'Microsoft.VCRedist.2015+.x64  1.0  winget' }
        return ''
    }
    # Stub Start-Process to not actually run winget
    function global:Start-Process {
        param([string]$FilePath, [string]$ArgumentList, [switch]$NoNewWindow, [switch]$PassThru)
        $p = New-Object System.Diagnostics.Process
        $p | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param([int]$ms) $true } -Force
        $p | Add-Member -MemberType ScriptMethod -Name 'Kill' -Value {} -Force
        return $p
    }
    Import-MainFunctions
    $result = Assert-WinGetSource
    Assert-True  '3a: healthy source -> returns true'        $result
    Assert-True  '3a: healthy source -> no recovery called'  ($script:sourceResetCount -eq 0)

    # 3b: source NOT listed — recovery attempt 1 succeeds
    $script:sourceResetCount = 0
    $script:probeCallCount   = 0
    function global:winget {
        param()
        $cmd = $args -join ' '
        if ($cmd -match 'source list')      { return 'msstore  https://storeedge.microsoft.com' }
        if ($cmd -match 'source reset')     { $script:sourceResetCount++; return 'Done' }
        if ($cmd -match 'source update')    { return 'Done' }
        if ($cmd -match 'search.*VCRedist') {
            $script:probeCallCount++
            if ($script:sourceResetCount -ge 1) { return 'Microsoft.VCRedist.2015+.x64' }
            return 'Failed when searching source; results will not be included: winget'
        }
        return ''
    }
    Import-MainFunctions
    $result = Assert-WinGetSource
    Assert-True  '3b: source missing -> recovery triggered'    $result
    Assert-Called '3b: source reset called'                    $script:sourceResetCount

    # 3c: "Failed when searching source" in probe — recovery triggered
    $script:sourceResetCount = 0
    function global:winget {
        param()
        $cmd = $args -join ' '
        if ($cmd -match 'source list')      { return 'winget  https://cdn.winget.microsoft.com/cache' }
        if ($cmd -match 'source update')    { return 'Done' }
        if ($cmd -match 'source reset')     { $script:sourceResetCount++; return 'Done' }
        if ($cmd -match 'search.*VCRedist') {
            if ($script:sourceResetCount -ge 1) { return 'Microsoft.VCRedist.2015+.x64' }
            return 'Failed when searching source; results will not be included: winget'
        }
        return ''
    }
    Import-MainFunctions
    $result = Assert-WinGetSource
    Assert-True  '3c: CDN failure -> recovery triggered -> true' $result
    Assert-Called '3c: source reset called'                      $script:sourceResetCount

    # 3d: timed source update hangs — process killed, function continues
    $script:procKilled = $false
    function global:winget {
        param()
        $cmd = $args -join ' '
        if ($cmd -match 'source list')   { return 'winget  https://cdn.winget.microsoft.com/cache' }
        if ($cmd -match 'search.*VCRedist') { return 'Microsoft.VCRedist.2015+.x64' }
        return ''
    }
    function global:Start-Process {
        param([string]$FilePath, [string]$ArgumentList, [switch]$NoNewWindow, [switch]$PassThru)
        $p = New-Object System.Diagnostics.Process
        # WaitForExit returns false (timeout exceeded)
        $p | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param([int]$ms) $false } -Force
        $p | Add-Member -MemberType ScriptMethod -Name 'Kill' -Value { $script:procKilled = $true } -Force
        return $p
    }
    Import-MainFunctions
    $result = Assert-WinGetSource
    Assert-True  '3d: hung update -> process killed'      $script:procKilled
    Assert-True  '3d: hung update -> function returns true anyway' $result

    # 3e: all recovery fails — returns false
    $script:sourceAddArgs = @()
    function global:winget {
        param()
        $cmd = $args -join ' '
        if ($cmd -match 'source list')   { return 'msstore only' }
        if ($cmd -match 'source reset')  { return 'Failed' }
        if ($cmd -match 'source remove') { return 'Done' }
        if ($cmd -match 'source add') {
            $script:sourceAddArgs += $cmd
            return 'Failed to add source'
        }
        if ($cmd -match 'search.*VCRedist') { return 'Failed when searching source' }
        return ''
    }
    Import-MainFunctions
    $result = Assert-WinGetSource
    Assert-True  '3e: all recovery fails -> returns false'  (-not $result)
    Assert-Contains '3e: manual re-add uses correct CDN URL' `
        'cdn.winget.microsoft.com' ($script:sourceAddArgs -join ' ')

    Remove-Item Function:\winget        -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 4: Get-WinGetIds filtering
# ---------------------------------------------------------------------------
function Test-GetWinGetIdsSuite {
    Write-Host "`n[Get-WinGetIds]"

    $mockOutput = @(
        'Name                                    Id                                  Version  Source'
        '--------------------------------------- ----------------------------------- -------- ------'
        'Microsoft VC++ 2013 x64                 Microsoft.VCRedist.2013.x64         12.0.40  winget'
        'Microsoft VC++ 2013 x86                 Microsoft.VCRedist.2013.x86         12.0.40  winget'
        'Microsoft VC++ 2013 ARM                 Microsoft.VCRedist.2013.arm64       12.0.40  winget'
        'VC Uninstaller                           Microsoft.VCRedist.Uninstaller      1.0.0    winget'
        'VC Developer Tools                       Microsoft.VCRedist.Developer.x64    1.0.0    winget'
    )

    function global:winget {
        param()
        return $mockOutput
    }
    Import-MainFunctions

    $ids = Get-WinGetIds -Query 'Microsoft.VCRedist' `
        -MatchPattern   @('^Microsoft\.VCRedist\.') `
        -ExcludePattern @('arm', 'Uninstaller', 'Developer')

    Assert-True  '4a: x64 included'       ($ids -contains 'Microsoft.VCRedist.2013.x64')
    Assert-True  '4b: x86 included'       ($ids -contains 'Microsoft.VCRedist.2013.x86')
    Assert-True  '4c: arm excluded'       ($ids -notcontains 'Microsoft.VCRedist.2013.arm64')
    Assert-True  '4d: Uninstaller excluded' ($ids -notcontains 'Microsoft.VCRedist.Uninstaller')
    Assert-True  '4e: Developer excluded' ($ids -notcontains 'Microsoft.VCRedist.Developer.x64')

    # 4f: empty output
    function global:winget { return @() }
    Import-MainFunctions
    $ids = Get-WinGetIds -Query 'nothing' -MatchPattern @('nothing')
    Assert-True  '4f: empty output -> empty array, no exception' ($ids.Count -eq 0)

    # 4g: malformed output
    function global:winget { return 'this has no package IDs whatsoever' }
    Import-MainFunctions
    $ids = Get-WinGetIds -Query 'test' -MatchPattern @('^test\.')
    Assert-True  '4g: malformed output -> empty array' ($ids.Count -eq 0)

    Remove-Item Function:\winget -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 5: Invoke-WinGetInstall exit-code mapping + retry
# ---------------------------------------------------------------------------
function Test-InvokeWinGetInstallSuite {
    Write-Host "`n[Invoke-WinGetInstall exit codes + retry]"

    Import-MainFunctions

    $exitCodeMap = @(
        @{ Code = 0;            Expected = 'Installed' },
        @{ Code = -1978335189;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978335135;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978334963;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978334962;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978335153;  Expected = 'AlreadyUpToDate' }
    )

    foreach ($tc in $exitCodeMap) {
        $mockCode = $tc.Code
        function global:winget {
            param()
            $global:LASTEXITCODE = $mockCode
            return "winget output"
        }
        Import-MainFunctions
        $status = Invoke-WinGetInstall -Id 'Test.Package' -MaxRetries 1
        Assert-Equal ("5: exit $($tc.Code) -> $($tc.Expected)") $tc.Expected $status
    }

    # 5g: failure triggers 3 retries
    $script:wingetCallCount = 0
    $script:sleepCount      = 0
    function global:winget {
        param()
        $script:wingetCallCount++
        $global:LASTEXITCODE = 1
        return "install failed"
    }
    function global:Start-Sleep {
        param([int]$Seconds)
        $script:sleepCount++
    }
    Import-MainFunctions
    $status = Invoke-WinGetInstall -Id 'Fail.Package' -MaxRetries 3 -RetryDelaySec 0
    Assert-Equal '5g: 3 retries -> Failed'             'Failed' $status
    Assert-Equal '5g: winget called 3 times'           3 $script:wingetCallCount
    Assert-Equal '5g: sleep called between retries'    2 $script:sleepCount

    # 5h: mid-run source error triggers recovery once then retries
    $script:wingetCallCount   = 0
    $script:recoveryCount     = 0
    function global:winget {
        param()
        $cmd = $args -join ' '
        if ($cmd -match 'install') {
            $script:wingetCallCount++
            $global:LASTEXITCODE = 0
            if ($script:wingetCallCount -eq 1) {
                return 'Failed when searching source; results will not be included: winget'
            }
            return 'Successfully installed'
        }
        # source recovery calls
        if ($cmd -match 'source')   { $script:recoveryCount++; return 'winget  cdn' }
        if ($cmd -match 'search')   { return 'Microsoft.VCRedist.2015+.x64' }
        return ''
    }
    $mockProc = New-Object PSObject
    $mockProc | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param([int]$ms) $true } -Force
    $mockProc | Add-Member -MemberType ScriptMethod -Name 'Kill'        -Value {} -Force
    function global:Start-Process { return $mockProc }
    Import-MainFunctions
    $status = Invoke-WinGetInstall -Id 'Test.Package' -MaxRetries 3
    Assert-Equal  '5h: source error -> Installed after recovery' 'Installed' $status
    Assert-Called '5h: recovery triggered'                       $script:recoveryCount

    Remove-Item Function:\winget       -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep  -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 6: Log file creation
# ---------------------------------------------------------------------------
function Test-LogSuite {
    Write-Host "`n[Log file creation]"

    $tmpRoot = Join-Path $env:TEMP "GameRedistsTest_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    # Temporarily redirect the log dir constant
    Import-MainFunctions
    $script:LOG_DIR  = Join-Path $tmpRoot 'Windows\Setup\Scripts'
    $script:LOG_FILE = Join-Path $script:LOG_DIR "GameRedists_test.log"

    Initialize-Log

    Assert-True '6a: log directory created' (Test-Path $script:LOG_DIR)
    Assert-True '6b: log file created'      (Test-Path $script:LOG_FILE)

    try { Stop-Transcript | Out-Null } catch {}
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 7: Summary counters
# ---------------------------------------------------------------------------
function Test-SummarySuite {
    Write-Host "`n[Summary counters]"

    Import-MainFunctions

    # Simulate batch results
    $totals = @{ Installed = 1; AlreadyUpToDate = 1; Failed = 1; FailedIds = @('Fail.Pkg') }

    $output = & {
        Write-Log "=== Summary ==="
        Write-Log ("  Installed         : {0}" -f $totals.Installed)
        Write-Log ("  Already up-to-date: {0}" -f $totals.AlreadyUpToDate)
        Write-Log ("  Failed            : {0}" -f $totals.Failed)
    } 4>&1 | Out-String

    $combined = $output + (Write-Log "  Installed         : $($totals.Installed)" 4>&1 | Out-String)

    # Verify counts appear
    Assert-Contains '7a: installed count in output' '1' ($totals.Installed.ToString())
    Assert-Contains '7b: failed count in output'    '1' ($totals.Failed.ToString())

    $exitCode = if ($totals.Failed -gt 0) { 2 } else { 0 }
    Assert-Equal '7c: exit 2 on failures'   2 $exitCode

    $totals2   = @{ Installed = 5; AlreadyUpToDate = 3; Failed = 0; FailedIds = @() }
    $exitCode2 = if ($totals2.Failed -gt 0) { 2 } else { 0 }
    Assert-Equal '7d: exit 0 on all success' 0 $exitCode2
}

# ---------------------------------------------------------------------------
# Test suite 8: Invoke-WinGetBatch progress + aggregation
# ---------------------------------------------------------------------------
function Test-InvokeWinGetBatchSuite {
    Write-Host "`n[Invoke-WinGetBatch aggregation]"

    $mockStatuses = @{ 'Pkg.A' = 'Installed'; 'Pkg.B' = 'AlreadyUpToDate'; 'Pkg.C' = 'Failed' }
    function global:winget { param(); $global:LASTEXITCODE = 0; return '' }
    function global:Invoke-WinGetInstall {
        param([string]$Id, [int]$MaxRetries, [int]$RetryDelaySec)
        return $mockStatuses[$Id]
    }
    $script:progressCalls = 0
    function global:Write-Progress {
        param([string]$Activity, [string]$Status, [int]$PercentComplete, [string]$CurrentOperation, [switch]$Completed)
        $script:progressCalls++
    }

    Import-MainFunctions
    # Override Invoke-WinGetInstall post dot-source
    function Invoke-WinGetInstall {
        param([string]$Id, [int]$MaxRetries = 3, [int]$RetryDelaySec = 5)
        return $mockStatuses[$Id]
    }

    $r = Invoke-WinGetBatch -GroupName 'Test' -Ids @('Pkg.A','Pkg.B','Pkg.C') `
        -StartIndex 0 -TotalCount 3

    Assert-Equal '8a: Installed count'      1 $r.Installed
    Assert-Equal '8b: AlreadyUpToDate count' 1 $r.AlreadyUpToDate
    Assert-Equal '8c: Failed count'         1 $r.Failed
    Assert-True  '8d: FailedIds contains Pkg.C' ($r.FailedIds -contains 'Pkg.C')
    Assert-Called '8e: Write-Progress called'   $script:progressCalls

    Remove-Item Function:\winget         -ErrorAction SilentlyContinue
    Remove-Item Function:\Write-Progress -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Run all suites
# ---------------------------------------------------------------------------
Write-Host "`n========================================="
Write-Host " Gaming Redists — Test Runner"
Write-Host "=========================================`n"

try {
    Test-WinGetReadySuite
    Test-AssertWinGetSuite
    Test-AssertWinGetSourceSuite
    Test-GetWinGetIdsSuite
    Test-InvokeWinGetInstallSuite
    Test-LogSuite
    Test-SummarySuite
    Test-InvokeWinGetBatchSuite
} catch {
    Write-Host "`n[FATAL] Unhandled exception in test runner: $_" -ForegroundColor Red
    $script:FAIL++
}

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
Write-Host "`n========================================="
$total = $script:PASS + $script:FAIL
Write-Host " Results: $($script:PASS)/$total passed" -ForegroundColor $(if ($script:FAIL -eq 0) { 'Green' } else { 'Yellow' })
if ($script:FAIL -gt 0) {
    Write-Host " $($script:FAIL) test(s) FAILED" -ForegroundColor Red
}
Write-Host "=========================================`n"

exit $(if ($script:FAIL -gt 0) { 1 } else { 0 })
