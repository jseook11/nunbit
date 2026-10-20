# Personal Fork — Headless / Lecture Modes

> 브랜치: `personal/headless` · 기준: upstream `main` (`07ba072`) · 작업일: 2026-10-20 ~ 21

이 문서는 개인 사용 목적으로 만든 FreeDisplay 포크의 변경점과 사용법을 정리한다.
Upstream에 PR로 보낼 목적이 아니라, 이 Mac에서 두 가지 상황을 해결하기 위한 브랜치다.

## 목적

1. **강의 재생 유지** — 물리 모니터가 꺼져도(또는 잠들어도) Mac이 잠들지 않고 재생이 계속된다.
2. **방치형 게임** — 가상 디스플레이에 게임 창을 두고, 물리 모니터 전원을 끈 상태로 계속 돌린다.

## 사용법

### 방치형 게임 (헤드리스 세션)

1. 메뉴바 → **虚拟显示器**에서 `1920×1080` 설정을 만든다. `HiDPI`는 켜도 되고, `自动`(autoCreate)은 꺼둔다. (이 포크에서는 기본 설정을 미리 넣어둠)
2. 메뉴바 → **无头会话**에서 해당 가상 디스플레이를 선택하고 **开始无头会话**를 누른다.
3. 세션이 가상 디스플레이를 생성/활성화하고 메인 디스플레이로 만든다.
4. 게임 창을 새로 나타난 가상 디스플레이로 드래그한다.
5. 물리 모니터의 전원 버튼을 눌러 끈다. 게임은 가상 디스플레이에서 계속 렌더링된다.
6. 돌아올 때는 모니터 전원을 켜고 **结束无头会话**를 누른다. 이전 메인 디스플레이가 복원되고, 세션이 만든 가상 디스플레이는 제거된다.

> 이미 가상 디스플레이를 수동으로 켜둔 상태라면, 게임 창을 먼저 옮긴 뒤 세션을 시작해도 된다. 이 경우 세션 종료 시 가상 디스플레이는 제거되지 않는다.

> 세션 중에는 해당 가상 디스플레이를 메뉴에서 끄거나 삭제할 수 없다.
> 물리 모니터 전원을 껐다 켜면, 세션은 물리 모니터를 다시 메인으로 복원해 메뉴에 접근할 수 있게 한다. 게임과 세션은 가상 디스플레이에서 계속 실행된다. 모니터를 다시 끄면 가상 디스플레이가 다시 메인이 된다.

### 강의 (강의 모드)

1. 메뉴바 → **网课模式**을 연다.
2. **保持播放（防止系统睡眠）**을 켠다.
3. **立即关闭显示器**를 누르거나, 모니터 전원 버튼을 누르거나, 디스플레이 자동 잠자기를 기다린다.
4. 시스템은 깨어 있고 재생은 계속된다. 키 입력/마우스로 모니터를 다시 켤 수 있다.

> 강의 모드는 **가상 디스플레이를 만들지 않는다.** FairPlay/HDCP 보호 영상은 가상 디스플레이에서 재생되지 않기 때문이다.
> 이 모드는 시스템 잠자기만 막고 디스플레이 잠자기는 허용한다. (`caffeinate -i`와 같은 범위)

## 구현 변경점

### 안정성 / 버그 수정

