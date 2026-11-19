# MacBook 원격 입력 사용법

Windows에서 Mac의 전체 디스플레이를 미러링하면 영상 창에서 키보드와 마우스를 사용할 수 있습니다.

## 처음 연결하기

1. Windows에서 기존 수신기를 종료하고 r4 폴더의 `airplay-windows.exe`를 실행합니다.
2. Mac에서 Finder의 **이동 → 폴더로 이동**에 `~/Applications`를 입력하고 **AirPlay Input.app**을 엽니다. **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 앱을 허용합니다. 다음 로그인에도 준비되게 하려면 앱의 로그인 시 시작 옵션을 켭니다. 구형 터미널 에이전트가 실행 중이면 종료한 뒤 새 앱을 사용합니다.
3. Mac에서 Windows로 화면 미러링을 시작합니다. Windows 영상 창의 **Mac input (F8)** 버튼을 클릭하거나 **F8**을 누릅니다. Windows가 현재 미러링 송신자의 주소를 선택합니다.
4. 처음 한 번 Mac 앱에서 32자리 키를 복사해 Windows의 **Pairing key**에 붙여넣고 **Enable input**을 누릅니다. 연결되면 영상 창 안에서 Mac을 조작할 수 있습니다. 키는 두 장치 사이에서 직접 옮깁니다.

## 다음 연결부터

미러링 중에 **F8** 한 번으로 제어를 시작합니다. 같은 키를 사용하는 Mac 앱과 Windows 수신기를 재실행해도 페어링이 유지됩니다. MacBook 배열에서는 **Shift+F8**을 누르거나 다른 창으로 이동하면 제어가 해제됩니다. Windows는 현재 세션의 주소를 사용하고 AirPlay가 제공하는 기기 ID로 저장된 키를 찾습니다. ID를 제공하지 않는 송신기는 기기 이름을 사용하며, 이름도 없을 때에는 주소가 바뀌면 다시 페어링합니다.

### 연결이 끊겼을 때

| Windows 표시 | 확인할 사항 |
|---|---|
| `TCP connection to … failed` 또는 `timed out` | Mac 앱이 실행 중인지, 두 기기가 같은 LAN에 있는지, macOS에서 로컬 네트워크 접근이 허용됐는지 확인한 후 다시 연결합니다. |
| `TLS pairing failed` | 키를 재발급했다면 Mac 앱에서 새 키를 복사해 Windows 입력창의 기존 값을 교체합니다. 새 키로 연결에 성공하면 저장된 키가 갱신됩니다. |
| `TLS paired` 뒤에 준비 오류 | Mac 앱의 손쉬운 사용 권한과 수신 상태를 확인합니다. |
| 로그의 `Windows could not save the key` | 현재 세션에서는 제어할 수 있습니다. Windows 자격 증명 관리자를 사용할 수 있는 계정인지 확인합니다. |

TCP 연결이 거부되면 Mac 앱에 **Windows 연결 대기 중**이 표시되는지 확인한 뒤 **Enable input**을 다시 누릅니다. 이 창이 열린 동안에는 입력한 키가 유지됩니다. IPv6로 TCP 연결이 실패하면 Windows는 같은 네트워크 인터페이스에서 같은 Mac의 사설 IPv4가 하나로 확인되는 경우 그 주소로 한 번 더 시도합니다.

주소는 사설 IPv4, 인터페이스 번호가 붙은 링크 로컬 IPv6 또는 ULA를 사용할 수 있습니다. 다른 IPv6 주소로 미러링된 경우 Windows는 같은 인터페이스와 하드웨어 주소에 해당하는 사설 IPv4를 찾습니다. 자동으로 주소를 얻지 못하거나 이전 IPv4 전용 에이전트로 연결할 때는 **Connection address**에서 Mac의 LAN 주소를 지정할 수 있습니다.

## 입력과 좌표

