param(
  [string] $ConfigPath = (Join-Path $PSScriptRoot "config.alerts.json"),
  [string] $StatePath = (Join-Path $PSScriptRoot "state\\alerts-state.json"),
  [int] $MinDurationMinutes = 5,
  [int] $ReminderMinutes = 60,
  [string[]] $Environments = @("prod", "dev_test"),
  [string] $DotEnvPath = (Join-Path $PSScriptRoot ".env")
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

function Import-DotEnv([string] $path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $lines = Get-Content -LiteralPath $path -Encoding UTF8
  foreach ($line in $lines) {
    $lineText = if ($null -eq $line) { "" } else { [string]$line }
    $trim = $lineText.Trim()
    if ($trim.Length -eq 0) { continue }
    if ($trim.StartsWith("#")) { continue }
    $eq = $trim.IndexOf("=")
    if ($eq -lt 1) { continue }
    $key = $trim.Substring(0, $eq).Trim()
    $val = $trim.Substring($eq + 1).Trim()
    if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
      if ($val.Length -ge 2) { $val = $val.Substring(1, $val.Length - 2) }
    }
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    if (-not (Test-Path -Path ("Env:" + $key))) {
      Set-Item -Path ("Env:" + $key) -Value $val
    }
  }
}

function Get-JakartaNow {
  $tz = [TimeZoneInfo]::FindSystemTimeZoneById("SE Asia Standard Time")
  return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tz)
}

function Format-Jakarta([DateTimeOffset] $ts) {
  $tz = [TimeZoneInfo]::FindSystemTimeZoneById("SE Asia Standard Time")
  $jak = [TimeZoneInfo]::ConvertTime($ts, $tz)
  $dow = @("일","월","화","수","목","금","토")[[int]$jak.DayOfWeek]
  return "{0:yyyy-MM-dd}({1}) {0:HH:mm}" -f $jak, $dow
}

function Parse-DateTimeOffset([string] $value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
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

function Slack-PostMessage([string] $token, [string] $channel, [string] $text) {
  $uri = "https://slack.com/api/chat.postMessage"
  $body = @{
    channel = $channel
    text    = $text
    mrkdwn  = $true
  } | ConvertTo-Json -Compress

  $headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json; charset=utf-8"
  }

  # Windows PowerShell 5.1: send UTF-8 bytes explicitly to avoid mojibake in Slack.
  $utf8Body = [Text.Encoding]::UTF8.GetBytes($body)
  $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $utf8Body -TimeoutSec 20
  if (-not $resp.ok) {
    $msg = if ($resp.error) { $resp.error } else { "unknown_error" }
    throw "Slack API error: $msg"
  }
}

function Build-AlertLine(
  [string] $emoji,
  [hashtable] $labels,
  [DateTimeOffset] $activeAtUtc,
  [DateTimeOffset] $nowUtc,
  [string] $fp,
  [bool] $isResolved,
  $endedAtUtc = $null
) {
  $alertname = $labels["alertname"]
  $serverName = $labels["server_name"]
  $instance = $labels["instance"]
  $job = $labels["job"]
  $severity = $labels["severity"]
  $severityText = if ($severity) { $severity } else { "unknown" }

  $targetParts = @()
  if ($serverName) { $targetParts += $serverName }
  if ($instance) { $targetParts += ("``{0}``" -f $instance) }
  if ($job) { $targetParts += ("job ``{0}``" -f $job) }
  $target = if ($targetParts.Count -gt 0) { $targetParts -join " | " } else { "target_unknown" }

  $durMin = [Math]::Floor(($nowUtc - $activeAtUtc).TotalMinutes)
  if ($durMin -lt 0) { $durMin = 0 }

  if ($isResolved) {
    $endUtc = if ($null -eq $endedAtUtc) { $nowUtc } else { [DateTimeOffset]$endedAtUtc }
    $startJak = Format-Jakarta $activeAtUtc
    $endJak = Format-Jakarta $endUtc
    $fpCode = ("fp ``{0}``" -f $fp)
    return "- ✅ *$alertname* | $target | $severityText | ${durMin}분 | $startJak~$endJak | $fpCode"
  }

  $startJak = Format-Jakarta $activeAtUtc
  $fpCode = ("fp ``{0}``" -f $fp)
  return "- $emoji *$alertname* | $target | $severityText | ${durMin}분 | $startJak~현재 | $fpCode"
}

