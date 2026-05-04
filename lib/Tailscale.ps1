# Tailscale.ps1 — Tailscale 설치 (선택적).

$Script:TailscaleWingetId = 'Tailscale.Tailscale'

function Test-TailscaleInstalled {
    if (Get-Command tailscale -ErrorAction SilentlyContinue) { return $true }
    $svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    return [bool]$svc
}

function Invoke-TailscaleInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    if (Test-TailscaleInstalled) {
        Write-Log "Tailscale 이미 설치됨"
        return
    }

    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] winget install $Script:TailscaleWingetId"
        return
    }

    $args = @(
        'install','--id', $Script:TailscaleWingetId,
        '--exact',
        '--accept-source-agreements','--accept-package-agreements',
        '--silent','--disable-interactivity'
    )
    $code = Invoke-Native -FilePath 'winget.exe' -ArgumentList $args -AllowedExitCodes @(0,-1978335189,-1978335212) -NoThrow
    Write-Log "Tailscale winget exit: $code"

    if (-not (Test-TailscaleInstalled)) {
        Write-Log "Tailscale 설치가 끝났는데도 명령/서비스를 찾을 수 없습니다. PATH 갱신을 위해 새 PowerShell 창에서 'tailscale up' 을 실행해 주세요." 'WARN'
    } else {
        Write-Log "Tailscale 설치 완료. 외부 접속을 쓰려면 별도 PowerShell 에서 'tailscale up' 으로 로그인하세요." 'INFO'
    }
}
