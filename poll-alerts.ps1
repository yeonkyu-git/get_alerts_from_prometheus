param(
  [string] $ConfigPath = (Join-Path $PSScriptRoot "config.alerts.json"),
  [string] $StatePath = (Join-Path $PSScriptRoot "state\\alerts-state.json"),
  [int] $MinDurationMinutes = 5,
  [int] $ReminderMinutes = 60,
  [string[]] $Environments = @("prod", "dev_test"),
  [string] $CodexCommand = "codex",
  [int] $CodexTimeoutSec = 300,
  [string] $CodexPrompt = "Prometheus MCP Tool을 사용하여 get_alerts를 하고, 알람이 있는 경우 Slack으로 전송한다."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-Hashtable($obj) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [string] -or $obj.GetType().IsPrimitive) { return $obj }
  if ($obj -is [DateTime] -or $obj -is [DateTimeOffset]) { return $obj }

  if ($obj -is [System.Collections.IDictionary]) {
    $h = @{}
    foreach ($k in $obj.Keys) {
      $h[[string]$k] = ConvertTo-Hashtable $obj[$k]
    }
    return $h
  }

  if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
    $arr = @()
    foreach ($item in $obj) { $arr += ,(ConvertTo-Hashtable $item) }
    return $arr
  }

  if ($obj -is [pscustomobject]) {
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) {
      $h[$p.Name] = ConvertTo-Hashtable $p.Value
    }
    return $h
  }

  return $obj
}

function Parse-DateTimeOffset([string] $value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Get-StringHashtableFromPsObject($obj) {
  $h = @{}
  if ($null -eq $obj) { return $h }
  if ($obj.PSObject -and $obj.PSObject.Properties) {
    foreach ($p in $obj.PSObject.Properties) {
      $h[$p.Name] = [string]$p.Value
    }
  }
  return $h
}

function Get-StableFingerprint([string] $environment, [hashtable] $labels) {
  $all = @{}
  $all["environment"] = $environment
  foreach ($key in ($labels.Keys | Sort-Object)) {
    $all[$key] = [string]$labels[$key]
  }
  $json = ($all | ConvertTo-Json -Compress)
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $sha = [Security.Cryptography.SHA256]::Create()
  $hash = $sha.ComputeHash($bytes)
  return -join ($hash | ForEach-Object { $_.ToString("x2") })
}

function Invoke-PrometheusAlerts([string] $promUrl) {
  $uri = ($promUrl.TrimEnd("/")) + "/api/v1/alerts"
  return Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 20
}

function Ensure-State([string] $path) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  if (-not (Test-Path $path)) {
    $init = @{ version = 1; fingerprints = @{} }
    $init | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
  }
}

function Read-State([string] $path) {
  Ensure-State $path
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{ version = 1; fingerprints = @{} } }
  $obj = $raw | ConvertFrom-Json
  $state = ConvertTo-Hashtable $obj
  if ($null -eq $state["fingerprints"]) { $state["fingerprints"] = @{} }
  return $state
}

