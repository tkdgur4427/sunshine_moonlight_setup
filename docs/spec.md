# Sunshine 원격 스트리밍 자동 셋업 스크립트

새 Windows 노트북에 Sunshine + Virtual Display Driver + 자동화 스크립트를 한 번에 설치/설정하는 PowerShell 기반 셋업 도구.

## 1. 목적과 배경

### 해결하려는 문제

3ds Max 같은 그래픽 작업용 PC를 원격으로 사용할 때, Parsec의 무료 버전은 색 정확도(YUV 4:4:4 미지원)와 비트레이트 제약이 있다. Sunshine + Moonlight 조합은 이 문제를 해결하지만, 다음과 같은 수동 설정이 번거롭다:

- Sunshine 설치 및 초기 설정
- Virtual Display Driver(VDD) 설치 (인증서 등록 등 까다로운 절차)
- 클라이언트 해상도에 맞춘 가상 디스플레이 자동 전환 스크립트
- 노트북 덮개를 닫아도 동작하도록 전원 옵션 변경
- Sunshine과 보조 도구 간 연동 설정

이 모든 과정을 한 번의 스크립트 실행으로 끝내는 것이 목표.

### 사용 시나리오

- 노트북을 호스트로 두고 덮은 채로 외부 기기(태블릿, 다른 PC)에서 원격 작업
- Tailscale을 통해 외부 네트워크에서도 접속
- 클라이언트 해상도가 다양해도(1080p 노트북, 1440p 데스크톱, 아이패드 등) 매번 자동 매칭
- 친구나 동료에게도 동일한 환경을 빠르게 구축해줄 수 있음

## 2. 범위

### 포함되는 기능

- Sunshine 최신 버전 자동 설치
- Virtual Display Driver (itsmikethetech/Virtual-Display-Driver) 자동 설치
- 보조 유틸리티 다운로드 (MultiMonitorTool 등)
- Tailscale 자동 설치 (선택적)
- Sunshine 설정 파일 자동 생성 (sunshine.conf)
- 디스플레이 자동 전환 스크립트 생성 (do.ps1, undo.ps1)
- 전원 옵션 자동 설정 (덮개 닫기 동작)
- 방화벽 규칙 확인 및 추가
- GPU 자동 감지 및 적절한 인코더 설정 (NVENC / AMF / QuickSync)
- 설치 후 다음 단계 안내 (Sunshine 웹 UI 접속, PIN 페어링 방법 등)

### 포함되지 않는 기능

- 클라이언트(Moonlight) 자동 설치 — 다른 기기에서 따로 진행
- Sunshine 웹 UI 첫 로그인 계정 자동 생성 — 보안상 사용자 직접 설정
- Tailscale 자동 로그인 — 브라우저 인증 필요
- Moonlight ↔ Sunshine 자동 페어링 — PIN 입력은 사용자가 진행
- macOS / Linux 호스트 지원 — Windows 전용

## 3. 대상 환경

### 지원 OS

- Windows 11 (주 타겟)
- Windows 10 22H2 이상

### 하드웨어 요구사항

- GPU: NVIDIA (GTX 900 시리즈 이상), AMD (RX 400 시리즈 이상), Intel (HD Graphics 500 시리즈 이상)
  - 하드웨어 인코더가 있어야 실용적인 성능 확보
- RAM: 8GB 이상
- 네트워크: 유선 또는 5GHz Wi-Fi 권장

### 사전 조건

- 관리자 권한이 있는 사용자 계정
- 인터넷 연결 (설치 패키지 다운로드)
- winget (Windows 11 기본 내장, Windows 10은 자동 확인 후 안내)

## 4. 시스템 구성

### 디렉토리 구조

```
C:\
├── Program Files\Sunshine\          # Sunshine 본체 (winget 또는 인스톨러로 설치)
├── VirtualDisplayDriver\            # VDD 영구 설치 위치
│   ├── nefconw.exe
│   ├── *.cer
│   └── vdd_settings.xml
└── sunshine-tools\                  # 자동화 스크립트 및 보조 도구
    ├── MultiMonitorTool.exe
    ├── do.ps1
    ├── undo.ps1
    ├── helpers\
    │   └── display-utils.ps1
    └── logs\
        └── automation.log
```

### 컴포넌트 관계

```
[Moonlight 클라이언트]
       ↓ (HTTPS 페어링 / RTP 스트리밍)
[Tailscale 가상 네트워크]   ← (선택, 외부 접속 시)
       ↓
[Sunshine 호스트]
   ├── Prep Command "Do" → do.ps1 실행
   │       └── MultiMonitorTool로 가상 디스플레이 활성화
   │       └── 클라이언트 해상도로 가상 디스플레이 설정
   ├── 캡처: Virtual Display Driver의 가상 모니터
   ├── 인코딩: GPU 하드웨어 인코더 (NVENC/AMF/QSV)
   └── Prep Command "Undo" → undo.ps1 실행
           └── 가상 디스플레이 비활성화 및 원상 복구
```

## 5. 자동화 스크립트 동작

### setup.ps1 (메인 인스톨러)

다음 단계를 순서대로 실행:

1. 관리자 권한 확인 (없으면 자동 재실행 요청)
2. 시스템 정보 수집 (GPU, OS 버전, 기존 설치 항목)
3. 충돌 가능성 있는 소프트웨어 감지 (Parsec 등) → 경고
4. winget 가용성 확인
5. Sunshine 설치 (이미 있으면 스킵)
6. VDD 다운로드 및 설치
   - GitHub API로 최신 릴리스 조회
   - 인증서를 신뢰할 수 있는 루트 인증 기관에 등록
   - 드라이버 설치 (UAC 프롬프트 발생)