기본값은 MacBook의 물리적인 보조 키 배열입니다. 스페이스바 왼쪽의 **Ctrl · Windows · Alt**가 각각 **Control · Option · Command**로 동작합니다. 예를 들어 **Alt+C/V**로 복사·붙여넣기를 하고, 터미널에서 **Ctrl+C**로 실행 중인 명령을 중단합니다. 기존 왼쪽 Ctrl로 복사하는 방식은 **설정 → Mac 키보드 → MacBook 보조 키 배열 사용**을 끄면 다시 사용할 수 있습니다. 변경 사항은 Windows에 저장됩니다. 기존 Mac 에이전트와 호환됩니다.

| Windows 입력 | Mac에서의 동작 |
|---|---|
| 왼쪽·오른쪽·가운데 버튼, 더블클릭, 드래그 | 해당 Mac 버튼 동작. 영상 밖으로 드래그하면 가장자리에 고정 |
| 휠 | 세로·가로 스크롤 |
| 왼쪽·오른쪽 Ctrl | 해당 쪽 Control |
| 왼쪽·오른쪽 Windows 키 | 해당 쪽 Option |
| 왼쪽·오른쪽 Alt | 해당 쪽 Command |
| Shift | Shift |
| Caps Lock | Mac의 Caps 입력 소스 전환 설정을 따릅니다. 해당 설정을 켜면 짧게 눌러 한/영을 전환하고 길게 눌러 대문자 잠금을 전환합니다. |
| F1~F12 | 새 Mac 앱이 macOS의 표준 기능 키 설정에 따라 처리합니다. 앱에서 상단 행 또는 표준 F1~F12를 선택할 수도 있습니다. F1/F2는 밝기, F3/F4는 Mission Control·Spotlight, F7~F9는 이전·재생/일시 정지·다음, F10~F12는 음소거·음량입니다. |
| 문자·숫자·방향키·편집키·기능키 | Mac 활성 입력 소스의 물리 키 위치 |
| 한/영 키 또는 Shift+F9 | 새 Mac 앱에서 활성화된 한국어·영문 입력 소스를 직접 전환 |
| 오른쪽 Alt와 한/영을 겸하는 키 | MacBook 배열에서는 단독 입력과 조합 모두 오른쪽 Command. 한/영 전환에는 전용 키, Caps Lock 또는 Shift+F9 사용 |
| 오른쪽 Ctrl과 한자를 겸하는 키 | Windows가 오른쪽 Ctrl 위치로 보고하면 Mac의 오른쪽 Control |
| F5 / F6 | 상단 행 모드에서 F5는 현재 앱의 받아쓰기 메뉴, F6는 Mac에 지정된 방해금지 단축키를 사용합니다. 사용할 동작이 없으면 해당 표준 기능 키를 전달합니다. |
| F8 | 로컬 모드에서 제어 시작. 제어 중에는 Mac에 F8 전달 |
| Shift+F8 | MacBook 배열에서 제어 해제. 기존 배열에서는 F8로 해제하고 F9로 한/영 전환 |

입력 중에는 영상이 현재 창을 채웁니다. MacBook 배열에서는 연결된 영상 창이 키보드 포커스를 가진 동안 Windows 키와 Alt+Tab을 원격 단축키로 캡처합니다. Windows에서 창을 전환하려면 Shift+F8로 제어를 해제한 뒤 Alt+Tab을 누릅니다. Ctrl+Alt+Delete는 Windows에서 처리합니다. Windows가 한/영 전용 키로 보고하는 키는 입력 소스 전환에 사용됩니다. 창의 테두리는 크기 변경에 쓸 수 있습니다. 화면 가장자리까지 클릭해야 할 때는 입력을 켜기 전에 전체 화면으로 전환합니다.

Windows는 SDL 창 좌표를 렌더러 출력 해상도로 환산하고, 실제 영상 사각형의 여백을 제거한 뒤 회전을 역변환합니다. Mac은 이를 선택한 디스플레이의 Quartz 전역 좌표로 변환합니다. Retina 배율을 직접 입력할 필요가 없습니다. 디스플레이마다 좌표 원점이 다를 수 있으므로 미러링한 디스플레이와 에이전트에서 선택한 디스플레이가 일치해야 합니다. 송신 영상 자체에 검은 여백이 인코딩된 경우 그 안쪽 경계는 자동 검출하지 않습니다. 앱 한 창만 공유하면서 Mac 전체 디스플레이를 대상으로 지정하는 방식은 좌표 보정 대상에서 제외됩니다.

