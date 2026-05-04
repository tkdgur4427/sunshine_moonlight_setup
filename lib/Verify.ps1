# Verify.ps1 — 설치 후 자가 검증.

function Test-WebEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSec = 5)
    try {
        # Sunshine 은 자체 서명 인증서를 쓰므로 SkipCertificateCheck 처럼 동작시켜야 함.
        # PowerShell 5.1 호환: ServicePointManager 콜백.
        if (-not ('TrustAllCertsPolicy' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int prob) { return true; }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
        return $true
    } catch {
        return $false
    }
}

function Invoke-PostInstallVerify {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    $checks = @()

    # 1) Sunshine 프로세스/서비스
    $proc = Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue
    $svc  = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
    $checks += @{
        Name = 'Sunshine 실행 중'
        Pass = ([bool]$proc -or ($svc -and $svc.Status -eq 'Running'))
        Hint = '서비스 시작: Start-Service SunshineService  /  수동 실행 시 작업 표시줄 트레이의 Sunshine 아이콘 확인'
    }

    # 2) 웹 UI 접근
    $checks += @{
        Name = '웹 UI (https://localhost:47990) 응답'
        Pass = (Test-WebEndpoint -Url 'https://localhost:47990' -TimeoutSec 5)
        Hint = '서비스 재시작 후 다시 시도. 방화벽이 localhost 를 막지 않는지 확인.'
    }

    # 3) 가상 디스플레이 디바이스
    $checks += @{
        Name = '가상 디스플레이 디바이스 등록'
        Pass = (Test-VddDeviceInstalled)
        Hint = '재부팅 후 자동 인식되는 경우가 많습니다. 안 되면 장치 관리자에서 수동 추가.'
    }

    # 4) Prep Command 스크립트 존재
    $do   = Join-Path $Ctx.ToolsRoot 'do.ps1'
    $undo = Join-Path $Ctx.ToolsRoot 'undo.ps1'
    $checks += @{
        Name = 'do.ps1 / undo.ps1 배치 완료'
        Pass = ((Test-Path $do) -and (Test-Path $undo))
        Hint = "$($Ctx.ToolsRoot) 의 do.ps1 / undo.ps1 존재 여부 확인."
    }

    # 5) 방화벽 규칙
    $rules = Get-SunshineFirewallRules
    $checks += @{
        Name = '방화벽 규칙 존재'
        Pass = ([bool]$rules)
        Hint = 'New-NetFirewallRule 로 직접 추가하거나 Sunshine 재설치 시도.'
    }

    # 6) MultiMonitorTool
    $mmt = Join-Path $Ctx.ToolsRoot 'MultiMonitorTool.exe'
    $checks += @{
        Name = 'MultiMonitorTool 배치 완료'
        Pass = (Test-Path $mmt)
        Hint = "$mmt 다운로드/배치 재시도."
    }

    Write-Host ""
    Write-Host "[검증]" -ForegroundColor Cyan
    $allPass = $true
    foreach ($c in $checks) {
        if ($c.Pass) {
            Write-Host ("  [PASS] " + $c.Name) -ForegroundColor Green
            Write-Log  ("VERIFY PASS: " + $c.Name)
        } else {
            $allPass = $false
            Write-Host ("  [FAIL] " + $c.Name) -ForegroundColor Yellow
            Write-Host ("         힌트: " + $c.Hint) -ForegroundColor DarkYellow
            Write-Log  ("VERIFY FAIL: " + $c.Name + " | hint: " + $c.Hint) 'WARN'
        }
    }

    if (-not $allPass) {
        Write-Log "일부 검증 항목이 실패했지만 설치 자체는 계속 사용 가능할 수 있습니다." 'WARN'
    }
}
