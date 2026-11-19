# MacBook 원격 입력 사용법

Windows에서 Mac 화면을 미러링한 뒤, 영상 창 안에서 키보드와 마우스를 사용할 수 있습니다. 입력은 기본으로 꺼져 있습니다. Mac에서 직접 수신 에이전트를 실행하고 Windows 창에서 페어링해야 합니다.

## 처음 연결하기

1. Windows 알림 영역에서 기존 AirPlay-Windows를 종료하고 개발 배포 폴더의 `airplay-windows.exe`를 실행합니다. 원본과 개발판은 프로그램의 단일 인스턴스 잠금을 공유합니다. Windows 방화벽이 새 실행 파일의 AirPlay 수신을 묻는 경우 사용하는 개인 네트워크를 선택합니다.
2. Mac에서 Windows로 **전체 디스플레이**를 미러링합니다. 확장 디스플레이를 조작하려면 미러링을 시작한 뒤 해당 디스플레이 ID를 선택합니다.
3. 제공한 Mac 소스 폴더를 Mac에 복사하고 터미널에서 해당 폴더로 이동해 `bash start.command`를 실행합니다. 이 스크립트는 처음 실행하거나 소스가 바뀌면 Apple의 Swift 컴파일러로 에이전트를 빌드합니다. `xcrun`이 개발자 도구를 찾지 못하면 `xcode-select --install`로 Command Line Tools를 설치합니다.
4. 스크립트에 **Mac의 LAN IPv4**, **Windows의 LAN IPv4**를 순서대로 입력합니다. Mac에서는 시스템 설정의 Wi-Fi 또는 이더넷 세부사항에서, Windows에서는 `ipconfig`에서 현재 연결의 IPv4를 확인할 수 있습니다. 마지막 디스플레이 ID는 Return을 누르면 Mac 주 디스플레이가 됩니다.
5. macOS **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 권한 요청에 표시된 앱 또는 실행 파일을 허용한 뒤 스크립트를 다시 실행합니다. 터미널에서 실행할 때는 터미널이 권한 주체로 표시될 수 있습니다. 로컬 네트워크나 수신 연결 권한을 묻는 경우 허용합니다. 입력 모니터링 권한은 요청하지 않습니다.
6. Windows 미러링 화면의 **Mac input (F8)** 버튼 또는 **F8**을 누릅니다. Mac 터미널에 나온 32자리 페어링 키를 입력하고 **Enable input**을 선택합니다. AirPlay가 IPv6로 연결된 경우 같은 Mac에서 에이전트를 실행한 사설 IPv4도 입력합니다. **Mac input on**이 표시되면 조작할 수 있습니다.

**F8을 다시 누르면 로컬 조작으로 돌아갑니다.** 같은 미러링 세션에서는 F8로 곧바로 재개할 수 있습니다. 창 포커스를 옮겨도 입력은 꺼집니다. 미러링 세션 변경 시 Windows는 저장해 둔 키를 지우며, Mac 에이전트를 다시 실행하면 새 키가 발급됩니다. Mac 터미널에서 Ctrl-C를 누르면 에이전트가 종료됩니다.

### 연결이 끊겼을 때

오류 창에서 현재 Mac 에이전트의 키를 다시 입력한 뒤 **Enable input**을 누릅니다. 같은 세션에서는 입력한 IPv4가 유지됩니다. IPv6 링크 로컬 미러링의 경우 Windows 이웃 테이블에서 같은 인터페이스와 하드웨어 주소를 가진 사설 IPv4가 하나로 확인되면 주소 칸에 제안합니다. Mac 터미널의 `Listening on` 주소와 대조할 수 있습니다.

| Windows 오류 문구 | 다음 확인 |
|---|---|
| `TCP connection to … failed` 또는 `timed out` | Mac 에이전트의 수신 주소·포트와 Mac 방화벽을 확인합니다. |
| `TLS pairing failed` | Mac 터미널의 허용 Windows 주소와 현재 키를 확인합니다. 새 에이전트는 허용 주소 불일치와 TLS 연결 실패를 터미널에 표시합니다. |
| `TLS paired` 뒤에 준비 오류 | 페어링은 성공했습니다. Mac 터미널 메시지와 손쉬운 사용 권한을 확인합니다. |
| `paired Mac input session disconnected` | 연결 후 끊겼습니다. Mac 쪽 종료 사유에서 디스플레이와 하트비트를 확인합니다. |

## 입력과 좌표

| Windows 입력 | Mac에서의 동작 |
|---|---|
| 왼쪽·오른쪽·가운데 버튼, 더블클릭, 드래그 | 해당 Mac 버튼 동작. 영상 밖으로 드래그하면 가장자리에 고정 |
| 휠 | 세로·가로 스크롤 |
| 왼쪽 Ctrl, 오른쪽 Ctrl | 각각 Command와 Control. Ctrl+C/V는 복사·붙여넣기 |
| Alt, Shift | Option, Shift |
| 문자·숫자·방향키·편집키·기능키 | Mac 활성 입력 소스의 물리 키 위치. F8과 F9는 제어용 |
| 한/영 키 또는 F9 | Mac에 Control-Space 전송. 한국어와 영문 입력 소스를 추가하고 ‘이전 입력 소스 선택’을 Control-Space로 설정 |
| F8 | 입력 제어 전환 |

입력 중에는 영상이 현재 창을 채우고 상단에 제어 상태가 표시됩니다. Windows가 먼저 처리하는 Alt-Tab, Windows 키 조합, Ctrl-Alt-Delete 등은 로컬에 남을 수 있습니다. 창의 테두리는 크기 변경에 쓸 수 있습니다. 화면 가장자리까지 클릭해야 할 때는 입력을 켜기 전에 전체 화면으로 전환합니다.

