#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.request import urlopen


def parse_datetime_offset(value: Optional[str]) -> Optional[datetime]:
    if not value or not str(value).strip():
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def get_string_dict(obj: Any) -> Dict[str, str]:
    if not isinstance(obj, dict):
        return {}
    return {str(k): "" if v is None else str(v) for k, v in obj.items()}


def stable_fingerprint(environment: str, labels: Dict[str, str]) -> str:
    payload = {"environment": environment}
    for key in sorted(labels.keys()):
        payload[key] = str(labels[key])
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def invoke_prometheus_alerts(prom_url: str) -> Dict[str, Any]:
    uri = prom_url.rstrip("/") + "/api/v1/alerts"
    with urlopen(uri, timeout=20) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


def ensure_state(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        init = {"version": 1, "fingerprints": {}}
        path.write_text(json.dumps(init, ensure_ascii=False, indent=2), encoding="utf-8")


def read_state(path: Path) -> Dict[str, Any]:
    ensure_state(path)
    raw = path.read_text(encoding="utf-8-sig").strip()
    if not raw:
        return {"version": 1, "fingerprints": {}}
    state = json.loads(raw)
    if "fingerprints" not in state or not isinstance(state["fingerprints"], dict):
        state["fingerprints"] = {}
    return state


def write_state(path: Path, state: Dict[str, Any]) -> None:
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def resolve_codex_command(command: str) -> str:
    cmd_path = Path(command)
    if cmd_path.is_file():
        return str(cmd_path)

    candidates: List[str] = []
    try:
        out = subprocess.check_output(["where", command], text=True, stderr=subprocess.DEVNULL)
        candidates = [line.strip() for line in out.splitlines() if line.strip()]
    except subprocess.CalledProcessError:
        pass

    which_path = shutil.which(command)
    if which_path and which_path not in candidates:
        candidates.append(which_path)

    if not candidates:
        raise RuntimeError(f"Codex command '{command}' was not found in PATH.")

    priority = {".exe": 0, ".cmd": 1, ".bat": 2, ".ps1": 3}
    candidates.sort(key=lambda p: priority.get(Path(p).suffix.lower(), 9))
    return candidates[0]


def invoke_codex_alert_dispatch(
    command: str,
    working_dir: Path,
    timeout_sec: int,
    base_prompt: str,
    environment: str,
    slack_channel: str,
    prom_url: str,
    firing_changes: int,
    resolved_changes: int,
    firing_details: List[Dict[str, Any]],
    resolved_details: List[Dict[str, Any]],
) -> None:
    cmd_path = resolve_codex_command(command)

    event_payload = {
        "environment": environment,
        "slack_channel": slack_channel,
        "prom_url": prom_url,
        "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "counts": {
            "firing": firing_changes,
            "resolved": resolved_changes,
        },
        "events": {
            "firing": firing_details,
            "resolved": resolved_details,
        },
    }

    event_json = json.dumps(event_payload, ensure_ascii=False, indent=2)
    prompt = "\n".join(
        [
            base_prompt,
            f"환경: {environment}",
            f"Slack 채널: {slack_channel}",
            f"사전 감지 변화량: firing {firing_changes}건, resolved {resolved_changes}건",
            "규칙: 알람이 없으면 Slack 전송을 생략한다.",
            "중요: 아래 JSON의 events.resolved 는 poller가 상태파일 기반으로 계산한 최종 결과다.",
            "중요: resolved 판정은 재계산하지 말고 JSON을 그대로 사용한다.",
            "다음 JSON을 기준으로 Slack 메시지를 작성/전송한다:",
            event_json,
        ]
    )

    stdout_file = tempfile.NamedTemporaryFile(delete=False)
    stderr_file = tempfile.NamedTemporaryFile(delete=False)
    last_msg_file = tempfile.NamedTemporaryFile(delete=False)
    stdout_file.close()
    stderr_file.close()
    last_msg_file.close()

    try:
        arg_list = [
            "exec",
            "--cd",
            str(working_dir),
            "--skip-git-repo-check",
            "--color",
            "never",
            "-o",
            last_msg_file.name,
            "-",
        ]

        ext = Path(cmd_path).suffix.lower()
        if ext == ".ps1":
            cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", cmd_path] + arg_list
        else:
            cmd = [cmd_path] + arg_list

        with open(stdout_file.name, "wb") as out_fp, open(stderr_file.name, "wb") as err_fp:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=out_fp,
                stderr=err_fp,
                cwd=str(working_dir),
            )
            assert proc.stdin is not None
            proc.stdin.write(prompt.encode("utf-8"))
            proc.stdin.close()

            start = time.time()
            completed_by_output = False
            while True:
                rc = proc.poll()
                if rc is not None:
                    break

                if os.path.exists(last_msg_file.name) and os.path.getsize(last_msg_file.name) > 0:
                    completed_by_output = True
                    break

                if time.time() - start >= timeout_sec:
                    proc.kill()
                    stdout_text = Path(stdout_file.name).read_text(encoding="utf-8", errors="ignore")
                    stderr_text = Path(stderr_file.name).read_text(encoding="utf-8", errors="ignore")
                    raise RuntimeError(
                        f"Codex relay timed out after {timeout_sec} seconds.\nstdout:\n{stdout_text}\nstderr:\n{stderr_text}"
                    )
                time.sleep(1)

            if completed_by_output:
                if proc.poll() is None:
                    proc.kill()
                return

            rc = proc.wait()
            if rc != 0:
                stdout_text = Path(stdout_file.name).read_text(encoding="utf-8", errors="ignore")
                stderr_text = Path(stderr_file.name).read_text(encoding="utf-8", errors="ignore")
                raise RuntimeError(f"Codex relay failed (exit {rc}).\nstdout:\n{stdout_text}\nstderr:\n{stderr_text}")
    finally:
        for p in [stdout_file.name, stderr_file.name, last_msg_file.name]:
            try:
                os.remove(p)
            except OSError:
                pass


