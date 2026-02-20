# monitoring-alerts

Prometheus `/api/v1/alerts` 를 5분 주기로 폴링해서, **상태 변화(신규 firing / resolved / 60분 리마인드)** 가 있을 때만 Slack에 요약을 전송하는 PowerShell 스크립트입니다.

## 준비

- PowerShell 5.1+ (Windows 기본)
- Slack Bot Token (`xoxb-...`) 이 채널에 `chat:write` 권한으로 초대되어 있어야 합니다.

### 토큰 설정 (환경 변수 또는 .env)

환경 변수(권장, 시스템 전역):

```powershell
setx SLACK_BOT_TOKEN "xoxb-***" /M
```

`.env` 파일(로컬, 선택):

- `.\.env.example` 을 `.\.env` 로 복사 후 `SLACK_BOT_TOKEN` 값을 넣습니다.
- `poll-alerts.ps1` 은 실행 시 `SLACK_BOT_TOKEN` 이 비어있으면 `.\.env` 를 읽어 채웁니다(기존 환경 변수가 있으면 우선).

설정 파일:
- `config.alerts.json` 에 Prometheus URL 및 Slack 채널명을 설정합니다.

## 수동 실행

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\poll-alerts.ps1
```

## 5분 스케줄 등록(작업 스케줄러)

관리자 PowerShell에서:

```powershell
$taskName = "PrometheusAlertPoller"
$script = (Resolve-Path .\poll-alerts.ps1).Path
schtasks /Create /F /SC MINUTE /MO 5 /TN $taskName /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
```

삭제:

```powershell
schtasks /Delete /F /TN "PrometheusAlertPoller"
```
