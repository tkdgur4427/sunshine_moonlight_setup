#requires -Version 5.1
<#
.SYNOPSIS
    Sunshine + Virtual Display Driver + 자동화 스크립트 일괄 셋업.

.DESCRIPTION
    docs/spec.md 의 명세에 따라 Windows 호스트에 Sunshine 원격 스트리밍 환경을
    구축한다. 멱등성을 가지므로 여러 번 실행해도 안전하다.

.PARAMETER InstallTailscale
    Tailscale 설치 여부. 기본값은 $false (사용자가 명시적으로 -InstallTailscale 지정).

.PARAMETER SkipVdd
    VDD 설치 단계 스킵. 이미 다른 가상 디스플레이를 쓰고 있을 때 사용.

.PARAMETER DryRun
    실제 변경 없이 어떤 작업이 일어날지만 로그에 기록.

.PARAMETER ToolsRoot
    자동화 스크립트가 배치될 디렉토리. 기본값 C:\sunshine-tools.

.PARAMETER VddRoot
    Virtual Display Driver 영구 설치 위치. 기본값 C:\VirtualDisplayDriver.

.EXAMPLE
    PS> .\setup.ps1
    기본 옵션으로 전체 설치 (Tailscale 제외).

.EXAMPLE
    PS> .\setup.ps1 -InstallTailscale
    Tailscale까지 함께 설치.