def build_detail(labels: Dict[str, str], annotations: Dict[str, str]) -> str:
    description = annotations.get("description", "")
    summary = annotations.get("summary", "")

    detail = description or summary
    if summary and description:
        detail = f"{description} | {summary}"
    if not detail:
        detail = labels.get("mountpoint", "")
    if not detail:
        detail = labels.get("device", "")
    return detail


def to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def main() -> None:
    script_root = Path(__file__).resolve().parent

    parser = argparse.ArgumentParser()
    parser.add_argument("--config-path", default=str(script_root / "config.alerts.json"))
    parser.add_argument("--state-path", default=str(script_root / "state" / "alerts-state.json"))
    parser.add_argument("--reminder-minutes", type=int, default=60)
    parser.add_argument("--environments", nargs="*", default=["prod", "dev_test"])
    parser.add_argument("--codex-command", default="codex")
    parser.add_argument("--codex-timeout-sec", type=int, default=300)
    parser.add_argument(
        "--codex-prompt",
        default="Prometheus MCP Tool을 사용하여 get_alerts를 하고, 알람이 있는 경우 Slack으로 전송한다.",
    )
    args = parser.parse_args()

    config_path = Path(args.config_path)
    state_path = Path(args.state_path)

    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    slack_channel = ((config.get("slack") or {}).get("channel") or "").strip()
    if not slack_channel:
        raise RuntimeError("Slack channel is missing in config.alerts.json (slack.channel).")

    state = read_state(state_path)
    now_utc = datetime.now(timezone.utc)

    try:
        for env_key in args.environments:
            env_cfg = (config.get("environments") or {}).get(env_key)
            if env_cfg is None:
                raise RuntimeError(f"Environment '{env_key}' not found in config.alerts.json")
            prom_url = env_cfg.get("prom_url", "")

            api = invoke_prometheus_alerts(prom_url)
            if api.get("status") != "success":
                raise RuntimeError(f"Prometheus API status != success for {env_key}")
            alerts = ((api.get("data") or {}).get("alerts") or [])

            current_active: Dict[str, Dict[str, Any]] = {}
            eligible: List[str] = []

            for alert in alerts:
                alert_state = str(alert.get("state", ""))
                if alert_state not in ("firing", "pending"):
                    continue

                active_at_utc = parse_datetime_offset(alert.get("activeAt"))
                if active_at_utc is None:
                    continue

                labels = get_string_dict(alert.get("labels") or {})
                annotations = get_string_dict(alert.get("annotations") or {})
                fp = stable_fingerprint(env_key, labels)

                current_active[fp] = {
                    "labels": labels,
                    "annotations": annotations,
                    "activeAtUtc": active_at_utc,
                    "alertState": alert_state,
                }
                eligible.append(fp)

            changes_firing: List[str] = []
            changes_resolved: List[str] = []
            firing_details: List[Dict[str, Any]] = []
            resolved_details: List[Dict[str, Any]] = []

            fingerprints = state.setdefault("fingerprints", {})

            for fp in eligible:
                item = current_active[fp]
                if fp not in fingerprints:
                    fingerprints[fp] = {
                        "env": env_key,
                        "first_seen_utc": to_iso_utc(now_utc),
                        "last_seen_utc": to_iso_utc(now_utc),

                        "last_sent_firing_utc": None,
                        "last_sent_resolved_utc": None,
                        "last_state": item["alertState"],
                        "active_at_utc": to_iso_utc(item["activeAtUtc"]),
                        "labels": item["labels"],
                        "annotations": item["annotations"],
                    }
                else:
                    rec = fingerprints[fp]
                    rec["last_seen_utc"] = to_iso_utc(now_utc)
                    rec["active_at_utc"] = to_iso_utc(item["activeAtUtc"])
                    rec["labels"] = item["labels"]
                    rec["annotations"] = item["annotations"]

                rec = fingerprints[fp]
                previous_state = str(rec.get("last_state") or "")
                current_state = str(item["alertState"])
                should_send = False

                if current_state == "firing":
                    last_sent_firing = parse_datetime_offset(rec.get("last_sent_firing_utc"))
                    if last_sent_firing is None:
                        should_send = True
                    elif (now_utc - last_sent_firing).total_seconds() / 60.0 >= args.reminder_minutes:
                        should_send = True
                    elif previous_state == "pending":
                        should_send = True

                if should_send:
                    labels = item["labels"]
                    annotations = item["annotations"]
                    detail = build_detail(labels, annotations)
                    event = {
                        "status": current_state,
                        "fingerprint": fp,
                        "env": env_key,
                        "alertname": labels.get("alertname"),
                        "severity": labels.get("severity"),
                        "server_name": labels.get("server_name"),
                        "instance": labels.get("instance"),
                        "job": labels.get("job"),
                        "detail": detail,
                        "active_at_utc": to_iso_utc(item["activeAtUtc"]),
                        "ended_at_utc": None,
                        "labels": labels,
                        "annotations": annotations,
                    }
                    if current_state == "firing":
                        changes_firing.append(fp)
                        firing_details.append(event)

                if current_state == "firing":
                    rec["last_sent_resolved_utc"] = None
                rec["last_state"] = current_state

            for fp, rec in list(fingerprints.items()):
                if rec.get("env") != env_key:
                    continue
                if fp in current_active:
                    continue

                last_seen = parse_datetime_offset(rec.get("last_seen_utc"))
                if last_seen is None:
                    continue
                last_state = str(rec.get("last_state") or "")
                if last_state == "resolved":
                    continue

                last_sent_firing = parse_datetime_offset(rec.get("last_sent_firing_utc"))
                if last_sent_firing is None:
                    continue

                labels = get_string_dict(rec.get("labels") or {})
                annotations = get_string_dict(rec.get("annotations") or {})
                active_at = parse_datetime_offset(rec.get("active_at_utc")) or last_seen
                detail = build_detail(labels, annotations)

                resolved_details.append(
                    {
                        "status": "resolved",
                        "fingerprint": fp,
                        "env": env_key,
                        "alertname": labels.get("alertname"),
                        "severity": labels.get("severity"),
                        "server_name": labels.get("server_name"),
                        "instance": labels.get("instance"),
                        "job": labels.get("job"),
                        "detail": detail,
                        "active_at_utc": to_iso_utc(active_at),
                        "ended_at_utc": to_iso_utc(now_utc),
                        "labels": labels,
                        "annotations": annotations,
                    }
                )
                changes_resolved.append(fp)

            if not changes_firing and not changes_resolved:
                continue

            invoke_codex_alert_dispatch(
                command=args.codex_command,
                working_dir=script_root,
                timeout_sec=args.codex_timeout_sec,
                base_prompt=args.codex_prompt,
                environment=env_key,
                slack_channel=slack_channel,
                prom_url=prom_url,
                firing_changes=len(changes_firing),
                resolved_changes=len(changes_resolved),
                firing_details=firing_details,
                resolved_details=resolved_details,
            )

            for fp in changes_firing:
                fingerprints[fp]["last_sent_firing_utc"] = to_iso_utc(now_utc)
            for fp in changes_resolved:
                if fp in fingerprints:
                    del fingerprints[fp]
    finally:
        write_state(state_path, state)


if __name__ == "__main__":
    main()