7. MultiMonitorTool 다운로드
8. (선택) Tailscale 설치
9. Sunshine 설정 파일 생성/수정
   - GPU에 맞는 인코더 자동 설정
   - Prep Command 등록
   - 가상 디스플레이를 캡처 대상으로 지정
10. do.ps1, undo.ps1 스크립트 생성
11. 전원 옵션 설정 (덮개 닫기 → 아무것도 안 함)
12. 방화벽 규칙 검증
13. 설치 완료 및 다음 단계 안내 출력

### do.ps1 (접속 시작 시)

Sunshine이 클라이언트 접속을 받으면 호출:

1. 환경 변수 읽기: SUNSHINE_CLIENT_WIDTH, HEIGHT, FPS
2. 가상 디스플레이 활성화 (MultiMonitorTool)
3. 가상 디스플레이 해상도/주사율을 클라이언트 값으로 변경
4. 노트북 내장 디스플레이 비활성화 (선택적, 설정에 따라)
5. 마우스 커서를 가상 디스플레이 영역으로 이동
6. 로그 기록

### undo.ps1 (접속 종료 시)

클라이언트가 접속을 끊으면 호출:

1. 가상 디스플레이 비활성화
2. 내장 디스플레이 재활성화 (사용자가 노트북을 다시 열었을 때 정상 동작)
3. 디스플레이 구성 원상 복구
4. 로그 기록

## 6. 설정 파일

### sunshine.conf 핵심 항목

```ini
# 캡처 대상 디스플레이 (VDD 설치 후 자동 감지된 번호)
output_name = <자동 감지>

# 인코더 (GPU에 따라 자동 선택)
encoder = nvenc          # NVIDIA
# encoder = amfenc       # AMD
# encoder = quicksync    # Intel

# 색 품질
chroma_sampling = yuv444  # 텍스트 선명도 확보

# Prep Commands
[prep_cmd]
do = "powershell.exe -ExecutionPolicy Bypass -File C:\sunshine-tools\do.ps1"
undo = "powershell.exe -ExecutionPolicy Bypass -File C:\sunshine-tools\undo.ps1"
```

### apps.json (Sunshine 앱 정의)

기본 "Desktop" 앱을 가상 디스플레이로 캡처하도록 정의. 필요 시 3ds Max 전용 앱도 추가 가능 (자동 실행).

## 7. 안전성과 견고성

### 멱등성

스크립트를 여러 번 실행해도 안전해야 함. 각 단계에서:

- 이미 설치된 항목은 버전 확인 후 스킵 또는 업데이트
- 설정 파일은 기존 값을 백업한 뒤 병합
- 만든 적 있는 디렉토리는 재생성하지 않음

### 롤백

각 주요 단계 시작 시 상태 스냅샷 저장. 실패 시:

- 설정 파일은 .bak 파일로 복원
- 추가한 방화벽 규칙은 제거
- 변경한 전원 옵션은 원래 값으로

### 로깅

`C:\sunshine-tools\logs\setup.log`에 모든 작업 기록. 단계별 시작/종료, 실패 시 에러 전문, 시스템 정보 포함.

## 8. 검증 방법

설치 완료 후 자동 검증 단계:

1. Sunshine 서비스 또는 프로세스 실행 중인지 확인
2. `https://localhost:47990` 응답 확인
3. 가상 디스플레이가 디스플레이 어댑터에 등록되어 있는지 확인
4. Prep Command 스크립트 단독 실행 테스트
5. 방화벽 규칙 존재 확인

각 항목 통과 여부를 콘솔에 표시하고, 실패한 항목에 대한 트러블슈팅 가이드 출력.

## 9. 사용자 안내

### 설치 후 출력 메시지 (예시)

```
[OK] 설치 완료

다음 단계를 진행하세요:

1. 브라우저에서 https://localhost:47990 접속
2. 관리자 계정 생성 (사용자명/비밀번호)
3. 클라이언트 기기에 Moonlight 설치:
   - PC: https://moonlight-stream.org
   - iOS/Android: 앱스토어에서 "Moonlight Game Streaming"
4. Moonlight에서 호스트 PC 추가:
   - 같은 LAN: 자동 감지됨
   - Tailscale: IP 100.x.x.x 직접 입력
5. PIN 4자리가 표시되면 Sunshine 웹 UI의 "PIN" 탭에 입력 + 기기 이름 지정
6. 페어링 완료 후 "Desktop" 앱 클릭하여 스트리밍 시작

문제 발생 시:
- 로그 위치: C:\sunshine-tools\logs\
- README: <GitHub 레포 URL>
```

## 10. 향후 확장 가능성 (스코프 외)

다음은 이번 버전에는 포함하지 않지만 나중에 추가할 수 있는 항목:

- 시스템 트레이 GUI (PowerShell 대신 C# WinForms)
- 클라이언트별 해상도/비트레이트 프리셋 관리
- 3ds Max 같은 특정 앱을 Sunshine에 자동 등록
- 여러 호스트 PC 간 설정 동기화
- 한 번에 N개 클라이언트 동시 스트리밍 지원 (Channels 자동 조정)

## 11. 참고 자료

- Sunshine: https://github.com/LizardByte/Sunshine
- Moonlight: https://moonlight-stream.org
- Virtual Display Driver: https://github.com/itsmikethetech/Virtual-Display-Driver
- MonitorSwapAutomation: https://github.com/Nonary/MonitorSwapAutomation (자동화 로직 참고)
- MultiMonitorTool: https://www.nirsoft.net/utils/multi_monitor_tool.html