Windows는 SDL 창 좌표를 렌더러 출력 해상도로 환산하고, 실제 영상 사각형의 여백을 제거한 뒤 회전을 역변환합니다. Mac은 이를 선택한 디스플레이의 Quartz 전역 좌표로 변환합니다. Retina 배율을 직접 입력할 필요가 없습니다. 디스플레이마다 좌표 원점이 다를 수 있으므로 미러링한 디스플레이와 에이전트에서 선택한 디스플레이가 일치해야 합니다. 송신 영상 자체에 검은 여백이 인코딩된 경우 그 안쪽 경계는 자동 검출하지 않습니다. 앱 한 창만 공유하면서 Mac 전체 디스플레이를 대상으로 지정하는 방식은 좌표 보정 대상에서 제외됩니다.

## 구성과 통신

공식 v0.5.0의 C++17/CMake 수신기는 Windows DNS-SD와 Winsock으로 AirPlay를 받고, libplist와 OpenSSL로 제어 프로토콜을 처리합니다. 영상은 FFmpeg H.264/HEVC 디코더와 SDL2 렌더러를 사용하며 Windows GPU 경로는 D3D11입니다. 오디오는 RAOP 디코더와 SDL 출력 경로, UI는 Dear ImGui를 사용합니다. 후속 실기기 확인에 따라 장치 발견과 AirPlay 광고 코드는 변경하지 않았습니다. [공식 v0.5.0 소스](https://github.com/moieric11/AirPlay-Windows/tree/v0.5.0)

입력은 TCP 49721을 사용합니다. Mac은 지정한 사설 또는 링크 로컬 IPv4에서만 수신하고 지정한 Windows IPv4만 허용합니다. Windows는 발신 연결만 합니다. TLS 1.2 PSK-AES128-GCM-SHA256으로 상호 인증하고 암호화합니다. 양쪽에서 공유하는 키는 Mac에서 생성한 128비트 난수이며 자동 저장하지 않습니다. Mac에서 macOS Network.framework와 Core Graphics를 사용하므로 추가 서버·패키지 또는 로그인 서비스 등록이 필요하지 않습니다. [Apple TLS-PSK 예제](https://developer.apple.com/forums/thread/711114) · [OpenSSL PSK 클라이언트 API](https://docs.openssl.org/3.6/man3/SSL_CTX_set_psk_client_callback/)

입력 패킷은 고정 8바이트입니다. 전송 스레드는 제어를 켰을 때 시작하며 키·버튼 순서를 보존하고 연속 이동 이벤트만 병합합니다. 유휴 상태에서는 0.5초마다 연결 상태를 알립니다. Mac은 연결 종료 시 누른 키·버튼을 해제하고, 패킷이 끊기면 마지막 완전한 이벤트에서 3초 뒤에 해제합니다. 현재 연결만 다루며 연결 복구 후에는 F8로 재활성화합니다.

## 개발 및 검증

소스 브랜치는 `feature/mac-input`이며 기준 커밋은 `e883ac821aa2e7c780fb6c75dbd7f71f042fed50`입니다. 주요 변경 위치는 다음과 같습니다.

| 위치 | 내용 |
|---|---|
| `src/input/channel.*` | TLS 클라이언트, 페어링, 제한된 이벤트 큐와 연결 종료 |
| `src/input/video_input.*`, `src/video/video_renderer.cpp` | SDL 이벤트, 페어링 창, F8, 좌표 및 창 모드 |
| `mac/` | Swift 수신기, 권한 확인, Quartz 출력과 실행 스크립트 |
| `CMakeLists.txt`, `tools/test_mac_input.cpp`, `tools/swift-tests/` | 빌드 연결, 좌표·통신 및 수신 로직 회귀 테스트 |

Windows 개발 빌드는 Visual Studio C++ x64, Windows SDK, CMake와 프로젝트의 vcpkg 기준 버전을 사용합니다. 아래 명령은 소스 루트에서 실행합니다.

```powershell
cmake -S . -B build -G "Visual Studio 18 2026" -A x64 "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" -DBUILD_NETWORK_TESTS=ON
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

Swift 수신 로직 테스트는 `swiftc -swift-version 5 mac/InputFrames.swift mac/InputSink.swift tools/swift-tests/main.swift -o /tmp/mac-input-tests && /tmp/mac-input-tests`로 실행할 수 있습니다.

이 개발판은 Windows x64 Release에서 빌드했고 CTest 9개를 통과했습니다. 새 입력 테스트는 로컬 TLS 수신기와 SDL 가상 창으로 인증 실패·성공, 하트비트, 좌표, 드래그, 포커스 상실에 따른 연결 종료를 검증합니다. WSL에서는 Swift 6.1.3으로 수신 프레임 분할, 키 매핑, 해제, 음수 디스플레이 원점 처리를 컴파일하고 실행했습니다. 전체 Swift 소스의 구문 검사도 통과했습니다. Windows 배포본의 도움말 실행을 확인했으며, 실행 중이던 기존 수신기가 포트 7000을 점유해 새 배포본의 실제 미러링 시작은 미검증입니다. Apple SDK를 사용한 에이전트 전체 빌드와 손쉬운 사용 권한을 통한 실제 이벤트 전달도 Mac에서 확인해야 합니다.

실기기에서는 텍스트 편집기에서 한/영 전환과 복사·붙여넣기, 좌우 클릭·더블클릭·드래그를 확인합니다. 창 크기 변경 전후에 영상 네 모서리를 클릭하고, Shift와 마우스를 누른 상태에서 창 포커스 전환·미러링 종료·Wi-Fi 단절을 각각 시험합니다. 오디오와 영상 연속 재생, Retina 및 보조 모니터, Mac의 CPU·메모리와 실제 입력 지연은 기기에서 따로 측정해야 합니다.
