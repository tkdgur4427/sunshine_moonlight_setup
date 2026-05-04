# Tools.ps1 — MultiMonitorTool 등 보조 도구 다운로드.

$Script:MultiMonitorToolUrl = 'https://www.nirsoft.net/utils/multimonitortool-x64.zip'

function Invoke-ToolsDownload {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    $toolsDir = $Ctx.ToolsRoot
    if (-not (Test-Path $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    $exe = Join-Path $toolsDir 'MultiMonitorTool.exe'
    if (Test-Path $exe) {
        Write-Log "MultiMonitorTool 이미 존재: $exe"
        return
    }

    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] MultiMonitorTool 다운로드 -> $exe"
        return
    }

    $zip = Join-Path $env:TEMP 'multimonitortool.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Invoke-Download -Url $Script:MultiMonitorToolUrl -Destination $zip

    $extract = Join-Path $env:TEMP 'multimonitortool-extracted'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    # 모든 산출물을 ToolsRoot 로 이동 (chm, txt, exe, cfg)
    Get-ChildItem -Path $extract -File | ForEach-Object {
        $dest = Join-Path $toolsDir $_.Name
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
    Write-Log "MultiMonitorTool 설치 완료: $exe"

    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

function Deploy-RuntimeScripts {
    <#
    .SYNOPSIS
        runtime/ 의 do.ps1 / undo.ps1 / helpers 를 ToolsRoot 로 복사.
        멱등: 이미 같은 내용이면 건드리지 않음.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    $src = $Ctx.RuntimeRoot
    $dst = $Ctx.ToolsRoot

    if (-not (Test-Path $src)) {
        throw "runtime/ 디렉토리를 찾을 수 없습니다: $src"
    }

    # 디렉토리 만들기
    foreach ($d in @($dst, (Join-Path $dst 'helpers'), (Join-Path $dst 'logs'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] $src -> $dst 복사"
        return
    }

    # 파일별 복사 (덮어쓰기 전에 동일성 확인)
    $files = Get-ChildItem -Path $src -Recurse -File
    foreach ($f in $files) {
        $rel  = $f.FullName.Substring($src.Length).TrimStart('\','/')
        $tgt  = Join-Path $dst $rel
        $tgtDir = Split-Path -Parent $tgt
        if (-not (Test-Path $tgtDir)) { New-Item -ItemType Directory -Path $tgtDir -Force | Out-Null }

        $needCopy = $true
        if (Test-Path $tgt) {
            $srcHash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
            $tgtHash = (Get-FileHash -Path $tgt        -Algorithm SHA256).Hash
            if ($srcHash -eq $tgtHash) { $needCopy = $false }
        }
        if ($needCopy) {
            Copy-Item -Path $f.FullName -Destination $tgt -Force
            Write-Log "복사: $rel"
        }
    }

    # 사용자 수정 가능한 config.json 은 처음 한 번만 생성 (이후 셋업에서 보존)
    $userCfg = Join-Path $dst 'config.json'
    if (-not (Test-Path $userCfg)) {
        $default = [ordered]@{
            virtual_display_match  = 'Virtual Display'
            disable_other_displays = $false
            default_width          = 1920
            default_height         = 1080
            default_fps            = 60
        } | ConvertTo-Json -Depth 4
        Set-Content -Path $userCfg -Value $default -Encoding UTF8
        Write-Log "기본 config.json 생성: $userCfg"
    } else {
        Write-Log "기존 config.json 보존: $userCfg"
    }
    Write-Log "런타임 스크립트 배포 완료: $dst"
}
