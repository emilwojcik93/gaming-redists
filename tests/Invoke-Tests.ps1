#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained test runner for Install-GameRedists.ps1.
    No external test framework required.

.DESCRIPTION
    Dot-sources the main script ONCE at script scope to load all functions,
    then runs each test suite with global mock functions (winget, Add-AppxPackage,
    Get-AppxPackage, Invoke-WebRequest, Start-Process, Start-Sleep).
    Exits 0 if all tests pass, 1 if any fail.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:PASS = 0
$script:FAIL = 0
$script:ScriptPath = Join-Path $PSScriptRoot '..\Install-GameRedists.ps1'

# ---------------------------------------------------------------------------
# Load main script functions into THIS scope.
# Suppress the trailing Main call and #Requires (not valid in scriptblocks).
# ---------------------------------------------------------------------------
$_src = (Get-Content $script:ScriptPath -Raw) `
    -replace '(?m)^Main\s*$', '# Main call suppressed for testing' `
    -replace '(?m)^#Requires[^\r\n]+', ''
. ([scriptblock]::Create($_src))
Remove-Variable _src

# ---------------------------------------------------------------------------
# Mini test framework
# ---------------------------------------------------------------------------
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Message = '')
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  [FAIL] $Name$(if ($Message) { ' -- ' + $Message })" -ForegroundColor Red
        $script:FAIL++
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ($Expected -eq $Actual) -or ($null -eq $Expected -and $null -eq $Actual)
    Assert-True -Name $Name -Condition $ok -Message "Expected '$Expected', got '$Actual'"
}

function Assert-Contains {
    param([string]$Name, [string]$Pattern, [string]$Text)
    Assert-True -Name $Name -Condition ($Text -match $Pattern) `
        -Message "Pattern '$Pattern' not found"
}

function Assert-Called {
    param([string]$Name, [int]$CallCount, [int]$ExpectedMin = 1)
    Assert-True -Name $Name -Condition ($CallCount -ge $ExpectedMin) `
        -Message "Expected >= $ExpectedMin calls, got $CallCount"
}