- 메뉴 패널이 빈 화면으로 뜨던 문제: `ScrollView`에 확정 높이를 주고 `fixedSize` 적용 (PR #9 방식).
- 메뉴를 열 때마다 외부 디스플레이 배열이 초기화되던 문제:
  - `MenuBarExtra` content의 `.task`가 매번 실행되는 것을 이용해 자동 배열이 반복되던 것을 제거.
  - 자동 배열은 실행당 1회, 그리고 add/remove/mode 변경 후에만 debounce 실행.
  - `setMainFlag`에서는 배열하지 않음.
- `CGCompleteDisplayConfiguration` 이후 `CGCancelDisplayConfiguration`을 호출하던 use-after-free 제거.
- 여러 디스플레이 이동을 하나의 transaction으로 통합.
- 메인 디스플레이 전환을 "두 디스플레이 origin 맞바꾸기" 대신 "전체 레이아웃 평행이동"으로 변경.
- `CGVirtualDisplay`:
  - `width/height`는 논리 포인트, `maxPixels`는 HiDPI일 때 2× backing.
  - `apply()` 후 `displayID`/online 상태를 최대 5초 폴링.
  - config UUID에서 stable product/serial 생성.
  - `CGDisplayIOServicePort == 0` 휴리스틱 제거 (macOS 26에서 물리 디스플레이도 0).
- `CGEvent` pass-through에서 `passRetained` 누수 → `passUnretained`.
- ICC 프로파일 적용 전 `mntr` + `RGB ` 헤더 검증.
- 잘못된 타입의 `CGSConfigureDisplayMode` fallback 비활성화.
- virtual display를 자동 배열/프리셋/auto-HiDPI/통합 밝기에서 제외.
- wake 후 virtual display 재생성 (`reconcileActiveDisplays`).

### 새 기능

- `SleepAssertionService` — IOPM assertion 기반 방지. owner별 참조 카운트.
  - `lecture`: `PreventUserIdleSystemSleep`만.
  - `headlessSession`: `PreventUserIdleSystemSleep` + `PreventUserIdleDisplaySleep`.
  - 앱이 죽으면 커널이 assertion을 자동 해제하므로 `caffeinate` 자식 프로세스처럼 남지 않는다.
- `HeadlessSessionService` — 가상 디스플레이 생성/활성화 → 메인 전환 → 방지 assertion → 화면 변경 시 메인 재확인 → 종료 시 복원.
- `LectureModeView` — 방지 토글 + `pmset displaysleepnow` 즉시 화면 끄기 버튼.
- `HeadlessSessionView` — 가상 디스플레이 선택 + 시작/종료 + 상태/에러.
- 버전 메타데이터(`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) 추가.

## 검증 상태

Xcode 27.1 / macOS 26.7.1에서 Debug 빌드까지 완료했다.

- `xcodebuild -project FreeDisplay.xcodeproj -scheme FreeDisplay -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- 서비스/모델 레이어: `swiftc -typecheck` 통과.
- SwiftUI 뷰: Xcode 빌드 통과. 추가로 `NSHostingView` 오프스크린 캡처로 메뉴 패널과 새 뷰 레이아웃 확인.
  - 메뉴 패널이 빈 화면이 아니라 디스플레이 목록/프리셋/도구/설정/푸터까지 정상 렌더링됨.
  - `网课模式`, `无头会话` 행과 내부 컨트롤이 정상 배치됨.
- 실제 하드웨어 스모크 테스트 통과:
  - 1920×1080 논리 / 3840×2160 backing HiDPI 가상 디스플레이 생성.
  - vendor `0xEEEE`, stable model/serial, online 확인.
  - 가상 디스플레이를 메인으로 전환 → 물리 디스플레이가 `(1280,0)`으로 이동.
  - 종료 시 물리 디스플레이 `(0,0)` 메인 복원, 가상 디스플레이 제거.
  - 실제 앱을 실행하고 `autoCreate` config를 넣어 앱 프로세스가 가상 디스플레이를 생성/정리하는 것까지 확인.
  - `SleepAssertionService` owner 참조 카운트: lecture(system) + headless(system+display) → headless 해제 후 system 유지 → 전체 해제 시 0.
- **미검증**: 물리 모니터 전원을 실제로 끈 상태에서 게임/강의가 계속되는지. 이건 사용자가 한 번 테스트해야 한다.

## 현재 설치

- 빌드: Release, ad-hoc 서명
- 설치 위치: `~/Applications/FreeDisplay.app`
- 기본 가상 디스플레이 설정: `1920×1080` / HiDPI / 60Hz / autoCreate 꺼짐
- `无头会话`의 선택값도 위 설정으로 미리 지정해 둠
- 메뉴 UI는 upstream의 중국어를 그대로 사용한다. 새 기능은 **网课模式**(강의 모드), **无头会话**(헤드리스 세션)이다.

## 빌드

```bash
# Xcode 설치 후
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcodegen          # 이미 설치됨
xcodegen generate
xcodebuild -scheme FreeDisplay -configuration Debug build

# Release + DMG
./build.sh
```

## 알려진 한계

- FairPlay/HDCP 영상은 가상 디스플레이에서 재생되지 않는다. 강의 모드는 물리 디스플레이를 유지한다.
- 가상 디스플레이는 60Hz SDR이다. VRR/120Hz는 지원하지 않는다.
- 물리 모니터 전원은 앱이 DDC로 끄지 않는다. 사용자가 모니터 전원 버튼을 누르는 방식이다.
- `pmset displaysleepnow`는 일부 플레이어에서 영상을 일시정지시킬 수 있다. 그 경우 모니터 전원 버튼을 사용한다.
- 메뉴 UI 문자열은 upstream의 중국어를 그대로 둔다. (개인 포크에서 전체 로컬라이제이션은 하지 않음)
- 공증/노타라이즈되지 않은 개인 빌드다.
