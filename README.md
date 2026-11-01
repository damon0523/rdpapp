# 원격PC

아이폰에서 Windows 원격 데스크톱(RDP)에 붙는 개인용 앱. 연결은 FreeRDP 3.32.2.

원격 해상도를 지금 보이는 화면 크기에 맞춰 요청하고, 회전하거나 접고 펴면 그 크기로 다시 맞춘다.

## 빌드

GitHub Actions(`.github/workflows/ios.yml`)가 OpenSSL · FreeRDP 를 iOS 용 정적 라이브러리로 빌드하고(`scripts/build-deps.sh`),
XcodeGen 으로 프로젝트를 만들어 서명 없이 앱을 빌드한다. 결과물은 `latest` 릴리스
(https://github.com/damon0523/rdpapp/releases/tag/latest)에 올라간다.

- `RdpApp-xcode.zip` — Mac 에서 Xcode 로 열 프로젝트(라이브러리 포함)
- `RdpApp-unsigned.ipa` — 서명 안 된 앱. Windows 의 Sideloadly 로 Apple ID 서명해 설치할 때

## Mac 에서 폰에 설치

1. `latest` 릴리스에서 `RdpApp-xcode.zip` 을 받아 풀고 `RdpApp.xcodeproj` 를 연다.
2. Xcode → Settings → Accounts 에서 본인 Apple ID 를 추가한다.
3. RdpApp 타깃 → Signing & Capabilities 에서 Team 을 본인(Personal Team)으로 고른다.
   번들 ID 가 이미 쓰이고 있다고 나오면 `io.github.damon0523.rdpapp` 끝을 아무거나 바꾼다.
4. 아이폰을 케이블로 연결하고 위쪽 기기 목록에서 고른 뒤 실행(⌘R).
5. 처음 한 번은 아이폰에서 개발자 모드를 켜고(설정 → 개인정보 보호 및 보안 → 개발자 모드),
   설정 → 일반 → VPN 및 기기 관리에서 본인 Apple ID 를 신뢰해야 열린다.
6. 다 하면 Xcode 에서 Apple ID 를 지운다.

무료 Apple ID 로 설치한 앱은 7일 뒤 열리지 않는다. 그때는 `RdpApp-unsigned.ipa` 를 Windows 의 Sideloadly 로 다시 설치하면 된다.

## 쓰는 법

- 탭: 왼쪽 클릭 · 길게 누르기: 오른쪽 클릭 · 한 손가락 끌기: 왼쪽 버튼 누른 채 이동 · 두 손가락 끌기: 스크롤
- 화면 위 `…` 메뉴: 키보드, 글자 크게 · 작게(Windows 배율을 접속 중에 바꾼다), 시작 메뉴, 연결 끊기
- 한글은 한 글자 조합이 끝나야(다음 글자·띄어쓰기·엔터) 원격으로 넘어간다.