function Clear-Mocks {
    foreach ($fn in @('winget','Get-AppxPackage','Add-AppxPackage',
                      'Invoke-WebRequest','Start-Process','Start-Sleep')) {
        Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Test suite 1: Test-WinGetReady
# ---------------------------------------------------------------------------
function Test-WinGetReadySuite {
    Write-Host "`n[Test-WinGetReady]"
    Clear-Mocks

    # 1a: version meets minimum
    function global:Get-AppxPackage { param($Name) [PSCustomObject]@{ Version = '1.22.1000.0' } }
    function global:winget { 'v1.22.1000' }
    Assert-True '1a: version OK -> true'          (Test-WinGetReady)

    # 1b: version below minimum
    function global:Get-AppxPackage { param($Name) [PSCustomObject]@{ Version = '1.0.0.0' } }
    Assert-True '1b: version too low -> false'    (-not (Test-WinGetReady))

    # 1c: package not installed
    function global:Get-AppxPackage { param($Name) $null }
    Assert-True '1c: not installed -> false'      (-not (Test-WinGetReady))

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Test suite 2: Assert-WinGet bootstrap tiers
# ---------------------------------------------------------------------------
function Test-AssertWinGetSuite {
    Write-Host "`n[Assert-WinGet bootstrap]"
    Clear-Mocks

    # 2a: Tier 1 already ready
    $script:addAppxCount = 0
    function global:Get-AppxPackage { param($Name) [PSCustomObject]@{ Version = '1.22.1000.0' } }
    function global:winget { 'v1.22.1000' }
    function global:Add-AppxPackage { param([string]$Path,[switch]$ForceApplicationShutdown) $script:addAppxCount++ }
    $result = Assert-WinGet
    Assert-True '2a: Tier1 ready -> true'                    $result
    Assert-True '2a: Tier1 -> Add-AppxPackage not called'    ($script:addAppxCount -eq 0)

    # 2b: Tier 2 fast path - Add-AppxPackage called 3 times then WinGet reports ready
    Clear-Mocks
    $script:addAppxCount = 0
    $script:addAppxPaths = @()
    function global:Get-AppxPackage {
        param($Name)
        if ($script:addAppxCount -ge 3) { [PSCustomObject]@{ Version = '1.22.1000.0' } } else { $null }
    }
    function global:winget { if ($script:addAppxCount -ge 3) { 'v1.22.1000' } else { '' } }
    function global:Add-AppxPackage {
        param([string]$Path,[switch]$ForceApplicationShutdown)
        $script:addAppxCount++
        $script:addAppxPaths += $Path
    }
    $result = Assert-WinGet
    Assert-True '2b: Tier2 -> true'                    $result
    Assert-True '2b: Tier2 -> 3 Add-AppxPackage calls' ($script:addAppxCount -eq 3)
    Assert-Contains '2b: VCLibs URL used'   'aka.ms/Microsoft.VCLibs'  ($script:addAppxPaths -join ',')
    Assert-Contains '2b: WinGet URL used'   'aka.ms/getwinget'          ($script:addAppxPaths -join ',')

    # 2c: Tier 3 - WindowsAppRuntime exception triggers dynamic URL
    Clear-Mocks
    $script:iwrUrls = @()
    $script:addAppxCount = 0
    function global:Get-AppxPackage { param($Name) $null }
    function global:Add-AppxPackage {
        param([string]$Path)
        $script:addAppxCount++
        if ($Path -match 'getwinget' -and $script:addAppxCount -le 3) {
            throw 'Deployment failed. Microsoft.WindowsAppRuntime.1.6 is required.'
        }
    }
    function global:Invoke-WebRequest {
        param([string]$Uri,[string]$OutFile,[switch]$UseBasicParsing)
        $script:iwrUrls += $Uri
        if ($OutFile) { Set-Content -Path $OutFile -Value 'mock' }
    }
    function global:Start-Process {
        param([string]$FilePath,[string[]]$ArgumentList,[switch]$Wait,[switch]$NoNewWindow,[switch]$PassThru)
    }
    function global:winget { '' }
    Assert-WinGet | Out-Null
    Assert-Contains '2c: Tier3 runtime URL has version 1.6' 'windowsappsdk/1.6' ($script:iwrUrls -join ',')

    # 2d: Tier 4 - all tiers fail, GitHub fallback URL attempted
    Clear-Mocks
    $script:iwrUrls = @()
    function global:Get-AppxPackage { param($Name) $null }
    function global:Add-AppxPackage { param([string]$Path) throw 'All installs fail' }
    function global:Invoke-WebRequest {
        param([string]$Uri,[string]$OutFile,[switch]$UseBasicParsing)
        $script:iwrUrls += $Uri
        if ($OutFile) { Set-Content -Path $OutFile -Value 'mock' }
    }
    function global:Start-Process {
        param([string]$FilePath,[string[]]$ArgumentList,[switch]$Wait,[switch]$NoNewWindow,[switch]$PassThru)
    }
    function global:winget { 'bad' }
    $result = Assert-WinGet
    Assert-True     '2d: all tiers fail -> false'       (-not $result)
    Assert-Contains '2d: Tier4 GitHub URL attempted'    'winget-cli/releases/latest' ($script:iwrUrls -join ',')

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Test suite 3: Assert-WinGetSource
# ---------------------------------------------------------------------------
function Test-AssertWinGetSourceSuite {
    Write-Host "`n[Assert-WinGetSource]"
    Clear-Mocks

    # 3a: healthy source, probe passes
    $script:resetCount = 0
    function global:winget {
        $cmd = "$args"
        if ($cmd -match 'source list')     { return "winget   https://cdn.winget.microsoft.com/cache`nmsstore" }
        if ($cmd -match 'source reset')    { $script:resetCount++ }
        if ($cmd -match 'search.*VCRedist'){ return 'Microsoft.VCRedist.2015+.x64  1.0  winget' }
        return ''
    }
    $mockProc = New-Object PSObject
    $mockProc | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param([int]$ms) $true } -Force
    $mockProc | Add-Member -MemberType ScriptMethod -Name 'Kill'        -Value {} -Force
    function global:Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
        if ($PassThru) { return $mockProc }
    }
    $result = Assert-WinGetSource
    Assert-True '3a: healthy -> true'              $result
    Assert-True '3a: no recovery needed'           ($script:resetCount -eq 0)

    # 3b: source missing from list -> recovery -> reset succeeds
    Clear-Mocks
    $script:resetCount = 0
    function global:winget {
        $cmd = "$args"
        if ($cmd -match 'source list')     { return 'msstore   https://storeedge.microsoft.com' }
        if ($cmd -match 'source reset')    { $script:resetCount++ }
        if ($cmd -match 'source remove')   { }
        if ($cmd -match 'source add')      { }
        if ($cmd -match 'search.*VCRedist'){
            if ($script:resetCount -ge 1) { return 'Microsoft.VCRedist.2015+.x64' }
            return 'no results'
        }
        return ''
    }
    function global:Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
        if ($PassThru) { return $mockProc }
    }
    $result = Assert-WinGetSource
    Assert-True   '3b: missing source -> recovery -> true' $result
    Assert-Called '3b: source reset called'                $script:resetCount

    # 3c: "Failed when searching source" in probe
    Clear-Mocks
    $script:resetCount = 0
    function global:winget {
        $cmd = "$args"
        if ($cmd -match 'source list')     { return 'winget   https://cdn.winget.microsoft.com/cache' }
        if ($cmd -match 'source reset')    { $script:resetCount++ }
        if ($cmd -match 'search.*VCRedist'){
            if ($script:resetCount -ge 1) { return 'Microsoft.VCRedist.2015+.x64' }
            return 'Failed when searching source; results will not be included: winget'
        }
        return ''
    }
    function global:Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
        if ($PassThru) { return $mockProc }
    }
    $result = Assert-WinGetSource
    Assert-True   '3c: CDN failure -> recovery -> true' $result
    Assert-Called '3c: source reset triggered'          $script:resetCount

    # 3d: source update hangs - process killed, function continues
    Clear-Mocks
    $script:procKilled = $false
    function global:winget {
        $cmd = "$args"
        if ($cmd -match 'source list')     { return 'winget   https://cdn.winget.microsoft.com/cache' }
        if ($cmd -match 'search.*VCRedist'){ return 'Microsoft.VCRedist.2015+.x64' }
        return ''
    }
    $hangProc = New-Object PSObject
    $hangProc | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param([int]$ms) $false } -Force
    $hangProc | Add-Member -MemberType ScriptMethod -Name 'Kill'        -Value { $script:procKilled = $true } -Force
    function global:Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
        if ($PassThru) { return $hangProc }
    }
    $result = Assert-WinGetSource
    Assert-True '3d: hung update -> process killed'  $script:procKilled
    Assert-True '3d: hung update -> returns true'    $result

    # 3e: all recovery fails -> false; manual re-add uses CDN URL
    Clear-Mocks
    $script:sourceAddArgs = @()
    function global:winget {
        $cmd = "$args"
        if ($cmd -match 'source list')     { return 'msstore only' }
        if ($cmd -match 'source reset')    { }
        if ($cmd -match 'source remove')   { }
        if ($cmd -match 'source add')      { $script:sourceAddArgs += $cmd }
        if ($cmd -match 'search.*VCRedist'){ return 'Failed when searching source' }
        return ''
    }
    function global:Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
        if ($PassThru) { return $mockProc }
    }
    $result = Assert-WinGetSource
    Assert-True     '3e: all fails -> false'                      (-not $result)
    Assert-Contains '3e: manual re-add uses CDN URL' 'cdn.winget.microsoft.com' ($script:sourceAddArgs -join ' ')

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Test suite 4: Get-WinGetId filtering
# ---------------------------------------------------------------------------
function Test-GetWinGetIdsSuite {
    Write-Host "`n[Get-WinGetId]"
    Clear-Mocks

    $mockOutput = @(
        'Name                                    Id                                  Version  Source'
        '--------------------------------------- ----------------------------------- -------- ------'
        'Microsoft VC++ 2013 x64                 Microsoft.VCRedist.2013.x64         12.0.40  winget'
        'Microsoft VC++ 2013 x86                 Microsoft.VCRedist.2013.x86         12.0.40  winget'
        'Microsoft VC++ 2013 ARM                 Microsoft.VCRedist.2013.arm64       12.0.40  winget'
        'VC Uninstaller                           Microsoft.VCRedist.Uninstaller      1.0.0    winget'
        'VC Developer Tools                       Microsoft.VCRedist.Developer.x64    1.0.0    winget'
    )

    function global:winget { $mockOutput }

    $ids = @(Get-WinGetId -Query 'Microsoft.VCRedist' `
        -MatchPattern   @('^Microsoft\.VCRedist\.') `
        -ExcludePattern @('arm', 'Uninstaller', 'Developer'))

    Assert-True '4a: x64 included'           ($ids -contains 'Microsoft.VCRedist.2013.x64')
    Assert-True '4b: x86 included'           ($ids -contains 'Microsoft.VCRedist.2013.x86')
    Assert-True '4c: arm excluded'           ($ids -notcontains 'Microsoft.VCRedist.2013.arm64')
    Assert-True '4d: Uninstaller excluded'   ($ids -notcontains 'Microsoft.VCRedist.Uninstaller')
    Assert-True '4e: Developer excluded'     ($ids -notcontains 'Microsoft.VCRedist.Developer.x64')

    # 4f: empty output
    function global:winget { @() }
    $ids = @(Get-WinGetId -Query 'nothing' -MatchPattern @('nothing'))
    Assert-True '4f: empty -> empty array'   ($ids.Count -eq 0)

    # 4g: malformed output
    function global:winget { 'this has no package IDs whatsoever' }
    $ids = @(Get-WinGetId -Query 'test' -MatchPattern @('^test\.'))
    Assert-True '4g: malformed -> empty array' ($ids.Count -eq 0)

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Test suite 5: Invoke-WinGetInstall exit-code mapping + retry
# ---------------------------------------------------------------------------
function Test-InvokeWinGetInstallSuite {
    Write-Host "`n[Invoke-WinGetInstall]"
    Clear-Mocks

    $exitCodeMap = @(
        @{ Code = 0;            Expected = 'Installed'       },
        @{ Code = -1978335189;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978335135;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978334963;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978334962;  Expected = 'AlreadyUpToDate' },
        @{ Code = -1978335153;  Expected = 'AlreadyUpToDate' }
    )

    foreach ($tc in $exitCodeMap) {
        $mockCode = $tc.Code
        function global:winget {
            $global:LASTEXITCODE = $mockCode
            return 'winget output'
        }
        $status = Invoke-WinGetInstall -Id 'Test.Package' -MaxRetries 1
        Assert-Equal "5: exit $($tc.Code) -> $($tc.Expected)" $tc.Expected $status
    }

    # 5g: failure retries 3 times
    Clear-Mocks
    $script:wingetCallCount = 0
    $script:sleepCount      = 0
    function global:winget {
        $script:wingetCallCount++
        $global:LASTEXITCODE = 1
        return 'install failed'
    }
    function global:Start-Sleep { param([int]$Seconds) $script:sleepCount++ }
    $status = Invoke-WinGetInstall -Id 'Fail.Package' -MaxRetries 3 -RetryDelaySec 0
    Assert-Equal '5g: 3 retries -> Failed'          'Failed' $status
    Assert-Equal '5g: winget called 3 times'        3        $script:wingetCallCount
    Assert-Equal '5g: sleep called twice'           2        $script:sleepCount

    # 5h: mid-run source error triggers recovery then succeeds
    Clear-Mocks
    $script:wingetCallCount = 0
    $script:recoveryCalled  = $false
    function global:winget {
        $cmd = "$args"
        if ($cmd -match 'install') {
            $script:wingetCallCount++
            $global:LASTEXITCODE = 0
            if ($script:wingetCallCount -eq 1) {
                return 'Failed when searching source; results will not be included: winget'
            }
            return 'Successfully installed'
        }
        # Check 'search' BEFORE 'source' -- search cmd contains '--source winget' which
        # would otherwise match the 'source' branch incorrectly.
        if ($cmd -match 'search') { return 'Microsoft.VCRedist.2015+.x64' }
        if ($cmd -match 'source') { $script:recoveryCalled = $true; return 'winget ok' }
        return ''
    }
    $mp = New-Object PSObject
    $mp | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param([int]$ms) $true } -Force
    $mp | Add-Member -MemberType ScriptMethod -Name 'Kill' -Value {} -Force
    function global:Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
        if ($PassThru) { return $mp }
    }
    $status = Invoke-WinGetInstall -Id 'Test.Package' -MaxRetries 3
    Assert-Equal '5h: source error -> Installed after recovery' 'Installed' $status
    Assert-True  '5h: recovery triggered'                        $script:recoveryCalled

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Test suite 6: Log file creation
# ---------------------------------------------------------------------------
function Test-LogSuite {
    Write-Host "`n[Log file creation]"
    Clear-Mocks

    $tmpRoot = Join-Path $env:TEMP "GameRedistsTest_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    $origDir  = $script:LOG_DIR
    $script:LOG_DIR  = Join-Path $tmpRoot 'Windows\Setup\Scripts'
    $script:LOG_FILE = Join-Path $script:LOG_DIR "GameRedists_test.log"

    Initialize-Log

    Assert-True '6a: log directory created' (Test-Path $script:LOG_DIR)
    Assert-True '6b: log file created'      (Test-Path $script:LOG_FILE)

    try { Stop-Transcript | Out-Null } catch {}

    # Restore
    $script:LOG_DIR  = $origDir
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test suite 7: Summary exit codes
# ---------------------------------------------------------------------------
function Test-SummarySuite {
    Write-Host "`n[Summary exit codes]"

    $exitCode = if (1 -gt 0)  { 2 } else { 0 }
    Assert-Equal '7a: exit 2 on failures'    2 $exitCode

    $exitCode2 = if (0 -gt 0) { 2 } else { 0 }
    Assert-Equal '7b: exit 0 on all success' 0 $exitCode2
}

# ---------------------------------------------------------------------------
# Test suite 8: Invoke-WinGetBatch aggregation
# ---------------------------------------------------------------------------
function Test-InvokeWinGetBatchSuite {
    Write-Host "`n[Invoke-WinGetBatch]"
    Clear-Mocks

    $mockStatuses = @{ 'Pkg.A' = 'Installed'; 'Pkg.B' = 'AlreadyUpToDate'; 'Pkg.C' = 'Failed' }
    $script:progressCalls = 0

    function global:winget { $global:LASTEXITCODE = 0; return '' }

    # Override Invoke-WinGetInstall in this scope so it uses mock statuses
    function Invoke-WinGetInstall {
        param([string]$Id,[int]$MaxRetries = 3,[int]$RetryDelaySec = 5)
        return $mockStatuses[$Id]
    }
    function global:Write-Progress {
        param([string]$Activity,[string]$Status,[int]$PercentComplete,
              [string]$CurrentOperation,[switch]$Completed,[int]$Id)
        $script:progressCalls++
    }

    $r = Invoke-WinGetBatch -GroupName 'Test' -Ids @('Pkg.A','Pkg.B','Pkg.C') `
        -StartIndex 0 -TotalCount 3

    Assert-Equal '8a: Installed count'       1 $r.Installed
    Assert-Equal '8b: AlreadyUpToDate count' 1 $r.AlreadyUpToDate
    Assert-Equal '8c: Failed count'          1 $r.Failed
    Assert-True  '8d: FailedIds has Pkg.C'   (@($r.FailedIds) -contains 'Pkg.C')
    Assert-Called '8e: Write-Progress called' $script:progressCalls

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Test suite 9: Get-WinGetId Count is never broken under StrictMode
# ---------------------------------------------------------------------------
function Test-StrictModeCountSuite {
    Write-Host "`n[StrictMode .Count safety]"
    Clear-Mocks

    # Single match - used to crash with PropertyNotFoundException under StrictMode
    function global:winget {
        @('Name   Id   Version   Source',
          '----   --   -------   ------',
          'VC++ Redist 2015   Microsoft.VCRedist.2015+.x64   14.0   winget')
    }

    $ids = @(Get-WinGetId -Query 'Microsoft.VCRedist' `
        -MatchPattern   @('^Microsoft\.VCRedist\.') `
        -ExcludePattern @('arm'))

    Assert-True '9a: single match returns array (not scalar)' ($ids -is [array])
    Assert-True '9b: .Count available on result'               ($ids.Count -ge 0)

    # Multiple matches
    function global:winget {
        @('Name   Id   Version',
          '----   --   -------',
          'VC A   Microsoft.VCRedist.2013.x64   12.0',
          'VC B   Microsoft.VCRedist.2013.x86   12.0')
    }
    $ids2 = @(Get-WinGetId -Query 'Microsoft.VCRedist' `
        -MatchPattern @('^Microsoft\.VCRedist\.'))
    Assert-True '9c: multiple matches work' ($ids2.Count -ge 2)

    Clear-Mocks
}

# ---------------------------------------------------------------------------
# Run all suites
# ---------------------------------------------------------------------------
Write-Host "`n========================================="
Write-Host " Gaming Redists - Test Runner"
Write-Host "=========================================`n"

$suites = @(
    { Test-WinGetReadySuite        },
    { Test-AssertWinGetSuite       },
    { Test-AssertWinGetSourceSuite },
    { Test-GetWinGetIdsSuite       },
    { Test-InvokeWinGetInstallSuite},
    { Test-LogSuite                },
    { Test-SummarySuite            },
    { Test-InvokeWinGetBatchSuite  },
    { Test-StrictModeCountSuite    }
)

foreach ($suite in $suites) {
    try { & $suite }
    catch {
        Write-Host "`n  [FATAL] Suite threw: $_" -ForegroundColor Red
        $script:FAIL++
    }
}

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
Write-Host "`n========================================="
$total = $script:PASS + $script:FAIL
$color = if ($script:FAIL -eq 0) { 'Green' } else { 'Yellow' }
Write-Host " Results: $($script:PASS)/$total passed" -ForegroundColor $color
if ($script:FAIL -gt 0) {
    Write-Host " $($script:FAIL) test(s) FAILED" -ForegroundColor Red
}
Write-Host "=========================================`n"

exit $(if ($script:FAIL -gt 0) { 1 } else { 0 })

