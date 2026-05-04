# Sunshine 원격 스트리밍 자동 셋업

Windows 노트북 / 데스크톱에 Sunshine + Virtual Display Driver + 자동 디스플레이 전환 스크립트를
한 번에 설치하는 PowerShell 도구.

명세서: [docs/spec.md](docs/spec.md)

## 빠른 시작

1. 이 폴더 전체를 호스트 PC 에 복사 (예: `C:\src\sunshine_moonlight_setup`)
2. **관리자 권한** PowerShell 에서:

   ```powershell
   cd C:\src\sunshine_moonlight_setup
   .\setup.ps1
   ```

   - 권한이 없으면 자동으로 UAC 승격 후 재실행됩니다.
   - Tailscale 도 같이 설치하려면 `-InstallTailscale` 추가.
   - 이미 가상 디스플레이가 있어 VDD 설치를 건너뛰려면 `-SkipVdd`.
   - 실제 변경 없이 동작만 보고 싶으면 `-DryRun`.

3. 끝나면 안내된 다음 단계대로 Sunshine 웹 UI 에서 계정 만들고 Moonlight 페어링.

## 설치되는 것

| 항목                    | 위치                                          |
| ----------------------- | --------------------------------------------- |
| Sunshine                | `C:\Program Files\Sunshine\` (winget)         |
| Virtual Display Driver  | `C:\VirtualDisplayDriver\`                    |
| MultiMonitorTool        | `C:\sunshine-tools\MultiMonitorTool.exe`      |
| do.ps1 / undo.ps1       | `C:\sunshine-tools\`                          |
| 헬퍼 라이브러리         | `C:\sunshine-tools\helpers\display-utils.ps1` |
| 사용자 설정             | `C:\sunshine-tools\config.json`               |
| 셋업 로그               | `C:\sunshine-tools\logs\setup.log`            |
| 자동화 로그 (do/undo)   | `C:\sunshine-tools\logs\automation.log`       |

## 동작 흐름

```
[Moonlight] -> [Sunshine] -- 접속 시작 --> do.ps1
                                          ├ 가상 디스플레이 ON
                                          ├ 클라이언트 해상도 적용
                                          ├ (옵션) 내장 디스플레이 OFF
                                          └ 가상 디스플레이를 주 디스플레이로
                            -- 접속 종료 --> undo.ps1
                                          ├ 가상 디스플레이 OFF
                                          └ 다른 디스플레이 ON / 주 디스플레이 복구
```

## 옵션

### `setup.ps1` 파라미터

| 파라미터              | 기본값                     | 설명                                           |
| --------------------- | -------------------------- | ---------------------------------------------- |
| `-InstallTailscale`   | off                        | Tailscale 도 winget 으로 함께 설치             |
| `-SkipVdd`            | off                        | VDD 설치 단계 건너뜀                           |
| `-DryRun`             | off                        | 변경 없이 어떤 작업이 일어날지 로그만 남김     |
| `-ToolsRoot`          | `C:\sunshine-tools`        | 자동화 스크립트 설치 위치                      |
| `-VddRoot`            | `C:\VirtualDisplayDriver`  | VDD 영구 설치 위치                             |

### VDD 버전 핀

기본은 **24.12.24** — 디바이스 생성 즉시 UMDF가 시작되어 가상 모니터가 자동으로 떠
헤드리스 자동화에 적합한 마지막 버전. 25.x 부터는 VDD Control GUI 백그라운드 앱이
필요해 자동화가 깨진다.

다른 버전을 시도하려면 정확한 태그명으로 핀:

```powershell
$env:VDD_TAG = '24.10.27'
.\setup.ps1
```

### `C:\sunshine-tools\config.json` (런타임 설정)

```json
{
  "virtual_display_match": "Virtual Display",
  "disable_other_displays": false,
  "default_width": 1920,
  "default_height": 1080,
  "default_fps": 60
}
```

- `virtual_display_match` — `do.ps1` 가 가상 디스플레이를 식별할 때 쓰는 이름 패턴 (정규식)
- `disable_other_displays` — `true` 면 스트리밍 중 노트북 내장 화면을 끔
- `default_*` — Sunshine 이 클라이언트 해상도 정보를 못 보낸 경우의 폴백

이 파일은 다시 셋업 스크립트를 돌려도 보존된다.

## 멱등성

`setup.ps1` 은 여러 번 실행해도 안전하다.

- 이미 설치된 winget 패키지는 건너뜀
- VDD 는 디바이스가 이미 등록돼 있으면 다시 추가하지 않음 (드라이버 패키지만 갱신)
- `sunshine.conf` / `apps.json` 은 변경 전에 `.bak.<timestamp>` 백업 후 키 단위로 병합
- `runtime/` 의 do.ps1 / undo.ps1 등은 SHA256 비교 후 변경된 것만 복사

## 다른 머신에 설치할 때

1. 같은 폴더를 USB 든 git 든 옮긴 후 `setup.ps1` 실행이면 끝
2. 환경별로 다르게 가져갈 부분은 `config.json` 만 손대면 됨
3. 사내 GitHub 토큰이 필요한 경우 `$env:GITHUB_TOKEN` 으로 API 호출 한도 회피

## 문제 해결

### Sunshine 웹 UI 가 안 열려요

```powershell
Get-Service SunshineService
Restart-Service SunshineService
```

브라우저에서 `https://localhost:47990` 접속. 자체 서명 인증서 경고는 진행 후 신뢰.