#>
[CmdletBinding()]
param(
    [switch]$InstallTailscale,
    [switch]$SkipVdd,
    [switch]$DryRun,
    [string]$ToolsRoot = 'C:\sunshine-tools',
    [string]$VddRoot   = 'C:\VirtualDisplayDriver'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # Invoke-WebRequest 가속

# ---------------------------------------------------------------------------
# 1. 라이브러리 로드
# ---------------------------------------------------------------------------
$Script:RepoRoot = $PSScriptRoot
$Script:LibRoot  = Join-Path $RepoRoot 'lib'
$Script:RuntimeRoot = Join-Path $RepoRoot 'runtime'

$libFiles = @(
    'Common.ps1',
    'SystemInfo.ps1',
    'Sunshine.ps1',
    'Vdd.ps1',
    'Tools.ps1',
    'Tailscale.ps1',
    'Config.ps1',
    'Power.ps1',
    'Firewall.ps1',
    'Verify.ps1'
)
foreach ($f in $libFiles) {
    $p = Join-Path $LibRoot $f
    if (-not (Test-Path $p)) {
        throw "필수 라이브러리 누락: $p"
    }
    . $p
}

# ---------------------------------------------------------------------------
# 2. 컨텍스트 초기화 (전역 상태 객체)
# ---------------------------------------------------------------------------
$Ctx = [pscustomobject]@{
    RepoRoot       = $RepoRoot
    RuntimeRoot    = $RuntimeRoot
    ToolsRoot      = $ToolsRoot
    VddRoot        = $VddRoot
    LogDir         = Join-Path $ToolsRoot 'logs'
    SetupLog       = Join-Path $ToolsRoot 'logs\setup.log'
    DryRun         = [bool]$DryRun
    InstallTailscale = [bool]$InstallTailscale
    SkipVdd        = [bool]$SkipVdd
    Gpu            = $null   # SystemInfo 단계에서 채움
    Encoder        = $null
    SunshineConfigDir = $null
    StartedAt      = Get-Date
    Failed         = $false
    FailureReason  = $null
}

# ---------------------------------------------------------------------------
# 3. 사전 점검
# ---------------------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    Write-Host "[!] 관리자 권한이 필요합니다. UAC 승격하여 재실행합니다..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

# 로그 디렉토리는 어드민 권한 확인 후에 생성
New-Item -ItemType Directory -Path $Ctx.LogDir -Force | Out-Null
Initialize-Logging -LogPath $Ctx.SetupLog

Write-Log "============================================================"
Write-Log "Sunshine 자동 셋업 시작 (PID=$PID)"
Write-Log "RepoRoot   = $($Ctx.RepoRoot)"
Write-Log "ToolsRoot  = $($Ctx.ToolsRoot)"
Write-Log "VddRoot    = $($Ctx.VddRoot)"
Write-Log "DryRun     = $($Ctx.DryRun)"
Write-Log "InstallTailscale = $($Ctx.InstallTailscale)"
Write-Log "SkipVdd    = $($Ctx.SkipVdd)"
Write-Log "============================================================"

# ---------------------------------------------------------------------------
# 4. 단계 실행 (각 단계는 try/catch로 격리)
# ---------------------------------------------------------------------------
$phases = @(
    @{ Name='시스템 정보 수집';     Fn={ Invoke-SystemInfoPhase    -Ctx $Ctx } },
    @{ Name='winget 가용성 확인';   Fn={ Assert-WingetAvailable    -Ctx $Ctx } },
    @{ Name='Sunshine 설치';        Fn={ Invoke-SunshineInstall    -Ctx $Ctx } },
    @{ Name='VDD 설치';             Fn={
            if ($Ctx.SkipVdd) {
                Write-Log "VDD 단계 스킵 (-SkipVdd)" 'WARN'
            } else {
                Invoke-VddInstall -Ctx $Ctx
            }
        } },
    @{ Name='보조 도구 다운로드';   Fn={ Invoke-ToolsDownload      -Ctx $Ctx } },
    @{ Name='Tailscale 설치';       Fn={
            if ($Ctx.InstallTailscale) {
                Invoke-TailscaleInstall -Ctx $Ctx
            } else {
                Write-Log "Tailscale 단계 스킵 (-InstallTailscale 미지정)"
            }
        } },
    @{ Name='런타임 스크립트 배포'; Fn={ Deploy-RuntimeScripts     -Ctx $Ctx } },
    @{ Name='Sunshine 설정 작성';   Fn={ Update-SunshineConfig     -Ctx $Ctx } },
    @{ Name='전원 옵션 설정';       Fn={ Set-LidPowerAction        -Ctx $Ctx } },
    @{ Name='방화벽 규칙 검증';     Fn={ Confirm-FirewallRules     -Ctx $Ctx } },
    @{ Name='설치 검증';            Fn={ Invoke-PostInstallVerify  -Ctx $Ctx } }
)

$idx = 0
foreach ($phase in $phases) {
    $idx++
    $label = "[$idx/$($phases.Count)] $($phase.Name)"
    Write-Log ""
    Write-Log "------------------------------------------------------------"
    Write-Log $label
    Write-Log "------------------------------------------------------------"
    Write-Host ""
    Write-Host $label -ForegroundColor Cyan

    try {
        & $phase.Fn
        Write-Log "  -> OK: $($phase.Name)"
    }
    catch {
        $Ctx.Failed = $true
        $Ctx.FailureReason = "$($phase.Name): $($_.Exception.Message)"
        Write-Log "  -> FAIL: $($phase.Name): $($_.Exception.Message)" 'ERROR'
        Write-Log $_.ScriptStackTrace 'ERROR'
        Write-Host "  [!] 실패: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  자세한 내용은 $($Ctx.SetupLog) 확인" -ForegroundColor Red
        break
    }
}

# ---------------------------------------------------------------------------
# 5. 종료 처리
# ---------------------------------------------------------------------------
$elapsed = (Get-Date) - $Ctx.StartedAt
Write-Log ""
Write-Log "============================================================"
Write-Log "총 소요 시간: $([int]$elapsed.TotalSeconds)s"

if ($Ctx.Failed) {
    Write-Log "결과: 실패 — $($Ctx.FailureReason)" 'ERROR'
    Write-Host ""
    Write-Host "[FAIL] 설치 중단됨" -ForegroundColor Red
    exit 1
}

Write-Log "결과: 성공"
Write-Host ""
Write-Host "[OK] 설치 완료" -ForegroundColor Green
Write-Host ""
Show-NextSteps -Ctx $Ctx
exit 0