function Severity-Emoji([string] $sev) {
  switch ($sev) {
    "critical" { return "🛑" }
    "warning" { return "⚠️" }
    default { return "ℹ️" }
  }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$slackChannel = $config.slack.channel
if ([string]::IsNullOrWhiteSpace($env:SLACK_BOT_TOKEN)) {
  Import-DotEnv -path $DotEnvPath
}
$token = $env:SLACK_BOT_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { throw "SLACK_BOT_TOKEN env var is required." }
if ([string]::IsNullOrWhiteSpace($slackChannel)) { throw "Slack channel is missing in config.alerts.json (slack.channel)." }

$state = Read-State $StatePath
$nowUtc = [DateTimeOffset]::UtcNow

foreach ($envKey in $Environments) {
  if ($null -eq $config.environments.$envKey) { throw "Environment '$envKey' not found in config.alerts.json" }
  $promUrl = $config.environments.$envKey.prom_url

  $api = Invoke-PrometheusAlerts $promUrl
  if ($api.status -ne "success") { throw "Prometheus API status != success for $envKey" }
  $alerts = @($api.data.alerts)

  $currentFiring = @{}
  $eligible = @()

  foreach ($a in $alerts) {
    if ($a.state -ne "firing") { continue }
    $activeAtUtc = Parse-DateTimeOffset $a.activeAt
    if ($null -eq $activeAtUtc) { continue }
    $durMin = ($nowUtc - $activeAtUtc).TotalMinutes
    if ($durMin -lt $MinDurationMinutes) { continue }

    $labels = @{}
    foreach ($p in $a.labels.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value }
    $fp = Get-StableFingerprint -environment $envKey -labels $labels

    $currentFiring[$fp] = @{
      labels = $labels
      activeAtUtc = $activeAtUtc
      severity = ($labels["severity"] | ForEach-Object { $_.ToLowerInvariant() })
    }
    $eligible += $fp
  }

  $changesFiring = New-Object System.Collections.Generic.List[string]
  $changesResolved = New-Object System.Collections.Generic.List[string]

  foreach ($fp in $eligible) {
    if (-not $state["fingerprints"].ContainsKey($fp)) {
      $state["fingerprints"][$fp] = @{
        env = $envKey
        first_seen_utc = $nowUtc.UtcDateTime.ToString("o")
        last_seen_utc = $nowUtc.UtcDateTime.ToString("o")
        last_sent_firing_utc = $null
        last_sent_resolved_utc = $null
        active_at_utc = $currentFiring[$fp].activeAtUtc.UtcDateTime.ToString("o")
        labels = $currentFiring[$fp].labels
      }
    } else {
      $state["fingerprints"][$fp]["last_seen_utc"] = $nowUtc.UtcDateTime.ToString("o")
      $state["fingerprints"][$fp]["active_at_utc"] = $currentFiring[$fp].activeAtUtc.UtcDateTime.ToString("o")
      $state["fingerprints"][$fp]["labels"] = $currentFiring[$fp].labels
    }

    $lastSentFiring = Parse-DateTimeOffset $state["fingerprints"][$fp]["last_sent_firing_utc"]
    $shouldSend = $false
    if ($null -eq $lastSentFiring) { $shouldSend = $true }
    elseif (($nowUtc - $lastSentFiring).TotalMinutes -ge $ReminderMinutes) { $shouldSend = $true }

    if ($shouldSend) {
      $item = $currentFiring[$fp]
      $emoji = Severity-Emoji $item.severity
      $changesFiring.Add((Build-AlertLine -emoji $emoji -labels $item.labels -activeAtUtc $item.activeAtUtc -nowUtc $nowUtc -fp $fp -isResolved:$false))
      $state["fingerprints"][$fp]["last_sent_firing_utc"] = $nowUtc.UtcDateTime.ToString("o")
    }
  }

  # Resolved detection: previously seen firing fingerprints that are now missing
  foreach ($entry in @($state["fingerprints"].GetEnumerator())) {
    $fp = $entry.Key
    $rec = $entry.Value
    if ($rec.env -ne $envKey) { continue }
    $lastSeen = Parse-DateTimeOffset $rec.last_seen_utc
    $lastSentResolved = Parse-DateTimeOffset $rec.last_sent_resolved_utc

    if ($currentFiring.ContainsKey($fp)) { continue }
    if ($null -eq $lastSeen) { continue }
    if (($nowUtc - $lastSeen).TotalMinutes -lt 4) { continue } # avoid false resolved (scheduler is 5m)
    if ($null -ne $lastSentResolved) { continue } # already announced resolved once

    # Only resolve if it had been announced as firing at least once
    $lastSentFiring = Parse-DateTimeOffset $rec.last_sent_firing_utc
    if ($null -eq $lastSentFiring) { continue }

    $labels = @{}
    if ($rec.labels) {
      foreach ($k in $rec.labels.Keys) { $labels[$k] = [string]$rec.labels[$k] }
    }
    $activeAtUtc = Parse-DateTimeOffset $rec.active_at_utc
    if ($null -eq $activeAtUtc) { $activeAtUtc = $lastSeen }
    $emoji = Severity-Emoji (($labels["severity"] | ForEach-Object { $_.ToLowerInvariant() }))
    $changesResolved.Add((Build-AlertLine -emoji $emoji -labels $labels -activeAtUtc $activeAtUtc -nowUtc $nowUtc -fp $fp -isResolved:$true -endedAtUtc $nowUtc))
    $rec["last_sent_resolved_utc"] = $nowUtc.UtcDateTime.ToString("o")
    $state["fingerprints"][$fp] = $rec
  }

  if ($changesFiring.Count -eq 0 -and $changesResolved.Count -eq 0) {
    continue
  }

  # Build summary counts (based on current firing eligible set)
  $crit = 0
  $warn = 0
  foreach ($fp in $eligible) {
    $sev = $currentFiring[$fp].severity
    if ($sev -eq "critical") { $crit++ }
    elseif ($sev -eq "warning") { $warn++ }
  }

  $title = "🚨 알람 알림 | $envKey | $(Format-Jakarta $nowUtc) (Jakarta)"

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($title)
  $lines.Add("📌 요약")
  $lines.Add("- 🛑 Critical $crit" + "건 | ⚠️ Warning $warn" + "건 | 🟢 Resolved " + $changesResolved.Count + "건")
  $lines.Add("🧾 변경사항")

  if ($changesFiring.Count -gt 0) {
    $more = if ($changesFiring.Count -gt 3) { " (+ " + ($changesFiring.Count - 3) + "건)" } else { "" }
    $lines.Add("- 🔴 Firing (신규/리마인드) " + ([Math]::Min(3, $changesFiring.Count)) + "/" + $changesFiring.Count + "건" + $more)
    $top = $changesFiring | Select-Object -First 3
    foreach ($l in $top) { $lines.Add("  " + $l) }
  } else {
    $lines.Add("- 🔴 Firing (신규/리마인드) 0건")
  }

  if ($changesResolved.Count -gt 0) {
    $morer = if ($changesResolved.Count -gt 3) { " (+ " + ($changesResolved.Count - 3) + "건)" } else { "" }
    $lines.Add("- 🟢 Resolved " + ([Math]::Min(3, $changesResolved.Count)) + "/" + $changesResolved.Count + "건" + $morer)
    $topr = $changesResolved | Select-Object -First 3
    foreach ($l in $topr) { $lines.Add("  " + $l) }
  } else {
    $lines.Add("- 🟢 Resolved 0건")
  }

  $lines.Add("✅ 다음")
  $lines.Add("- `up{job=...}`/`up{instance=...}` 로 실제 unreachable 확인")
  $lines.Add("- 대상 서버의 `9100`(node_exporter) 리슨/프로세스/방화벽 확인")

  $text = ($lines -join "`n")
  Slack-PostMessage -token $token -channel $slackChannel -text $text
}

Write-State -path $StatePath -state $state
