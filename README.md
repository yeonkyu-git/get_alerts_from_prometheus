# monitoring-alerts

Prometheus `/api/v1/alerts`를 주기적으로 조회하여 `firing`/`resolved` 변화가 있을 때만 Codex를 통해 Slack으로 전송하는 Python 스크립트입니다.

## 구성 파일
- `poll_alerts.py`: 메인 폴러 스크립트 (Python)
- `run-poller.cmd`: Windows 작업 스케줄러용 실행 래퍼
- `config.alerts.json`: 환경별 Prometheus URL, Slack 채널 (로컬 파일, Git 제외)
- `state/alerts-state.json`: fingerprint 기반 상태 저장 파일 (자동 생성, Git 제외)

## 사전 준비
- Python 3.10+
- `codex` CLI 실행 가능 환경
- Slack Bot Token (`SLACK_BOT_TOKEN`)

권장: 시스템 환경 변수로 토큰 설정

```powershell
setx SLACK_BOT_TOKEN "xoxb-***" /M
```

## 설정 파일 예시
`config.alerts.json` (Git에 올리지 않음)

```json
{
  "slack": {
    "channel": "your-alert-channel"
  },
  "environments": {
    "prod": {
      "prom_url": "http://<PROMETHEUS_HOST>:9090"
    },
    "dev_test": {
      "prom_url": "http://<PROMETHEUS_HOST>:9090"
    }
  }
}
```

## 실행
```powershell
python .\poll_alerts.py
```

옵션 예시:

```powershell
python .\poll_alerts.py `
  --reminder-minutes 60 `
  --environments prod dev_test
```

## 스케줄러 등록 (2분)
관리자 PowerShell:

```powershell
$taskName = "PrometheusAlertPoller"
$runner = (Resolve-Path .\run-poller.cmd).Path
schtasks /Create /F /SC MINUTE /MO 2 /TN $taskName /TR "`"$runner`""
```

삭제:

```powershell
schtasks /Delete /F /TN "PrometheusAlertPoller"
```

## 동작 요약
- `pending`/`firing` 알람을 상태 파일에 추적
- Slack 전송은 `firing`/`resolved` 이벤트만 처리
- `resolved` 전송 후 해당 fingerprint는 상태 파일에서 제거
- 변화가 없으면 Slack 전송 생략

## 보안 주의사항
- `.env`, `config.alerts.json`, `state/`는 Git에 커밋하지 않습니다.
- IP, 토큰, 채널명 등 실운영 값은 예시로 대체해서 문서화합니다.
