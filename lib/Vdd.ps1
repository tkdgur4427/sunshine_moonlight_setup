# Vdd.ps1 — Virtual Display Driver 다운로드, 인증서 등록, 드라이버 설치.
#
# 참고: itsmikethetech/Virtual-Display-Driver 의 릴리스 구조는 버전마다 조금씩
# 다르므로 이 모듈은 가능한 여러 패턴(MttVDD / IddSampleDriver)을 모두 시도한다.

$Script:VddRepo       = 'itsmikethetech/Virtual-Display-Driver'
# 자동화 친화 마지막 버전 — 디바이스 생성 즉시 UMDF 가 시작되어 가상 모니터가 뜸.
# 25.x 부터는 VDD Control GUI 가 백그라운드에서 동작해야 하므로 헤드리스 자동화 불가.
$Script:VddDefaultTag = '24.12.24'

function Get-VddLatestRelease {
    [CmdletBinding()]
    param([string]$Tag)

    $headers = @{ 'User-Agent' = 'sunshine-setup/1.0' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "token $($env:GITHUB_TOKEN)" }

    if ($Tag) {
        $url = "https://api.github.com/repos/$Script:VddRepo/releases/tags/$Tag"
    } else {
        $url = "https://api.github.com/repos/$Script:VddRepo/releases/latest"
    }
    Write-Log "GitHub API 조회: $url"
    return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60
}

function Select-VddAsset {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Release)

    $assets = @($Release.assets | Where-Object { $_.name -match '\.zip$' })
    if (-not $assets -or $assets.Count -eq 0) {
        throw "VDD 릴리스 $($Release.tag_name) 에서 zip 자산을 찾을 수 없습니다."
    }

    # 1. ARM64 자산 제외 (이 머신이 ARM64 인 경우만 ARM64 선택)
    $archTokens = Get-MachineArchTokens
    $isArm64 = $archTokens[0] -eq 'ARM64'
    $archFilter = if ($isArm64) {
        { param($n) $n -match 'ARM64|arm64|Aarch64' }
    } else {
        { param($n) $n -notmatch 'ARM64|arm64|Aarch64' }
    }
    $candidates = $assets | Where-Object { & $archFilter $_.name }
    if ($candidates.Count -eq 0) { $candidates = $assets }

    # 2. HDR/debug/src/audio 변형보다 일반 버전 우선
    $preferred = $candidates | Where-Object { $_.name -notmatch 'HDR|debug|src|Audio|VAD' }
    if (-not $preferred) { $preferred = $candidates }

    # 3. 'signed' 또는 'Driver' 가 있는 것을 우선 (드라이버 본체)
    $signed = $preferred | Where-Object { $_.name -match 'Signed|Driver' }
    if ($signed) { $preferred = $signed }

    return $preferred | Select-Object -First 1
}

function Test-VddDeviceInstalled {
    # MttVDD / IddSampleDriver HardwareID 만 신뢰 — FriendlyName 'Virtual Display' 는
    # Parsec 등 다른 가상 디스플레이도 매칭되므로 사용 안 함.
    $devs = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.HardwareID -match 'MttVDD|IddSampleDriver'
    }
    return [bool]$devs
}

