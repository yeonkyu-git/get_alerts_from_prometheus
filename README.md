# monitoring-alerts

Prometheus `/api/v1/alerts`를 5분 주기로 조회하고, 상태 변화(`firing`, `resolved`, 60분 리마인드)가 있을 때만 Codex를 통해 Slack으로 전송하는 PowerShell 스크립트입니다.

## 구성 파일
- `poll-alerts.ps1`: 메인 폴러 스크립트
- `config.alerts.json`: 환경별 Prometheus URL, Slack 채널
- `state/alerts-state.json`: fingerprint 기반 상태 저장 파일(자동 생성)
- `run-poller.cmd`: Windows 작업 스케줄러에서 실행할 래퍼

## 사전 준비
- Windows PowerShell 5.1+
- `codex` CLI 실행 가능 환경
- Slack Bot Token (`SLACK_BOT_TOKEN`)

권장: 시스템 환경 변수로 토큰 설정

```powershell
setx SLACK_BOT_TOKEN "xoxb-***" /M
```

로컬 테스트 시 `.env` 파일도 사용할 수 있습니다.

## 설정
`config.alerts.json` 예시:

```json
{
  "slack": {
    "channel": "bsim-server-alerts"
  },
  "environments": {
    "prod": {
      "prom_url": "http://10.23.12.101:9090"
    },
    "dev_test": {
      "prom_url": "http://10.32.16.101:9090"
    }
  }
}
```

## 실행
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\poll-alerts.ps1
```

옵션 예시:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\poll-alerts.ps1 `
  -MinDurationMinutes 5 `
  -ReminderMinutes 60 `
  -Environments @("prod","dev_test")
```

## 스케줄러 등록(5분)
관리자 PowerShell:

```powershell
$taskName = "PrometheusAlertPoller"
$runner = (Resolve-Path .\run-poller.cmd).Path
schtasks /Create /F /SC MINUTE /MO 5 /TN $taskName /TR "`"$runner`""
```

삭제:

```powershell
schtasks /Delete /F /TN "PrometheusAlertPoller"
```

## 동작 요약
- `firing` 알람 중 `MinDurationMinutes` 이상 지속된 항목만 후보로 처리
- fingerprint 기준으로 최초 발생/리마인드(`ReminderMinutes`) 전송
- 상태 파일에서 이전 전송 이력을 기준으로 `resolved` 1회 전송
- 변화가 없으면 Slack 전송 생략
