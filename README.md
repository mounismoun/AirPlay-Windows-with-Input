# AirPlay Windows with Input

[English](#english)

AirPlay-Windows v0.5.0의 화면 및 오디오 미러링 기능에 Windows의 키보드와 마우스 입력을 통해 Mac을 제어하는 기능을 추가했습니다.

MacBook을 윈도우에서 쉽게 제어하기 위해서 추가한 기능이며 다른 Apple 기기에서 테스트하지 않았습니다.

MacBook과 성공적으로 연결되면, Windows의 키보드 배열은 Mac을 기준으로 작동합니다. F8로 제어를 시작하고, Shift + F8로 제어모드를 해제할 수 있습니다.

이 프로그램은 동일 화면 미러링을 목적으로 수정되었고, 확장 화면 세팅에서는 이 수정의 목적인 입력을 정상적으로 활용할 수 없습니다. 미러링 설정에서 "확장된 디스플레이"가 아닌 "전체 화면"을 선택해주세요.

자세한 세팅 및 사용법은 아래에서 확인해주세요.

### Windows에서 세팅하기
1. Windows에 원격 입력 기능이 포함된 Windows r4.4 x64 ZIP의 압축을 풉니다.
2. 압축을 푼 파일에서 airplay-windows.exe를 실행합니다.
3. 방화벽 안내가 나타나고 동의하면, 로컬 네트워크에서 접근을 허용합니다.
4. MacBook의 화면 미러링 목록에 AirPlay-Windows가 표시되는지 확인합니다. 표시되지 않는다면 MacBook의 Wifi를 해제했다가 다시 연결해보세요. **AirPlay는 연결하고자 하는 기기가 같은 네트워크(동일 서브넷, 동일 Wifi)에 연결되어 있어야합니다.**

### MacBook에서 세팅하기
1. AirPlay Input.app을 사용자 응용 프로그램 폴더(~/Applications)에 복사하고 실행합니다. 소스에서 /mac/Scripts/build.sh를 실행하면 직접 빌드할수도 있습니다.
2. AirPlay Input 앱에서 손쉬운 사용의 권한 설정 열기를 누르고 AirPlay Input을 활성화합니다. 로컬 네트워크나 로그인 키체인 접근 요청이 표시되면 허용합니다.

### 연결하기
1. MacBook의 제어 센터 -> 화면 미러링(사각형이 두개 겹쳐있음)을 선택하고 Windows를 선택합니다.
2. 미러링이 성공하면 Windows 화면에 Macbook의 화면이 미러링 됩니다.
3. Windows 영상 창에서 F8을 누르면 최초 연결시에만 표시되는 페어링 키를 입력칸이 표시됩니다. MacBook의 AirPlay Input에서 복사 가능한 페어링 키를 입력해주세요.
4. 이제 키보드 및 마우스가 MacBook을 정상적으로 제어하는지 확인합니다. 위에서 말했듯, 미러링의 "전체 화면" 설정에서 정상적으로 사용할 수 있습니다. 이제 키보드가 MacBook의 키배열로 작동합니다. Shift + F8을 눌러 제어모드를 해제합니다.

**페어링 키 입력은 최초 연결에서만 요구합니다.**

---

## English

This version adds remote input to AirPlay-Windows v0.5.0. Alongside screen and audio mirroring, you can now control your Mac with the keyboard and mouse connected to your Windows PC.

I added this feature to make it easier to control a MacBook from Windows. I have only tested it with a MacBook.

Once connected, your Windows keyboard follows the Mac keyboard layout. Press **F8** to start controlling the MacBook and **Shift + F8** to release control.

Remote input is designed for mirroring the same screen on both devices. In the MacBook’s mirroring settings, select **Entire Screen**. Input does not work as intended in **Extended Display** mode.

Follow the steps below to set up and connect both devices.

### Set up Windows

1. On your Windows PC, extract the **Windows r4.4 x64 ZIP**, which includes remote input support.
2. Run `airplay-windows.exe` from the extracted folder.
3. If Windows Firewall prompts you, allow the app to communicate on your local network.
4. On the MacBook, check that **AirPlay-Windows** appears in the Screen Mirroring list. If it does not appear, try turning Wi-Fi off and back on. **For AirPlay to work, both devices must be on the same network (the same subnet and Wi-Fi network).**

### Set up the MacBook

1. Copy `AirPlay Input.app` to your user Applications folder (`~/Applications`) and open it. To build the app from source, run `./mac/Scripts/build.sh` from the repository root.
2. In AirPlay Input, open the Accessibility permission settings and enable **AirPlay Input**. If macOS asks for access to the local network or your login keychain, allow it.

### Connect

1. On the MacBook, open **Control Center → Screen Mirroring** (the icon with two overlapping rectangles) and select your Windows PC.
2. Once mirroring starts, you should see the MacBook’s screen on your Windows PC.
3. Press **F8** in the mirroring window on Windows. On the first connection, a pairing key field appears. Copy the pairing key from AirPlay Input on the MacBook and paste it into the field on Windows.
4. Check that your keyboard and mouse control the MacBook. Use **Entire Screen** mirroring so that input works as intended. Your keyboard now follows the MacBook layout. Press **Shift + F8** to release control.

**You only need to enter the pairing key the first time you connect.**
