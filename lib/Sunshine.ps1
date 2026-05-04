# Sunshine.ps1 — Sunshine 설치 및 설정 디렉토리 탐지.

$Script:SunshineWingetId = 'LizardByte.Sunshine'

function Get-SunshineInstallPath {
    <#
    .SYNOPSIS
        Sunshine 설치 경로(Program Files\Sunshine) 탐지. 없으면 $null.
    #>
    $candidates = @(
        "$env:ProgramFiles\Sunshine",
        "${env:ProgramFiles(x86)}\Sunshine"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'sunshine.exe'))) { return $c }
    }
    return $null
}

function Get-SunshineConfigDir {
    [CmdletBinding()]
    param([string]$InstallPath)
    if (-not $InstallPath) { $InstallPath = Get-SunshineInstallPath }
    if (-not $InstallPath) { return $null }
    $candidates = @(
        (Join-Path $InstallPath 'config'),
        (Join-Path $env:APPDATA  'Sunshine')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    # 아직 없으면 install 디렉토리 하위 config 를 기본으로 채택 (서비스 모드 기준)
    return (Join-Path $InstallPath 'config')
}

function Test-SunshineInstalled {
    return [bool](Get-SunshineInstallPath)
}

function Invoke-SunshineInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    if (Test-SunshineInstalled) {
        Write-Log "Sunshine 이미 설치됨: $(Get-SunshineInstallPath)"
    } else {
        if (Test-IsDryRun $Ctx) {
            Write-Log "[DryRun] winget install $Script:SunshineWingetId"
        } else {
            Write-Log "winget 으로 Sunshine 설치 중..."
            $args = @(
                'install','--id', $Script:SunshineWingetId,
                '--exact',
                '--accept-source-agreements',
                '--accept-package-agreements',
                '--silent',
                '--disable-interactivity'
            )
            # winget 은 이미 설치/업데이트 없음일 때도 0이 아닌 코드 (예: -1978335189) 를 줌
            $code = Invoke-Native -FilePath 'winget.exe' -ArgumentList $args -AllowedExitCodes @(0, -1978335189, -1978335212) -NoThrow
            if (-not (Test-SunshineInstalled)) {
                throw "Sunshine 설치 후에도 실행 파일을 찾지 못했습니다 (winget exit=$code)"
            }
        }
    }

    $installPath = Get-SunshineInstallPath
    if (-not $installPath) {
        throw "Sunshine 설치 경로를 찾을 수 없습니다."
    }
    $cfgDir = Get-SunshineConfigDir -InstallPath $installPath
    Write-Log "Sunshine 설치 경로: $installPath"
    Write-Log "Sunshine 설정 디렉토리: $cfgDir"
    $Ctx.SunshineConfigDir = $cfgDir

    # 설정 디렉토리는 첫 실행 후에 생성되는 경우가 있으므로 미리 만들어 둔다
    if (-not (Test-Path $cfgDir)) {
        if (-not (Test-IsDryRun $Ctx)) {
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        }
        Write-Log "설정 디렉토리 생성: $cfgDir"
    }

    # 서비스 등록 확인 (winget 패키지가 자동으로 SunshineService 를 등록함)
    $svc = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "Sunshine 서비스 상태: $($svc.Status)"
    } else {
        Write-Log "Sunshine 서비스 미등록 — 사용자 수동 실행 모드일 수 있습니다." 'WARN'
    }
}

function Restart-SunshineService {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)
    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] Restart-Service SunshineService"
        return
    }
    $svc = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "SunshineService 가 없어 재시작을 생략합니다." 'WARN'
        return
    }
    try {
        if ($svc.Status -eq 'Running') {
            Restart-Service -Name 'SunshineService' -Force
            Write-Log "SunshineService 재시작 완료"
        } else {
            Start-Service -Name 'SunshineService'
            Write-Log "SunshineService 시작"
        }
    } catch {
        Write-Log "SunshineService 재시작 실패: $($_.Exception.Message)" 'WARN'
    }
}
