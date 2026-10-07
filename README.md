# Connect My World in Herdr

Herdr의 등록 서버를 확인하고 클릭으로 재연결하는 macOS 메뉴바 앱입니다.

- 서버별 SSH·Herdr 응답 확인, 개별 재연결과 체크한 연결만 재연결
- `Tailscale만` 버튼으로 Tailscale 경유 연결만 선택
- Proxmox 아래에 소속 VM 표시 (`└` 트리 표시)
- 접속 불가, Herdr 서버 응답 없음, 연결 꺼짐 상태 구분
- 선택 가능한 Mac 로그인 시 자동 실행

## 다운로드와 설치

[GitHub Releases](https://github.com/justn-hyeok/connect-my-world-in-herdr/releases)에서 ZIP을 받고 압축을 푼 뒤 앱을 Applications 폴더로 옮겨 실행하세요.

v0.2.1 배포 파일은 **Apple Silicon(M1 이상), macOS 15 이상**용입니다. Apple Developer ID 서명과 공증 없이 배포하며, 개발자 계정 없이 만든 로컬 ad-hoc 서명만 포함합니다.

첫 실행이 차단되면 앱을 실행한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기(Open Anyway)**로 해당 앱을 승인할 수 있습니다. [Apple 실행 안내](https://support.apple.com/en-us/102445)를 참고하세요. 시스템 전체의 Gatekeeper를 끌 필요는 없습니다.

### 필요한 환경

- `/opt/homebrew/bin/herdr`와 실행 중인 로컬 Herdr 서버
- Herdr에 등록된 SSH 연결과 기존 OpenSSH 설정/인증
- 원격 서버의 `~/.local/bin/herdr`

도구 경로는 개인 환경에 맞춰 고정돼 있습니다. 모든 서버는 기존 OpenSSH 설정(키, Tailscale 등)으로 직접 접속하며, 앱은 별도 인증 단계를 실행하지 않습니다. Intel/Homebrew의 다른 경로는 이번 배포 파일에서 지원하지 않습니다. Herdr 설정, SSH 키, 비밀번호, 인증 토큰은 배포 파일에 포함하지 않습니다.

## 사용법

서버를 클릭하면 SSH와 원격 Herdr를 확인한 뒤 해당 등록 연결을 껐다 켭니다. 왼쪽 체크박스로 고른 연결만 **선택 재연결**로 순서대로 갱신하고, 실패한 연결을 따로 보여줍니다. Herdr에서 꺼진 연결은 체크돼 있어도 건너뛰며, 꺼진 연결을 켜려면 그 행을 직접 누르세요. 선택은 기억되며, 처음에는 Herdr에서 켜진 연결만 체크됩니다. **Tailscale만**은 켜진 연결 중 `ssh -G`로 확인한 실제 접속 주소, 또는 ProxyJump로 거치는 서버가 `*.ts.net`이나 Tailscale 대역(100.64.0.0/10, fd7a:115c:a1e0::/48)인 연결만 체크합니다. 예를 들어 Tailscale인 pve를 거쳐 LAN으로 붙는 pve-new도 포함됩니다. 60초마다 서버 응답을 확인합니다. ‘연결 가능’은 원격 서버 응답 기준이며 Herdr 화면의 최종 연결 상태까지 보증하지 않습니다.

VM 이름 끝의 ` (pve)`는 `pve` 아래에, ` (pn)`은 `pve-new` 아래에 표시합니다. 부모가 등록되지 않은 VM은 독립 행으로 유지합니다. 등록명과 SSH 대상은 변경하지 않습니다.

## 소스에서 빌드

Xcode/Swift 6.2 이상, macOS 15 이상이 필요합니다. 외부 Swift 패키지 의존성은 없습니다.

```sh
swift test
zsh scripts/build-app.sh
```

앱은 `dist/Connect My World in Herdr.app`에 생성됩니다. 로컬 빌드는 현재 Mac의 아키텍처를 사용합니다.

상태 확인은 `swift run ConnectionCheck`, 특정 연결 갱신은 `swift run ConnectionCheck --reconnect <등록된 SSH 대상>`입니다.

## 검증 범위

Swift Testing 18개가 상태, 선택 재연결, Tailscale 판정, 부분 실패, 등록 변경, 명령 인자/시간 제한, VM 계층을 검증합니다. GUI 버튼 전체 흐름은 검증하지 않았습니다.
