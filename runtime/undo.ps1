# undo.ps1 — Sunshine Prep Command "undo".
# 클라이언트 접속 종료 시 호출되어 디스플레이를 원상 복구한다.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'helpers\display-utils.ps1')

Write-RuntimeLog "============================================================"
Write-RuntimeLog "undo.ps1 시작 (PID=$PID)"

$cfg = Read-RuntimeConfig

try {
    # 1) 만약 do.ps1 가 다른 디스플레이를 껐다면 다시 켠다.
    #    (현재 상태에서 Active=No 인 비-가상 모니터를 모두 enable)
    $list = Get-MonitorList
    foreach ($m in $list) {
        $isVirtual = (
            ($m.'Monitor Name' -and $m.'Monitor Name' -match $cfg.virtual_display_match) -or
            ($m.'Monitor ID'   -and $m.'Monitor ID'   -match 'MttVDD|IddSampleDriver')
        )
        if (-not $isVirtual -and $m.Active -ne 'Yes' -and $m.Disconnected -ne 'Yes') {
            Write-RuntimeLog "디스플레이 재활성화: $($m.Name) ($($m.'Monitor Name'))"
            Enable-Monitor -Monitor $m
        }
    }

    # 2) 가상 디스플레이 비활성화
    $mon = Find-VirtualMonitor -Pattern $cfg.virtual_display_match
    if ($mon -and $mon.Active -eq 'Yes') {
        Write-RuntimeLog "가상 디스플레이 비활성화: $($mon.'Monitor Name')"
        Disable-Monitor -Monitor $mon
    }

    # 3) 첫 번째 비-가상 활성 디스플레이를 주 디스플레이로
    Start-Sleep -Milliseconds 500
    $list2 = Get-MonitorList
    $primaryCandidate = $list2 | Where-Object {
        $_.Active -eq 'Yes' -and
        -not (
            ($_.'Monitor Name' -and $_.'Monitor Name' -match $cfg.virtual_display_match) -or
            ($_.'Monitor ID'   -and $_.'Monitor ID'   -match 'MttVDD|IddSampleDriver')
        )
    } | Select-Object -First 1
    if ($primaryCandidate) {
        try { Set-PrimaryMonitor -Monitor $primaryCandidate } catch { }
    }

    Write-RuntimeLog "undo.ps1 완료"
    exit 0
}
catch {
    Write-RuntimeLog "undo.ps1 예외: $($_.Exception.Message)" 'ERROR'
    Write-RuntimeLog $_.ScriptStackTrace 'ERROR'
    exit 1
}
