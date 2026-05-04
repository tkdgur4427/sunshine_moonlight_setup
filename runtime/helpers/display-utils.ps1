# display-utils.ps1 — 모니터 enable/disable 및 해상도 변경 헬퍼.
# do.ps1 / undo.ps1 가 dot-source 하여 사용한다.
#
# 외부 의존: MultiMonitorTool.exe (sunshine-tools 디렉토리에 위치)

function Get-ToolsRoot {
    # display-utils.ps1 -> helpers/ 의 부모가 ToolsRoot
    return (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
}

function Get-MultiMonitorTool {
    $exe = Join-Path (Get-ToolsRoot) 'MultiMonitorTool.exe'
    if (-not (Test-Path $exe)) {
        throw "MultiMonitorTool.exe 를 찾을 수 없습니다: $exe"
    }
    return $exe
}

function Get-RuntimeLogPath {
    $logDir = Join-Path (Get-ToolsRoot) 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    return (Join-Path $logDir 'automation.log')
}

function Write-RuntimeLog {
    param(
        [Parameter(Mandatory, Position=0)] [AllowEmptyString()] [string]$Message,
        [Parameter(Position=1)]
        [ValidateSet('INFO','WARN','ERROR','DEBUG')] [string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path (Get-RuntimeLogPath) -Value $line -Encoding UTF8 } catch { }
}

function Read-RuntimeConfig {
    $cfgPath = Join-Path (Get-ToolsRoot) 'config.json'
    $defaults = [pscustomobject]@{
        virtual_display_match  = 'Virtual Display'
        disable_other_displays = $false
        default_width          = 1920
        default_height         = 1080
        default_fps            = 60
    }
    if (-not (Test-Path $cfgPath)) { return $defaults }
    try {
        $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        # 기본값과 병합
        foreach ($p in $defaults.PSObject.Properties) {
            if (-not $parsed.PSObject.Properties[$p.Name]) {
                $parsed | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
            }
        }
        return $parsed
    } catch {
        Write-RuntimeLog "config.json 파싱 실패, 기본값 사용: $($_.Exception.Message)" 'WARN'
        return $defaults
    }
}

function Get-MonitorList {
    <#
    .SYNOPSIS
        MultiMonitorTool 의 /scomma 출력을 파싱하여 모니터 목록을 반환.
    #>
    $exe = Get-MultiMonitorTool
    $tmp = Join-Path $env:TEMP "mmt-monitors-$PID.csv"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }

    Start-Process -FilePath $exe -ArgumentList @('/scomma', "`"$tmp`"") -Wait -WindowStyle Hidden | Out-Null

    if (-not (Test-Path $tmp)) {
        Write-RuntimeLog "MMT /scomma 결과 파일이 생성되지 않았습니다: $tmp" 'WARN'
        return @()
    }
    $rows = Import-Csv -Path $tmp -ErrorAction SilentlyContinue
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $rows
}

function Find-VirtualMonitor {
    [CmdletBinding()]
    param([string]$Pattern = 'Virtual Display')
    $list = Get-MonitorList
    $hit = $list | Where-Object {
        ($_.'Monitor Name' -and $_.'Monitor Name' -match $Pattern) -or
        ($_.'Monitor ID'   -and $_.'Monitor ID'   -match 'MttVDD|IddSampleDriver')
    } | Select-Object -First 1
    return $hit
}

function Find-OtherActiveMonitors {
    [CmdletBinding()]
    param([string]$VirtualPattern = 'Virtual Display')
    $list = Get-MonitorList
    return $list | Where-Object {
        $_.Active -eq 'Yes' -and
        -not (
            ($_.'Monitor Name' -and $_.'Monitor Name' -match $VirtualPattern) -or
            ($_.'Monitor ID'   -and $_.'Monitor ID'   -match 'MttVDD|IddSampleDriver')
        )
    }
}

function Invoke-MMT {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$ArgList)
    $exe = Get-MultiMonitorTool
    Write-RuntimeLog "MMT $($ArgList -join ' ')" 'DEBUG'
    Start-Process -FilePath $exe -ArgumentList $ArgList -Wait -WindowStyle Hidden | Out-Null
}

function Enable-Monitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Monitor)
    $key = if ($Monitor.'Monitor ID') { $Monitor.'Monitor ID' } else { $Monitor.Name }
    Invoke-MMT -ArgList @('/enable', "`"$key`"")
}

function Disable-Monitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Monitor)
    $key = if ($Monitor.'Monitor ID') { $Monitor.'Monitor ID' } else { $Monitor.Name }
    Invoke-MMT -ArgList @('/disable', "`"$key`"")
}

function Set-MonitorMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Monitor,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [int]$Frequency = 60,
        [int]$ColorDepth = 32
    )
    $key = if ($Monitor.'Monitor ID') { $Monitor.'Monitor ID' } else { $Monitor.Name }
    $spec = "Name=$key|Width=$Width|Height=$Height|DisplayFrequency=$Frequency|ColorDepth=$ColorDepth"
    Invoke-MMT -ArgList @('/SetMonitors', "`"$spec`"")
}

function Set-PrimaryMonitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Monitor)
    $key = if ($Monitor.'Monitor ID') { $Monitor.'Monitor ID' } else { $Monitor.Name }
    Invoke-MMT -ArgList @('/SetPrimary', "`"$key`"")
}

function Move-CursorToMonitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Monitor)
    # Resolution 컬럼은 "1920 X 1080" 형태
    $res = $Monitor.Resolution
    $w = 1920; $h = 1080
    if ($res -match '(\d+)\s*[xX]\s*(\d+)') {
        $w = [int]$Matches[1]; $h = [int]$Matches[2]
    }
    # Position-X / Position-Y 컬럼 (모니터 좌상단 좌표)
    $px = 0; $py = 0
    if ($Monitor.'Left-Top' -and $Monitor.'Left-Top' -match '(-?\d+)\s*,\s*(-?\d+)') {
        $px = [int]$Matches[1]; $py = [int]$Matches[2]
    }
    $cx = $px + [int]($w / 2)
    $cy = $py + [int]($h / 2)

    Add-Type -Namespace Win32 -Name Cursor -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetCursorPos(int X, int Y);
"@ -ErrorAction SilentlyContinue
    [Win32.Cursor]::SetCursorPos($cx, $cy) | Out-Null
    Write-RuntimeLog "커서 이동: ($cx, $cy)"
}

function Wait-MonitorActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Pattern,
        [int]$TimeoutSec = 8
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = Find-VirtualMonitor -Pattern $Pattern
        if ($m -and $m.Active -eq 'Yes') { return $m }
        Start-Sleep -Milliseconds 400
    }
    return (Find-VirtualMonitor -Pattern $Pattern)
}
