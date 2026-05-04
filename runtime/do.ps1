# do.ps1 — Sunshine Prep Command "do".
# 클라이언트 접속 시 호출되어 가상 디스플레이를 활성화/구성한다.
#
# 환경변수 (Sunshine 이 주입):
#   SUNSHINE_CLIENT_WIDTH, SUNSHINE_CLIENT_HEIGHT, SUNSHINE_CLIENT_FPS

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'helpers\display-utils.ps1')

Write-RuntimeLog "============================================================"
Write-RuntimeLog "do.ps1 시작 (PID=$PID)"

$cfg = Read-RuntimeConfig
Write-RuntimeLog "config: virtual_display_match=$($cfg.virtual_display_match), disable_other_displays=$($cfg.disable_other_displays)"

# 1) 클라이언트 해상도 결정 (env -> config 기본값 순)
function Get-IntEnv([string]$name, [int]$default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($v -and ($v -as [int])) { return [int]$v }
    return $default
}
$width  = Get-IntEnv 'SUNSHINE_CLIENT_WIDTH'  $cfg.default_width
$height = Get-IntEnv 'SUNSHINE_CLIENT_HEIGHT' $cfg.default_height
$fps    = Get-IntEnv 'SUNSHINE_CLIENT_FPS'    $cfg.default_fps
Write-RuntimeLog "요청 해상도: ${width}x${height}@${fps}Hz"

try {
    # 2) 가상 디스플레이 활성화
    $mon = Find-VirtualMonitor -Pattern $cfg.virtual_display_match
    if (-not $mon) {
        Write-RuntimeLog "가상 디스플레이를 찾을 수 없습니다. (VDD 가 설치되었는지, config.virtual_display_match 가 맞는지 확인)" 'ERROR'
        exit 1
    }
    Write-RuntimeLog "가상 디스플레이 후보: name='$($mon.'Monitor Name')', id='$($mon.'Monitor ID')', active=$($mon.Active)"

    if ($mon.Active -ne 'Yes') {
        Enable-Monitor -Monitor $mon
        $mon = Wait-MonitorActive -Pattern $cfg.virtual_display_match -TimeoutSec 10
        if (-not $mon -or $mon.Active -ne 'Yes') {
            Write-RuntimeLog "가상 디스플레이 활성화 시간 초과" 'WARN'
        }
    }

    # 3) 해상도/주사율 적용
    Set-MonitorMode -Monitor $mon -Width $width -Height $height -Frequency $fps
    Start-Sleep -Milliseconds 600
    Write-RuntimeLog "해상도 적용 완료"

    # 4) (선택) 다른 디스플레이 비활성화
    if ($cfg.disable_other_displays) {
        $others = Find-OtherActiveMonitors -VirtualPattern $cfg.virtual_display_match
        foreach ($o in $others) {
            Write-RuntimeLog "다른 디스플레이 비활성화: $($o.Name) ($($o.'Monitor Name'))"
            Disable-Monitor -Monitor $o
        }
    }

    # 5) 가상 디스플레이를 주 디스플레이로 (커서/포커스가 자연스럽게 이동)
    try {
        Set-PrimaryMonitor -Monitor $mon
    } catch {
        Write-RuntimeLog "주 디스플레이 변경 실패 (무시): $($_.Exception.Message)" 'WARN'
    }

    # 6) 커서 이동
    $mon = Find-VirtualMonitor -Pattern $cfg.virtual_display_match  # 좌표 갱신용 재조회
    if ($mon) { Move-CursorToMonitor -Monitor $mon }

    Write-RuntimeLog "do.ps1 완료"
    exit 0
}
catch {
    Write-RuntimeLog "do.ps1 예외: $($_.Exception.Message)" 'ERROR'
    Write-RuntimeLog $_.ScriptStackTrace 'ERROR'
    exit 1
}
