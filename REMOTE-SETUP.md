# Agent Watch — 나만 쓰는 이동용 원격 설정 (2-Mac + cmux)

목표: 아이폰에서 두 office Mac의 cmux 안 claude/codex 세션을 **구분해서 보고, 승인하고, 프롬프트를 직접 입력**.

## 한 번만: 네트워크 (Tailscale)

1. iPhone + 두 Mac에 Tailscale 설치, 같은 계정 로그인.
2. 관리콘솔에서 두 Mac 이름을 구분되게: `office-mac-1`, `office-mac-2`.
3. (Bonjour는 tailnet을 못 넘으므로) 앱에선 **"Enter IP manually"**에 `office-mac-1`(또는 100.x IP) 입력.

## 각 Mac에서 (5분)

```bash
cd claude-watch/skill/bridge
npm install
./setup-hooks.sh 7860                 # Claude 전역 훅 등록 (1회)
sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1   # 잠들면 도달 불가
./install-launchd.sh 7860             # 재부팅에도 살아남는 LaunchAgent로 기동
```

- 재부팅 생존: **자동 로그인 ON** (cmux가 GUI 세션 앱이라 LaunchAgent 사용).
- 페어링 코드는 로그에 찍힘:
  `grep -A4 'AGENT WATCH BRIDGE' ~/Library/Logs/claude-watch/bridge.out.log | tail -6`

## 아이폰 앱

- Xcode로 빌드 → 첫 페어링: "Enter IP manually"에 `office-mac-1` + 코드.
- **두 번째 Mac 추가:** 설정(⚙) → **Macs → Add another Mac** → `office-mac-2` + 코드.
- **전환:** 설정 → Macs에서 탭. (재페어링 없음 — 토큰 저장됨)
- **삭제:** Macs에서 스와이프.

## 구분 방식

| 구분 | 어떻게 |
|---|---|
| 맥북 | 설정 → Macs 에서 선택한 연결 (체크 표시) |
| workspace | 멀티세션 페이저의 폴더명 (각 cmux 워크스페이스를 다른 폴더로) |
| 세션 | `claude` / `[codex]` 배지 |

## 프롬프트 직접 입력 (cmux send)

세션을 고른 뒤 명령을 보내면, bridge가 그 세션의 cwd→cmux surface를 찾아
**라이브 claude/codex TUI에 그대로 타이핑**합니다 (`cmux send` + Enter).
codex 승인도 라이브 surface에 `y`/`2`/Esc로 주입됩니다.

- cmux를 못 찾거나 매핑 실패 시 → 기존 detached `claude -p --continue`로 폴백.
- 매핑은 `cmux top --processes` + `lsof`(cwd)로 자동. cmux 경로는 `install-launchd.sh`가
  `CMUX_BIN`으로 자동 주입.

## 주의 (개인용 최소)

- 아이폰 FaceID/암호 ON (분실 시 승인권한 보호).
- 두 Mac에 gcloud 등 실자격이 있으니, 이동 중 `delete`/`destroy`/`push -f` 승인은 한 번 더 확인.
- bridge 재시작(재부팅/크래시) 시 토큰이 바뀜 → 앱에서 한 번 재페어링(코드는 위 로그 명령으로 확인).