### 가상 디스플레이가 안 보여요

```powershell
Get-PnpDevice | Where-Object { $_.HardwareID -match 'MttVDD|IddSampleDriver' }
```

- 결과가 없으면 재부팅 후 다시 확인
- 그래도 없으면 장치 관리자 → 동작 → "레거시 하드웨어 추가" → "목록에서 직접 선택" → "디스플레이 어댑터" → 디스크 있음 → `C:\VirtualDisplayDriver` 의 INF 선택

### `do.ps1` 가 "가상 디스플레이를 찾을 수 없습니다" 로 실패해요

VDD 버전마다 가상 모니터의 표시 이름이 다릅니다 (예: 신 MttVDD = "VDD by MTT", 구 IddSample = "Virtual Display"). `C:\sunshine-tools\config.json` 의 `virtual_display_match` 정규식을 실제 이름에 맞게 조정하세요.

```powershell
# 실제 모니터 이름 확인
& "C:\sunshine-tools\MultiMonitorTool.exe" /scomma "$env:TEMP\m.csv"
notepad "$env:TEMP\m.csv"   # "Monitor Name" 컬럼 확인
```

### `do.ps1` 가 호출되지 않아요

Sunshine 웹 UI → Applications → Desktop → Edit → "Command Preparations" 항목에 다음이 있어야 한다.

- Do: `powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\sunshine-tools\do.ps1"`
- Undo: 같은 형식으로 undo.ps1
- Run as: Administrator (체크)

### 클라이언트 해상도가 안 맞아요

`C:\sunshine-tools\logs\automation.log` 에서 do.ps1 가 받은 `SUNSHINE_CLIENT_*` 환경변수를 확인.
값이 비어 있으면 Moonlight 측에서 호스트 해상도 추적이 꺼진 상태.

### Sunshine 이 가상 디스플레이를 캡처하지 못해요

`sunshine.conf` 의 `output_name` 값을 확인. 셋업 스크립트는 자동 추정하지만 다중 모니터 환경에서는 어긋날 수 있다.

```powershell
# 현재 디스플레이 식별자 확인
& "C:\sunshine-tools\MultiMonitorTool.exe" /scomma "$env:TEMP\mon.csv"
notepad "$env:TEMP\mon.csv"
```

`Name` 열의 값(예: `\\.\DISPLAY3`)을 `output_name` 에 넣고 SunshineService 재시작.

## 제거 / 롤백

```powershell
# Sunshine
winget uninstall LizardByte.Sunshine

# Tailscale (설치했다면)
winget uninstall Tailscale.Tailscale

# VDD 드라이버
pnputil /enum-drivers | Select-String -Context 1,5 'MttVDD|IddSampleDriver'
# 위에서 확인한 oem*.inf 를 인자로
pnputil /delete-driver oemNN.inf /uninstall /force

# 자동화 스크립트와 VDD 파일
Remove-Item C:\sunshine-tools -Recurse -Force
Remove-Item C:\VirtualDisplayDriver -Recurse -Force

# 백업된 sunshine.conf / apps.json 으로 복원하려면
# C:\Program Files\Sunshine\config\*.bak.<ts> 중 하나를 골라 복사
```

## 알려진 한계

- macOS / Linux 호스트는 미지원 (Sunshine 자체는 가능하지만 이 스크립트는 Windows 전용)
- Sunshine 웹 UI 첫 로그인 계정은 보안상 자동 생성하지 않음 — 직접 만들어야 함
- Tailscale 로그인은 브라우저 인증이 필요하므로 자동화 안 됨 — `tailscale up` 으로 직접 진행
- 다중 GPU 시스템에서 인코더 자동 선택은 우선순위(NVIDIA → AMD → Intel)에 따라 한 개만 선택

## 참고

- Sunshine: <https://github.com/LizardByte/Sunshine>
- Moonlight: <https://moonlight-stream.org>
- Virtual Display Driver: <https://github.com/itsmikethetech/Virtual-Display-Driver>
- MultiMonitorTool: <https://www.nirsoft.net/utils/multi_monitor_tool.html>
- 참고한 자동화 로직: <https://github.com/Nonary/MonitorSwapAutomation>