function Write-State([string] $path, $state) {
  $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-CodexAlertDispatch(
  [string] $command,
  [string] $workingDir,
  [int] $timeoutSec,
  [string] $basePrompt,
  [string] $environment,
  [string] $slackChannel,
  [string] $promUrl,
  [int] $pendingChanges,
  [int] $firingChanges,
  [int] $resolvedChanges,
  [System.Collections.IEnumerable] $pendingDetails,
  [System.Collections.IEnumerable] $firingDetails,
  [System.Collections.IEnumerable] $resolvedDetails
) {
  $cmdCandidates = @(Get-Command $command -All -ErrorAction SilentlyContinue)
  if ($cmdCandidates.Count -eq 0) {
    throw "Codex command '$command' was not found in PATH."
  }
  $cmdInfo = $cmdCandidates |
    Where-Object { $_.Path } |
    Sort-Object {
      $ext = [IO.Path]::GetExtension($_.Path).ToLowerInvariant()
      switch ($ext) {
        ".exe" { 0; break }
        ".cmd" { 1; break }
        ".bat" { 2; break }
        ".ps1" { 3; break }
        default { 9; break }
      }
    } |
    Select-Object -First 1
  if ($null -eq $cmdInfo) {
    throw "Codex command '$command' did not resolve to an executable path."
  }
  $cmdPath = $cmdInfo.Path

  $eventPayload = @{
    environment = $environment
    slack_channel = $slackChannel
    prom_url = $promUrl
    generated_at_utc = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("o")
    counts = @{
      pending = $pendingChanges
      firing = $firingChanges
      resolved = $resolvedChanges
    }
    events = @{
      pending = @($pendingDetails)
      firing = @($firingDetails)
      resolved = @($resolvedDetails)
    }
  }
  $eventJson = $eventPayload | ConvertTo-Json -Depth 20

  $prompt = @(
    $basePrompt
    "환경: $environment"
    "Slack 채널: $slackChannel"
    "사전 감지 변화량: pending ${pendingChanges}건, firing ${firingChanges}건, resolved ${resolvedChanges}건"
    "규칙: 알람이 없으면 Slack 전송을 생략한다."
    "중요: 아래 JSON의 events.resolved 는 poller가 상태파일 기반으로 계산한 최종 결과다."
    "중요: resolved 판정은 재계산하지 말고 JSON을 그대로 사용한다."
    "다음 JSON을 기준으로 Slack 메시지를 작성/전송한다:"
    $eventJson
  ) -join "`n"

  $stdoutFile = [IO.Path]::GetTempFileName()
  $stderrFile = [IO.Path]::GetTempFileName()
  $lastMsgFile = [IO.Path]::GetTempFileName()
  $stdinFile = [IO.Path]::GetTempFileName()
  try {
    Set-Content -LiteralPath $stdinFile -Value $prompt -Encoding UTF8
    # Use non-interactive exec and a completion file so we can detect success
    # even when codex process does not terminate promptly on Windows.
    $argList = @("exec", "--cd", $workingDir, "--skip-git-repo-check", "--color", "never", "-o", $lastMsgFile, "-")
    $ext = [IO.Path]::GetExtension($cmdPath).ToLowerInvariant()
    if ($ext -eq ".ps1") {
      $proc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cmdPath) + $argList -NoNewWindow -PassThru -RedirectStandardInput $stdinFile -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    } else {
      $proc = Start-Process -FilePath $cmdPath -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardInput $stdinFile -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    }
    $startAt = Get-Date
    $completedByOutput = $false
    while ($true) {
      $proc.Refresh()
      if ($proc.HasExited) { break }
      if ((Test-Path -LiteralPath $lastMsgFile) -and ((Get-Item -LiteralPath $lastMsgFile).Length -gt 0)) {
        $completedByOutput = $true
        break
      }
      if (((Get-Date) - $startAt).TotalSeconds -ge $timeoutSec) {
        $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        try { $proc.Kill() } catch {}
        throw ("Codex relay timed out after {0} seconds.`nstdout:`n{1}`nstderr:`n{2}" -f $timeoutSec, $stdout, $stderr)
      }
      Start-Sleep -Seconds 1
    }
    if ($completedByOutput) {
      if (-not $proc.HasExited) {
        try { $proc.Kill() } catch {}
      }
      return
    }
    $proc.Refresh()
    if ($proc.ExitCode -ne 0) {
      $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
      $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
      throw ("Codex relay failed (exit {0}).`nstdout:`n{1}`nstderr:`n{2}" -f $proc.ExitCode, $stdout, $stderr)
    }
  } finally {
    Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lastMsgFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stdinFile -ErrorAction SilentlyContinue
  }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$slackChannel = $config.slack.channel
if ([string]::IsNullOrWhiteSpace($slackChannel)) { throw "Slack channel is missing in config.alerts.json (slack.channel)." }

$state = Read-State $StatePath
$nowUtc = [DateTimeOffset]::UtcNow

try {
foreach ($envKey in $Environments) {
  if ($null -eq $config.environments.$envKey) { throw "Environment '$envKey' not found in config.alerts.json" }
  $promUrl = $config.environments.$envKey.prom_url

  $api = Invoke-PrometheusAlerts $promUrl
  if ($api.status -ne "success") { throw "Prometheus API status != success for $envKey" }
  $alerts = @($api.data.alerts)

  # Track currently active alerts (both firing and pending)
  $currentActive = @{}
  $eligible = @()

  foreach ($a in $alerts) {
    if ($a.state -ne "firing" -and $a.state -ne "pending") { continue }
    $activeAtUtc = Parse-DateTimeOffset $a.activeAt
    if ($null -eq $activeAtUtc) { continue }
    $durMin = ($nowUtc - $activeAtUtc).TotalMinutes
    if ($durMin -lt $MinDurationMinutes) { continue }

    $labels = @{}
    foreach ($p in $a.labels.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value }
    $annotations = Get-StringHashtableFromPsObject $a.annotations
    $fp = Get-StableFingerprint -environment $envKey -labels $labels

    $currentActive[$fp] = @{
      labels = $labels
      annotations = $annotations
      activeAtUtc = $activeAtUtc
      alertState = [string]$a.state
      severity = ($labels["severity"] | ForEach-Object { $_.ToLowerInvariant() })
    }
    $eligible += $fp
  }

  $changesPending = New-Object System.Collections.Generic.List[string]
  $changesFiring = New-Object System.Collections.Generic.List[string]
  $changesResolved = New-Object System.Collections.Generic.List[string]
  $pendingDetails = New-Object System.Collections.Generic.List[object]
  $firingDetails = New-Object System.Collections.Generic.List[object]
  $resolvedDetails = New-Object System.Collections.Generic.List[object]

  foreach ($fp in $eligible) {
    if (-not $state["fingerprints"].ContainsKey($fp)) {
      $state["fingerprints"][$fp] = @{
        env = $envKey
        first_seen_utc = $nowUtc.UtcDateTime.ToString("o")
        last_seen_utc = $nowUtc.UtcDateTime.ToString("o")
        last_sent_pending_utc = $null
        last_sent_firing_utc = $null
        last_sent_resolved_utc = $null
        last_state = $currentActive[$fp].alertState
        active_at_utc = $currentActive[$fp].activeAtUtc.UtcDateTime.ToString("o")
        labels = $currentActive[$fp].labels
        annotations = $currentActive[$fp].annotations
      }
    } else {
      $state["fingerprints"][$fp]["last_seen_utc"] = $nowUtc.UtcDateTime.ToString("o")
      $state["fingerprints"][$fp]["active_at_utc"] = $currentActive[$fp].activeAtUtc.UtcDateTime.ToString("o")
      $state["fingerprints"][$fp]["labels"] = $currentActive[$fp].labels
      $state["fingerprints"][$fp]["annotations"] = $currentActive[$fp].annotations
    }

    $previousState = [string]$state["fingerprints"][$fp]["last_state"]
    $currentState = [string]$currentActive[$fp].alertState
    $shouldSend = $false
    if ($currentState -eq "pending") {
      $lastSentPending = Parse-DateTimeOffset $state["fingerprints"][$fp]["last_sent_pending_utc"]
      if ($null -eq $lastSentPending) { $shouldSend = $true }
      elseif (($nowUtc - $lastSentPending).TotalMinutes -ge $ReminderMinutes) { $shouldSend = $true }
      elseif ($previousState -eq "firing") { $shouldSend = $true }
    } elseif ($currentState -eq "firing") {
      $lastSentFiring = Parse-DateTimeOffset $state["fingerprints"][$fp]["last_sent_firing_utc"]
      if ($null -eq $lastSentFiring) { $shouldSend = $true }
      elseif (($nowUtc - $lastSentFiring).TotalMinutes -ge $ReminderMinutes) { $shouldSend = $true }
      elseif ($previousState -eq "pending") { $shouldSend = $true }
    }

    if ($shouldSend) {
      $item = $currentActive[$fp]
      $labels = $item.labels
      $annotations = $item.annotations
      $detail = $annotations["description"]
      if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $annotations["summary"] }
      if (-not [string]::IsNullOrWhiteSpace($annotations["summary"]) -and -not [string]::IsNullOrWhiteSpace($annotations["description"])) {
        $detail = "{0} | {1}" -f $annotations["description"], $annotations["summary"]
      }
      if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $labels["mountpoint"] }
      if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $labels["device"] }
      $event = [ordered]@{
        status = $currentState
        fingerprint = $fp
        env = $envKey
        alertname = $labels["alertname"]
        severity = $labels["severity"]
        server_name = $labels["server_name"]
        instance = $labels["instance"]
        job = $labels["job"]
        detail = $detail
        active_at_utc = $item.activeAtUtc.UtcDateTime.ToString("o")
        ended_at_utc = $null
        labels = $labels
        annotations = $annotations
      }
      if ($currentState -eq "pending") {
        $changesPending.Add($fp)
        $pendingDetails.Add($event)
      } else {
        $changesFiring.Add($fp)
        $firingDetails.Add($event)
      }
    }
    $state["fingerprints"][$fp]["last_state"] = $currentState
  }

  # Resolved detection: previously seen active fingerprints that are now missing
  foreach ($entry in @($state["fingerprints"].GetEnumerator())) {
    $fp = $entry.Key
    $rec = $entry.Value
    if ($rec.env -ne $envKey) { continue }
    $lastSeen = Parse-DateTimeOffset $rec.last_seen_utc
    $lastSentResolved = Parse-DateTimeOffset $rec.last_sent_resolved_utc

    if ($currentActive.ContainsKey($fp)) { continue }
    if ($null -eq $lastSeen) { continue }
    if (($nowUtc - $lastSeen).TotalMinutes -lt 4) { continue } # avoid false resolved (scheduler is 5m)
    if ($null -ne $lastSentResolved) { continue } # already announced resolved once

    # Resolve if pending or firing had been announced at least once
    $lastSentPending = Parse-DateTimeOffset $rec.last_sent_pending_utc
    $lastSentFiring = Parse-DateTimeOffset $rec.last_sent_firing_utc
    if ($null -eq $lastSentPending -and $null -eq $lastSentFiring) { continue }

    $changesResolved.Add($fp)
    $labels = @{}
    if ($rec.labels) {
      foreach ($k in $rec.labels.Keys) { $labels[$k] = [string]$rec.labels[$k] }
    }
    $annotations = @{}
    if ($rec.annotations) {
      foreach ($k in $rec.annotations.Keys) { $annotations[$k] = [string]$rec.annotations[$k] }
    }
    $activeAtUtc = Parse-DateTimeOffset $rec.active_at_utc
    if ($null -eq $activeAtUtc) { $activeAtUtc = $lastSeen }
    $detail = $annotations["description"]
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $annotations["summary"] }
    if (-not [string]::IsNullOrWhiteSpace($annotations["summary"]) -and -not [string]::IsNullOrWhiteSpace($annotations["description"])) {
      $detail = "{0} | {1}" -f $annotations["description"], $annotations["summary"]
    }
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $labels["mountpoint"] }
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $labels["device"] }
    $resolvedDetails.Add([ordered]@{
      status = "resolved"
      fingerprint = $fp
      env = $envKey
      alertname = $labels["alertname"]
      severity = $labels["severity"]
      server_name = $labels["server_name"]
      instance = $labels["instance"]
      job = $labels["job"]
      detail = $detail
      active_at_utc = $activeAtUtc.UtcDateTime.ToString("o")
      ended_at_utc = $nowUtc.UtcDateTime.ToString("o")
      labels = $labels
      annotations = $annotations
    })
    $state["fingerprints"][$fp] = $rec
  }

  if ($changesPending.Count -eq 0 -and $changesFiring.Count -eq 0 -and $changesResolved.Count -eq 0) {
    continue
  }

  Invoke-CodexAlertDispatch `
    -command $CodexCommand `
    -workingDir $PSScriptRoot `
    -timeoutSec $CodexTimeoutSec `
    -basePrompt $CodexPrompt `
    -environment $envKey `
    -slackChannel $slackChannel `
    -promUrl $promUrl `
    -pendingChanges $changesPending.Count `
    -firingChanges $changesFiring.Count `
    -resolvedChanges $changesResolved.Count `
    -pendingDetails $pendingDetails `
    -firingDetails $firingDetails `
    -resolvedDetails $resolvedDetails

  foreach ($fp in $changesPending) {
    $state["fingerprints"][$fp]["last_sent_pending_utc"] = $nowUtc.UtcDateTime.ToString("o")
  }
  foreach ($fp in $changesFiring) {
    $state["fingerprints"][$fp]["last_sent_firing_utc"] = $nowUtc.UtcDateTime.ToString("o")
  }
  foreach ($fp in $changesResolved) {
    $state["fingerprints"][$fp]["last_sent_resolved_utc"] = $nowUtc.UtcDateTime.ToString("o")
  }
}
} finally {
  Write-State -path $StatePath -state $state
}

