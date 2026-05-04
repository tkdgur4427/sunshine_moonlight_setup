# Firewall.ps1 — Sunshine 방화벽 규칙 검증/추가.

function Get-SunshineFirewallRules {
    return Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Sunshine*' }
}

function Confirm-FirewallRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    $rules = Get-SunshineFirewallRules
    if ($rules) {
        Write-Log "Sunshine 방화벽 규칙 $($rules.Count) 개 확인됨"
        foreach ($r in $rules) {
            Write-Log "  - $($r.DisplayName) [$($r.Direction)/$($r.Action)/$($r.Enabled)]"
        }
        return
    }

    Write-Log "Sunshine 방화벽 규칙이 발견되지 않아 직접 추가합니다." 'WARN'
    $exe = Join-Path (Get-SunshineInstallPath) 'sunshine.exe'
    if (-not (Test-Path $exe)) {
        Write-Log "sunshine.exe 가 없어 규칙을 추가할 수 없습니다." 'WARN'
        return
    }

    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] netsh advfirewall add Sunshine rules"
        return
    }

    # 인바운드 — Sunshine 의 기본 포트는 47984..47990 (TCP/UDP) + 47998..48000 (UDP)
    try {
        New-NetFirewallRule -DisplayName 'Sunshine (TCP-In)' -Direction Inbound -Protocol TCP `
            -LocalPort 47984,47989,47990 -Action Allow -Program $exe -Profile Any -Enabled True | Out-Null
        New-NetFirewallRule -DisplayName 'Sunshine (UDP-In)' -Direction Inbound -Protocol UDP `
            -LocalPort 47998,47999,48000,48010 -Action Allow -Program $exe -Profile Any -Enabled True | Out-Null
        Write-Log "방화벽 규칙 추가 완료"
    } catch {
        Write-Log "방화벽 규칙 추가 실패: $($_.Exception.Message)" 'WARN'
    }
}