## 구성과 통신

공식 v0.5.0의 C++17/CMake 수신기는 Windows DNS-SD와 Winsock으로 AirPlay를 받고, libplist와 OpenSSL로 제어 프로토콜을 처리합니다. 영상은 FFmpeg H.264/HEVC 디코더와 SDL2 렌더러를 사용하며 Windows GPU 경로는 D3D11입니다. 오디오는 RAOP 디코더와 SDL 출력 경로, UI는 Dear ImGui를 사용합니다. 후속 실기기 확인에 따라 장치 발견과 AirPlay 광고 코드는 변경하지 않았습니다. [공식 v0.5.0 소스](https://github.com/moieric11/AirPlay-Windows/tree/v0.5.0)

입력 채널은 TCP 49721과 TLS 1.2 PSK-AES128-GCM-SHA256을 사용합니다. Windows는 Mac이 인증과 준비 응답을 마친 뒤에만 128비트 키를 현재 사용자의 Windows 자격 증명 관리자에 저장합니다. 저장된 항목은 일반 자격 증명의 AirPlay-Windows/MacInput/ 접두사로 찾을 수 있습니다.

입력 패킷은 고정 8바이트입니다. 전송 스레드는 제어를 켰을 때 시작하며 키·버튼 순서를 보존하고 연속 이동 이벤트만 병합합니다. 유휴 상태에서는 0.5초마다 연결 상태를 알립니다. Mac은 연결 종료 시 누른 키·버튼을 해제하고, 패킷이 끊기면 마지막 완전한 이벤트에서 3초 뒤에 해제합니다. 현재 연결만 다루며 연결 복구 후에는 F8로 재활성화합니다.

## 개발 및 검증

소스 브랜치는 `feature/mac-input`이며 기준 커밋은 `e883ac821aa2e7c780fb6c75dbd7f71f042fed50`입니다. 주요 변경 위치는 다음과 같습니다.

| 위치 | 내용 |
|---|---|
| `src/input/channel.*` | TLS 클라이언트, 페어링, 제한된 이벤트 큐와 연결 종료 |
| `src/input/video_input.*`, `src/video/video_renderer.cpp` | SDL 이벤트, 페어링 창, F8, 좌표 및 창 모드 |
| `src/input/pairing.*` | 기기별 자격 증명 저장·조회 |
| Mac의 `airplay-input` 프로젝트 | 네이티브 에이전트 앱과 Mac 빌드 |
| `mac/` | 구형 r3 터미널 에이전트 소스 |
| `CMakeLists.txt`, `tools/test_mac_input.cpp`, `tools/swift-tests/` | 빌드 연결, 좌표·통신 및 수신 로직 회귀 테스트 |

Windows 개발 빌드는 Visual Studio C++ x64, Windows SDK, CMake와 프로젝트의 vcpkg 기준 버전을 사용합니다. 아래 명령은 소스 루트에서 실행합니다.

```powershell
cmake -S . -B build -G "Visual Studio 18 2026" -A x64 "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" -DBUILD_NETWORK_TESTS=ON
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

Swift 수신 로직 테스트는 `swiftc -swift-version 5 mac/InputFrames.swift mac/InputSink.swift tools/swift-tests/main.swift -o /tmp/mac-input-tests && /tmp/mac-input-tests`로 실행할 수 있습니다.

Windows 입력 테스트는 키 인증 성공·실패, 준비 응답, 자격 증명 저장 및 새 세션 재연결, 주소 정책, 키 배열, 좌표, 드래그와 포커스 해제를 검사합니다.

실기기에서는 텍스트 편집기에서 한/영 전환과 복사·붙여넣기, 좌우 클릭·더블클릭·드래그를 확인합니다. 창 크기 변경 전후에 영상 네 모서리를 클릭하고, Shift와 마우스를 누른 상태에서 창 포커스 전환·미러링 종료·Wi-Fi 단절을 각각 시험합니다. 오디오와 영상 연속 재생, Retina 및 보조 모니터, Mac의 CPU·메모리와 실제 입력 지연은 기기에서 따로 측정해야 합니다.
