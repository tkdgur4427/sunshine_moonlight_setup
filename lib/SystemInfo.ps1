# SystemInfo.ps1 — 시스템 정보 수집 및 사전 환경 점검.

function Get-PrimaryGpu {
    <#
    .SYNOPSIS
        주 GPU 한 개를 반환. (가상/마이크로소프트 기본 어댑터 제외, NVIDIA/AMD/Intel 우선)
    #>
    $all = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -and
            $_.Name -notmatch 'Virtual|Basic|Mirage|Microsoft Basic Display' -and
            $_.PNPDeviceID -notmatch 'ROOT\\'
        }
    if (-not $all) { return $null }

    # 우선순위: NVIDIA > AMD > Intel > 그 외
    $priority = { param($g)
        switch -Regex ($g.Name) {
            'NVIDIA|GeForce|Quadro|RTX|GTX' { 0; break }
            'AMD|Radeon|RX '                { 1; break }
            'Intel|UHD|Iris|Arc'            { 2; break }
            default                          { 9 }
        }
    }
    return $all | Sort-Object @{Expression=$priority} | Select-Object -First 1
}

function Resolve-EncoderForGpu {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Gpu)
    if (-not $Gpu) { return 'software' }
    switch -Regex ($Gpu.Name) {
        'NVIDIA|GeForce|Quadro|RTX|GTX' { return 'nvenc' }
        'AMD|Radeon|RX '                { return 'amfenc' }
        'Intel|UHD|Iris|Arc'            { return 'quicksync' }
        default                          { return 'software' }
    }
}

function Get-OsSummary {
    $os = Get-CimInstance Win32_OperatingSystem
    return [pscustomobject]@{
        Caption       = $os.Caption
        Version       = $os.Version
        BuildNumber   = $os.BuildNumber
        OSArchitecture = $os.OSArchitecture
    }
}

function Get-ConflictingSoftware {
    <#
    .SYNOPSIS
        Sunshine 동작에 간섭할 수 있는 다른 원격/캡처 도구 목록.
    #>
    $patterns = @(
        @{ Name='Parsec';     Match='Parsec' },
        @{ Name='AnyDesk';    Match='AnyDesk' },
        @{ Name='TeamViewer'; Match='TeamViewer' },
        @{ Name='NVIDIA GameStream'; Match='NVIDIA GeForce Experience' }  # GFE의 GameStream과 포트 충돌 가능
    )
    $found = @()
    $reg = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty $reg -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
    foreach ($p in $patterns) {
        if ($installed | Where-Object { $_.DisplayName -like "*$($p.Match)*" }) {
            $found += $p.Name
        }
    }
    return $found
}

function Invoke-SystemInfoPhase {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    $os = Get-OsSummary
    Write-Log "OS: $($os.Caption) ($($os.Version) build $($os.BuildNumber)) $($os.OSArchitecture)"

    $build = [int]$os.BuildNumber
    if ($build -lt 19045) {
        Write-Log "Windows 10 22H2(19045) 미만은 공식 지원 대상이 아닙니다. 진행은 가능하나 일부 기능이 작동하지 않을 수 있습니다." 'WARN'
    }

    $gpu = Get-PrimaryGpu
    if ($gpu) {
        Write-Log "GPU: $($gpu.Name) (드라이버 $($gpu.DriverVersion))"
    } else {
        Write-Log "GPU 감지 실패 — 소프트웨어 인코더로 진행합니다." 'WARN'
    }

    $encoder = Resolve-EncoderForGpu -Gpu $gpu
    Write-Log "선택된 인코더: $encoder"
    if ($encoder -eq 'software') {
        Write-Log "하드웨어 인코더가 없으면 4K/60FPS 같은 고부하 스트리밍은 어렵습니다." 'WARN'
    }

    $Ctx.Gpu     = $gpu
    $Ctx.Encoder = $encoder

    $conflicts = Get-ConflictingSoftware
    if ($conflicts.Count -gt 0) {
        Write-Log "충돌 가능 소프트웨어 감지: $($conflicts -join ', ')" 'WARN'
        Write-Log "동시에 캡처/스트리밍 시 충돌할 수 있으므로 사용 시 한 번에 하나만 활성화하세요." 'WARN'
    }
}

function Assert-WingetAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = (& winget --version) 2>$null
        Write-Log "winget 발견: $ver"
        return
    }
    $msg = @"
winget 명령을 찾을 수 없습니다.

Windows 11 은 기본 내장이며, Windows 10 22H2 도 보통 자동 업데이트로 설치됩니다.
누락된 경우 Microsoft Store 에서 'App Installer' 를 업데이트하거나
https://aka.ms/getwinget 에서 받아 설치한 뒤 다시 실행해 주세요.
"@
    throw $msg
}
