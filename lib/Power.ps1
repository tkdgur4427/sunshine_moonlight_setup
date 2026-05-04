# Power.ps1 — 노트북 덮개 닫기 동작을 "아무것도 하지 않음" 으로 변경.
#
# powercfg GUID 참조:
#   SUB_BUTTONS = 4f971e89-eebd-4455-a8de-9e59040e7347
#   LIDACTION  = 5ca83367-6e45-459f-a27b-476b1d01c936
#   액션값     : 0=Nothing, 1=Sleep, 2=Hibernate, 3=Shutdown

$Script:SubButtons  = '4f971e89-eebd-4455-a8de-9e59040e7347'
$Script:LidAction   = '5ca83367-6e45-459f-a27b-476b1d01c936'

function Set-LidPowerAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] powercfg LIDACTION 0 (AC/DC)"
        return
    }

    # 데스크톱 PC 에는 LID 동작이 없을 수 있음 — 실패해도 경고만.
    foreach ($mode in @('SETACVALUEINDEX','SETDCVALUEINDEX')) {
        try {
            $code = Invoke-Native -FilePath 'powercfg.exe' `
                -ArgumentList @("/$mode", 'SCHEME_CURRENT', $Script:SubButtons, $Script:LidAction, '0') `
                -AllowedExitCodes @(0) `
                -NoThrow
            if ($code -eq 0) {
                Write-Log "powercfg /$mode LIDACTION = Nothing"
            } else {
                Write-Log "powercfg /$mode 실패 (exit=$code) — LID 미지원 기기일 수 있습니다." 'WARN'
            }
        } catch {
            Write-Log "powercfg /$mode 예외: $($_.Exception.Message)" 'WARN'
        }
    }
    # 변경 사항 활성화
    Invoke-Native -FilePath 'powercfg.exe' -ArgumentList @('/SETACTIVE','SCHEME_CURRENT') -AllowedExitCodes @(0) -NoThrow | Out-Null
}