function Install-VddCertificates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ExtractedDir,
        [Parameter(Mandatory)] $Ctx
    )
    $cers = Get-ChildItem -Path $ExtractedDir -Recurse -Filter *.cer -ErrorAction SilentlyContinue
    if (-not $cers) {
        Write-Log "릴리스 내 .cer 파일이 없습니다. (이미 정식 서명된 드라이버일 가능성)" 'WARN'
        return
    }
    foreach ($cer in $cers) {
        if (Test-IsDryRun $Ctx) {
            Write-Log "[DryRun] Import-Certificate $($cer.FullName) -> TrustedPublisher, Root"
            continue
        }
        foreach ($store in @('TrustedPublisher','Root')) {
            try {
                Import-Certificate -FilePath $cer.FullName -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
                Write-Log "인증서 등록: $($cer.Name) -> LocalMachine\$store"
            } catch {
                Write-Log "인증서 등록 실패 ($($cer.Name) -> $store): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Get-MachineArchTokens {
    <#
    .SYNOPSIS
        현재 머신 아키텍처에 대응하는 폴더명 토큰 (우선순위 순).
        VDD 릴리스는 SignedDrivers/{ARM64,x86,x64}/ 식으로 분기되어 있고
        x86 폴더가 사실상 x64 INF 인 경우가 있어 둘 다 후보로 둔다.
    #>
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch -Regex ($arch) {
        'ARM64' { return @('ARM64','arm64','Aarch64') }
        'AMD64' { return @('x64','amd64','x86') }       # x86 도 fallback (실제 x64 INF 인 경우)
        'x86'   { return @('x86','win32') }
        default { return @('x64','x86','ARM64') }
    }
}

function Find-VddInfFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ExtractedDir)

    $infs = @(Get-ChildItem -Path $ExtractedDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) { return $null }

    # 1. 디스플레이 드라이버 INF 만 (오디오 등 다른 동봉 INF 제외)
    $displayInfs = $infs | Where-Object { $_.Name -match 'MttVDD|IddSampleDriver' }
    if ($displayInfs.Count -eq 0) { $displayInfs = $infs }

    # 2. 머신 아키텍처에 맞는 폴더의 INF 우선 선택
    $archTokens = Get-MachineArchTokens
    foreach ($tok in $archTokens) {
        $hit = $displayInfs | Where-Object {
            $parts = $_.FullName -split '[\\/]'
            $tok -in $parts
        } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    # 3. 매칭 실패 시 첫 번째 디스플레이 INF
    return ($displayInfs | Select-Object -First 1)
}

function Find-Nefconw {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ExtractedDir)
    # 신 VDD 릴리스는 nefcon 미동봉 — 구 릴리스에는 있을 수 있음.
    return Get-ChildItem -Path $ExtractedDir -Recurse -Include 'nefconw.exe','nefconc.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Get-NefconAsset {
    <#
    .SYNOPSIS
        nefarius/nefcon 의 최신 릴리스에서 현재 머신용 nefconw.exe 다운로드.
    .OUTPUTS
        다운로드된 nefconw.exe 의 경로
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DestDir)

    $exePath = Join-Path $DestDir 'nefconw.exe'
    if (Test-Path $exePath) { return $exePath }

    $headers = @{ 'User-Agent' = 'sunshine-setup/1.0' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "token $($env:GITHUB_TOKEN)" }
    $url = 'https://api.github.com/repos/nefarius/nefcon/releases/latest'
    Write-Log "nefcon 릴리스 조회: $url"
    $rel = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60

    # nefcon 릴리스는 보통 nefcon_v*.zip 단일 자산. 안에 nefconw.exe + nefconc.exe + dll 들.
    $asset = $rel.assets | Where-Object { $_.name -match '^nefcon.*\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        $asset = $rel.assets | Where-Object { $_.name -match 'nefcon' } | Select-Object -First 1
    }
    if (-not $asset) {
        throw "nefcon 릴리스에서 zip 자산을 찾지 못했습니다 (assets: $(($rel.assets.name) -join ', '))."
    }
    Write-Log "nefcon 자산 선택: $($asset.name)"

    if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    $tmp = Join-Path $env:TEMP $asset.name
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    Invoke-Download -Url $asset.browser_download_url -Destination $tmp

    if ($asset.name -match '\.zip$') {
        $extract = Join-Path $env:TEMP "nefcon-extract-$PID"
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -Path $tmp -DestinationPath $extract -Force

        # 머신 아키텍처에 맞는 nefconw 선택 (nefcon zip 은 ARM64/x64/x86 폴더 분기)
        $archTokens = Get-MachineArchTokens
        $candidates = Get-ChildItem -Path $extract -Recurse -Filter 'nefconw.exe' -ErrorAction SilentlyContinue
        $picked = $null
        foreach ($tok in $archTokens) {
            $picked = $candidates | Where-Object {
                ($_.FullName -split '[\\/]') -contains $tok
            } | Select-Object -First 1
            if ($picked) { break }
        }
        if (-not $picked) { $picked = $candidates | Select-Object -First 1 }
        if (-not $picked) {
            throw "nefcon zip 에서 nefconw.exe 를 찾지 못함 ($extract)"
        }
        # 의존 dll 도 같은 경로에 있을 수 있으니 nefconw 가 있는 폴더 통째로 복사
        $srcDir = Split-Path -Parent $picked.FullName
        Get-ChildItem -Path $srcDir -File | ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $DestDir $_.Name) -Force
        }
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } else {
        Copy-Item $tmp -Destination $exePath -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $exePath)) {
        throw "nefconw.exe 가 $DestDir 에 배치되지 않았습니다."
    }
    return $exePath
}

