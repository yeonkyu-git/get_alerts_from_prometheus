# AGENTS.md - 모니터링 알림 Slack 템플릿 (공개용)

## 목적
- 이 문서는 Slack 알림 메시지 포맷 템플릿을 정의한다.
- 민감 정보(IP, 토큰, 실제 서버명)는 문서에 포함하지 않는다.

## 기본 원칙
- 메시지는 한국어로 작성한다.
- 시간은 Jakarta 형식(`YYYY-MM-DD(요일) HH:mm`)으로 표시한다.
- 길게 나열하지 않고 핵심만 전달한다.
- 하나의 이벤트는 하나의 메시지로 전송한다.

## 전송 기준
- `firing` 이벤트: 전송
- `resolved` 이벤트: 전송
- 이벤트가 없으면 전송하지 않음

## 상태별 이모지
- `firing`: `🚨` (제목), `🔔` (알람 라인)
- `resolved`: `✅` (제목), `🟢` (알람 라인)

## 권장 템플릿
### firing
- `🚨 경보 알림 | {ENV} | {JAKARTA_TIME}`
- `🌐 환경: {ENV}`
- `🖥️ 대상 서버: {SERVER_ALIAS} ({INSTANCE})`
- `🔔 알람: [{SEVERITY}] {ALERT_SUMMARY}`
- `🛠️ 조치:`
- `  - {ACTION_1}`
- `  - {ACTION_2}`

### resolved
- `✅ 복구 알림 | {ENV} | {JAKARTA_TIME}`
- `🌐 환경: {ENV}`
- `🖥️ 대상 서버: {SERVER_ALIAS} ({INSTANCE})`
- `🟢 알람: [Resolved] {ALERT_SUMMARY}`
- `🛠️ 조치:`
- `  - {ACTION_1}`
- `  - {ACTION_2}`

## 작성 규칙
- 원문 라벨/annotations를 그대로 길게 복붙하지 않는다.
- fingerprint, 내부 job명, 민감 라벨은 노출하지 않는다.
- 값이 없는 항목은 생략한다.
- 같은 의미의 중복 문장은 제거한다.

## 금지 사항
- 실 IP/실 도메인/실 서버 식별자 하드코딩
- 토큰/시크릿/내부 URL 노출
- 다건 이벤트를 한 메시지에 과도하게 덤프

## 플레이스홀더 목록
- `{ENV}`: 환경명 (예: PROD, DEV)
- `{JAKARTA_TIME}`: Jakarta 시간 문자열
- `{SERVER_ALIAS}`: 서버 별칭
- `{INSTANCE}`: 인스턴스 식별자 (예: host:port)
- `{SEVERITY}`: Critical/Warning
- `{ALERT_SUMMARY}`: 한 줄 요약
- `{ACTION_1}`, `{ACTION_2}`: 조치 포인트
