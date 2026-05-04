# Common.ps1 — 로깅, 관리자 권한 검사, 유틸리티 함수.

$Script:LogPath = $null

function Initialize-Logging {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$LogPath)
    $Script:LogPath = $LogPath
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)] [AllowEmptyString()] [string]$Message,
        [Parameter(Position=1)]
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    if ($Script:LogPath) {
        try { Add-Content -Path $Script:LogPath -Value $line -Encoding UTF8 } catch { }
    }
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host "  $Message" -ForegroundColor $color
}

function Test-IsAdministrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    <#
    .SYNOPSIS
        외부 실행 파일 호출. exit code 검사 후 0이 아니면 throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$AllowedExitCodes = @(0),
        [switch]$NoThrow
    )
    Write-Log "$FilePath $($ArgumentList -join ' ')" 'DEBUG'
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -Wait
    $code = $proc.ExitCode
    if ($code -notin $AllowedExitCodes) {
        $msg = "$FilePath 가 종료 코드 $code 로 실패"
        if ($NoThrow) { Write-Log $msg 'WARN'; return $code }
        throw $msg
    }
    return $code
}

function Invoke-Download {
    <#
    .SYNOPSIS
        URL을 다운로드. 임시 파일 후 원자적 이동.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Destination,
        [int]$RetryCount = 3
    )
    if (Test-Path $Destination) {
        Write-Log "이미 다운로드됨: $Destination (생략)"
        return
    }
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Destination.partial"
    $lastErr = $null
    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            Write-Log "다운로드 시도 $i/$RetryCount : $Url"
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
            Move-Item -Path $tmp -Destination $Destination -Force
            Write-Log "다운로드 완료: $Destination"
            return
        }
        catch {
            $lastErr = $_
            Write-Log "다운로드 실패: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds ([math]::Min(8, $i * 2))
        }
    }
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    throw "다운로드 실패 ($Url): $($lastErr.Exception.Message)"
}

function New-BackupCopy {
    <#
    .SYNOPSIS
        파일 백업. <원본>.bak.<timestamp> 형식. 기존 .bak 은 보존.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $ts  = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $bak = "$Path.bak.$ts"
    Copy-Item -Path $Path -Destination $bak -Force
    Write-Log "백업: $Path -> $bak"
    return $bak
}

function Test-IsDryRun {
    param($Ctx)
    return [bool]$Ctx.DryRun
}

function Show-NextSteps {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    $msg = @"
============================================================
다음 단계를 진행하세요.
============================================================

1. 브라우저에서 https://localhost:47990 접속
   (자체 서명 인증서 경고가 뜨면 진행 후 신뢰)
2. 관리자 계정 생성 (사용자명/비밀번호)
3. 클라이언트 기기에 Moonlight 설치
   - PC      : https://moonlight-stream.org
   - iOS/Android : 앱스토어에서 "Moonlight Game Streaming"
4. Moonlight에서 호스트 PC 추가
   - 같은 LAN  : 자동 감지
   - Tailscale : 100.x.x.x 직접 입력
5. PIN이 표시되면 Sunshine 웹 UI -> "PIN" 탭에 입력
6. 페어링 후 "Desktop" 앱을 클릭하여 스트리밍 시작

[로그] $($Ctx.SetupLog)
[설정] $($Ctx.SunshineConfigDir)
[자동화 스크립트] $($Ctx.ToolsRoot)
============================================================
"@
    Write-Host $msg -ForegroundColor Green
}