function Install-VddDriverPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InfPath,
        [Parameter(Mandatory)] $Ctx
    )
    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] pnputil /add-driver `"$InfPath`" /install"
        return
    }
    Write-Log "드라이버 패키지 등록: $InfPath"
    # pnputil 은 변경 없음=259, 성공=0
    $code = Invoke-Native -FilePath 'pnputil.exe' `
        -ArgumentList @('/add-driver', "`"$InfPath`"", '/install') `
        -AllowedExitCodes @(0, 259, 3010) `
        -NoThrow
    Write-Log "pnputil 종료 코드: $code"
}

function Install-VddRootDevice {
    <#
    .SYNOPSIS
        nefconw 를 사용해 root-enumerated 가상 디바이스 노드 생성.
        이미 디바이스가 존재하면 스킵.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$NefconwPath,
        [Parameter(Mandatory)] $Ctx
    )
    if (Test-VddDeviceInstalled) {
        Write-Log "VDD 디바이스가 이미 등록되어 있어 root device 생성을 생략합니다."
        return
    }
    if (Test-IsDryRun $Ctx) {
        Write-Log "[DryRun] nefconw --create-device-node ..."
        return
    }

    # MttVDD 와 IddSampleDriver 두 패턴을 순차 시도
    $attempts = @(
        @('--create-device-node','--class-name','Display','--class-guid','{4d36e968-e325-11ce-bfc1-08002be10318}','--hardware-id','Root\MttVDD'),
        @('--create-device-node','--class-name','Display','--class-guid','{4d36e968-e325-11ce-bfc1-08002be10318}','--hardware-id','Root\IddSampleDriver')
    )
    foreach ($a in $attempts) {
        $code = Invoke-Native -FilePath $NefconwPath -ArgumentList $a -AllowedExitCodes @(0,1,2,3) -NoThrow
        if (Test-VddDeviceInstalled) {
            Write-Log "VDD 디바이스 등록 확인 (HardwareID: $($a[-1]))"
            return
        }
        Write-Log "nefconw 시도 ($($a[-1])) 실패 또는 디바이스 미감지 (exit=$code)" 'WARN'
    }
    Write-Log "모든 HardwareID 시도가 실패했습니다. 드라이버는 등록되었으나 디바이스가 자동 추가되지 않았습니다." 'WARN'
    Write-Log "수동 추가: 장치 관리자 -> 동작 -> 레거시 하드웨어 추가 -> 'MttVDD' 또는 'IddSampleDriver' 선택" 'WARN'
}

function Invoke-VddInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ctx)

    if (Test-VddDeviceInstalled) {
        Write-Log "VDD 디바이스가 이미 설치되어 있습니다. 다운로드 단계만 갱신 검사합니다."
    }

    # 1) 릴리스 메타 조회 — 사용자 $env:VDD_TAG 우선, 없으면 자동화 친화 기본 태그.
    $tag = if ($env:VDD_TAG) { $env:VDD_TAG } else { $Script:VddDefaultTag }
    $release = Get-VddLatestRelease -Tag $tag
    Write-Log "VDD 릴리스: $($release.tag_name) ($($release.name))"

    # 2) 자산 다운로드
    $asset = Select-VddAsset -Release $release
    Write-Log "선택된 자산: $($asset.name) ($([int]($asset.size/1KB)) KB)"

    if (-not (Test-Path $Ctx.VddRoot)) {
        New-Item -ItemType Directory -Path $Ctx.VddRoot -Force | Out-Null
    }
    $stamp = Join-Path $Ctx.VddRoot ".release-$($release.tag_name)"
    $extractRoot = $Ctx.VddRoot

    if (Test-Path $stamp -PathType Leaf) {
        Write-Log "이미 동일 버전($($release.tag_name)) 추출됨: $extractRoot"
    } else {
        $dlPath = Join-Path $env:TEMP "vdd-$($release.tag_name).zip"
        Invoke-Download -Url $asset.browser_download_url -Destination $dlPath
        Write-Log "압축 해제: $dlPath -> $extractRoot"
        if (-not (Test-IsDryRun $Ctx)) {
            # 안전을 위해 전체 비우지 않고 덮어쓰기. 핵심 파일들만 새 버전으로 교체.
            Expand-Archive -Path $dlPath -DestinationPath $extractRoot -Force
            New-Item -ItemType File -Path $stamp -Force | Out-Null
        }
    }

    # 3) 인증서 등록
    Install-VddCertificates -ExtractedDir $extractRoot -Ctx $Ctx

    # 4) INF 식별 후 드라이버 패키지 등록
    $inf = Find-VddInfFile -ExtractedDir $extractRoot
    if (-not $inf) {
        throw "추출된 디렉토리에서 INF 파일을 찾지 못했습니다: $extractRoot"
    }
    Write-Log "INF 식별: $($inf.FullName)"
    Install-VddDriverPackage -InfPath $inf.FullName -Ctx $Ctx

    # 5) Root device 생성 — nefconw 우선 사용, 없으면 nefcon 릴리스에서 다운로드
    $nef = Find-Nefconw -ExtractedDir $extractRoot
    if (-not $nef) {
        Write-Log "VDD 릴리스에 nefconw 미동봉 — nefarius/nefcon 에서 별도 다운로드"
        try {
            $nefPath = Get-NefconAsset -DestDir (Join-Path $Ctx.VddRoot 'tools')
            $nef = Get-Item $nefPath -ErrorAction SilentlyContinue
        } catch {
            Write-Log "nefconw 다운로드 실패: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($nef) {
        Write-Log "nefconw 사용: $($nef.FullName)"
        Install-VddRootDevice -NefconwPath $nef.FullName -Ctx $Ctx
    } else {
        Write-Log "nefconw 사용 불가 — VDD 디바이스 자동 추가 건너뜀." 'WARN'
        Write-Log "수동: 'C:\VirtualDisplayDriver\VDD Control.exe' 를 실행해 한 번 디바이스 추가 후 재실행" 'WARN'
    }

    # 6) vdd_settings.xml 위치 안내 (사용자가 수동 편집할 수 있도록)
    $settings = Get-ChildItem -Path $extractRoot -Recurse -Filter 'vdd_settings.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($settings) {
        Write-Log "VDD 설정 파일: $($settings.FullName) (해상도 프리셋 편집 가능)"
    }

    # 7) 최종 확인
    if (Test-VddDeviceInstalled) {
        Write-Log "VDD 설치 검증 통과"
    } else {
        Write-Log "VDD 디바이스가 아직 감지되지 않습니다. 재부팅 후 자동 인식될 수 있습니다." 'WARN'
    }
}
