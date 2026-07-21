param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
  [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "data\codex-token-usage-data.js"),
  [string]$CachePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "data\codex-token-usage-cache.json")
)

$ErrorActionPreference = "Stop"
$exportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$exportTimingCheckpoint = [double]0
$exportTimings = [ordered]@{}

function Get-Int64Value($Value) {
  if ($null -eq $Value) { return [int64]0 }
  return [int64]$Value
}

function Get-DoubleValue($Value) {
  if ($null -eq $Value) { return $null }
  return [double]$Value
}

function Test-ObjectMember($Value, [string]$Name) {
  if ($null -eq $Value) { return $false }
  if ($Value -is [System.Collections.IDictionary]) {
    return $Value.Contains($Name)
  }
  return $null -ne $Value.PSObject.Properties[$Name]
}

function Parse-DateTimeOffset($Value) {
  if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }

  try {
    return [datetimeoffset]::Parse(
      [string]$Value,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal
    )
  } catch {
    return $null
  }
}

function Convert-ToIsoUtc($Value) {
  if ($null -eq $Value) { return $null }
  return $Value.ToUniversalTime().ToString("o")
}

function Convert-ToLocalDateKey($Value) {
  if ($null -eq $Value) { return $null }
  return $Value.ToLocalTime().ToString("yyyy-MM-dd")
}

function Convert-ToLocalHourValue($Value) {
  if ($null -eq $Value) { return $null }
  return [int]$Value.ToLocalTime().Hour
}

function Convert-ToMinuteFloor($Value) {
  if ($null -eq $Value) { return $null }
  return [datetimeoffset]::new(
    $Value.Year,
    $Value.Month,
    $Value.Day,
    $Value.Hour,
    $Value.Minute,
    0,
    $Value.Offset
  )
}

function Find-LastTokenEventIndexOnOrBefore($Ticks, [long]$AtTicks) {
  if ($null -eq $Ticks -or $Ticks.Count -eq 0) { return -1 }

  $low = 0
  $high = $Ticks.Count - 1
  $result = -1

  while ($low -le $high) {
    $mid = [int][Math]::Floor(($low + $high) / 2)
    if ($Ticks[$mid] -le $AtTicks) {
      $result = $mid
      $low = $mid + 1
    } else {
      $high = $mid - 1
    }
  }

  return $result
}

function New-TokenEventPrefixIndex($Events) {
  [object[]]$sourceEvents = $Events.ToArray()
  $totalsByTick = @{}
  foreach ($event in $sourceEvents) {
    $eventTicks = Get-Int64Value $event.atTicks
    if ($eventTicks -le 0 -and $null -ne $event.at) {
      $eventTicks = ([datetimeoffset]$event.at).UtcDateTime.Ticks
    }
    if ($eventTicks -le 0) { continue }
    if (-not $totalsByTick.ContainsKey($eventTicks)) {
      $totalsByTick[$eventTicks] = [int64]0
    }
    $totalsByTick[$eventTicks] += Get-Int64Value $event.totalTokens
  }

  [long[]]$sortedTicks = @($totalsByTick.Keys)
  [Array]::Sort($sortedTicks)
  $ticks = New-Object "System.Collections.Generic.List[long]"
  $totals = New-Object "System.Collections.Generic.List[int64]"
  $runningTotal = [int64]0

  foreach ($eventTicks in $sortedTicks) {
    $runningTotal += Get-Int64Value $totalsByTick[$eventTicks]
    $ticks.Add($eventTicks) | Out-Null
    $totals.Add($runningTotal) | Out-Null
  }

  return [pscustomobject]@{
    Ticks = $ticks
    Totals = $totals
  }
}

function Get-TokenEventWindowTotal($PrefixIndex, [datetimeoffset]$StartExclusive, [datetimeoffset]$EndInclusive) {
  if ($null -eq $PrefixIndex -or $PrefixIndex.Ticks.Count -eq 0) { return [int64]0 }
  if ($EndInclusive -le $StartExclusive) { return [int64]0 }

  $endIndex = Find-LastTokenEventIndexOnOrBefore $PrefixIndex.Ticks $EndInclusive.UtcDateTime.Ticks
  if ($endIndex -lt 0) { return [int64]0 }

  $startIndex = Find-LastTokenEventIndexOnOrBefore $PrefixIndex.Ticks $StartExclusive.UtcDateTime.Ticks
  $beforeStart = if ($startIndex -ge 0) { Get-Int64Value $PrefixIndex.Totals[$startIndex] } else { [int64]0 }
  return (Get-Int64Value $PrefixIndex.Totals[$endIndex]) - $beforeStart
}

function Find-WeeklyWindowIndex($StartTicks, $EndTicks, [long]$EventTicks) {
  $low = 0
  $high = $StartTicks.Count - 1
  $candidateIndex = -1

  while ($low -le $high) {
    $mid = [int][Math]::Floor(($low + $high) / 2)
    if ($StartTicks[$mid] -lt $EventTicks) {
      $candidateIndex = $mid
      $low = $mid + 1
    } else {
      $high = $mid - 1
    }
  }

  for ($index = $candidateIndex; $index -ge 0; $index -= 1) {
    if ($EventTicks -le $EndTicks[$index]) { return $index }
  }
  return -1
}

function Convert-UnixSecondsToIsoUtc($Value) {
  if ($null -eq $Value) { return $null }

  try {
    return [datetimeoffset]::FromUnixTimeSeconds([int64]$Value).ToUniversalTime().ToString("o")
  } catch {
    return $null
  }
}

function Read-SharedUtf8Lines($Path) {
  $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)

  try {
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
    try {
      while ($null -ne ($line = $reader.ReadLine())) {
        $line
      }
    } finally {
      $reader.Dispose()
    }
  } finally {
    if ($stream) { $stream.Dispose() }
  }
}

function New-UsageBucket {
  return [ordered]@{
    inputTokens = [int64]0
    cachedInputTokens = [int64]0
    outputTokens = [int64]0
    reasoningOutputTokens = [int64]0
    otherTokens = [int64]0
    totalTokens = [int64]0
  }
}

function Add-UsageToBucket($Bucket, $Usage) {
  if ($null -eq $Usage) { return }

  $inputTokens = Get-Int64Value $Usage.input_tokens
  $outputTokens = Get-Int64Value $Usage.output_tokens
  $totalTokens = Get-Int64Value $Usage.total_tokens
  $otherTokens = $totalTokens - $inputTokens - $outputTokens
  if ($otherTokens -lt 0) { $otherTokens = 0 }

  $Bucket.inputTokens += $inputTokens
  $Bucket.cachedInputTokens += Get-Int64Value $Usage.cached_input_tokens
  $Bucket.outputTokens += $outputTokens
  $Bucket.reasoningOutputTokens += Get-Int64Value $Usage.reasoning_output_tokens
  $Bucket.otherTokens += $otherTokens
  $Bucket.totalTokens += $totalTokens
}

function Add-CachedUsageToBucket($Bucket, $Usage) {
  if ($null -eq $Usage) { return }

  $Bucket.inputTokens += Get-Int64Value $Usage.inputTokens
  $Bucket.cachedInputTokens += Get-Int64Value $Usage.cachedInputTokens
  $Bucket.outputTokens += Get-Int64Value $Usage.outputTokens
  $Bucket.reasoningOutputTokens += Get-Int64Value $Usage.reasoningOutputTokens
  $Bucket.otherTokens += Get-Int64Value $Usage.otherTokens
  $Bucket.totalTokens += Get-Int64Value $Usage.totalTokens
}

function Copy-Usage($Usage) {
  $bucket = New-UsageBucket
  Add-UsageToBucket $bucket $Usage
  return $bucket
}

function Convert-RateLimitWindow($Window) {
  if ($null -eq $Window) { return $null }

  $usedPercent = Get-DoubleValue $Window.used_percent
  return [ordered]@{
    usedPercent = $usedPercent
    remainingPercent = if ($null -eq $usedPercent) { $null } else { [Math]::Max(0, 100 - $usedPercent) }
    windowMinutes = if ($null -eq $Window.window_minutes) { $null } else { [int]$Window.window_minutes }
    resetsAt = Convert-UnixSecondsToIsoUtc $Window.resets_at
  }
}

function Convert-RateLimits($RateLimits, $Timestamp) {
  if ($null -eq $RateLimits) { return $null }

  $primary = Convert-RateLimitWindow $RateLimits.primary
  $secondary = Convert-RateLimitWindow $RateLimits.secondary
  $individual = Convert-RateLimitWindow $RateLimits.individual_limit
  $weekly = @(
    @($primary, $secondary, $individual) |
      Where-Object { $_ -and $_.windowMinutes -and [int]$_.windowMinutes -ge 10080 } |
      Sort-Object @{Expression = { [int]$_.windowMinutes }; Descending = $true} |
      Select-Object -First 1
  )

  return [ordered]@{
    observedAt = Convert-ToIsoUtc $Timestamp
    limitId = if ($null -eq $RateLimits.limit_id) { $null } else { [string]$RateLimits.limit_id }
    limitName = if ($null -eq $RateLimits.limit_name) { $null } else { [string]$RateLimits.limit_name }
    planType = if ($null -eq $RateLimits.plan_type) { $null } else { [string]$RateLimits.plan_type }
    primary = $primary
    secondary = $secondary
    individual = $individual
    weekly = if ($weekly.Count) { $weekly[0] } else { $null }
    reachedType = if ($null -eq $RateLimits.rate_limit_reached_type) { $null } else { [string]$RateLimits.rate_limit_reached_type }
  }
}

function Get-ThreadIndex($CodexHomePath) {
  $indexPath = Join-Path $CodexHomePath "session_index.jsonl"
  $index = @{}

  if (-not (Test-Path -LiteralPath $indexPath)) { return $index }

  foreach ($line in (Read-SharedUtf8Lines $indexPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
      $item = $line | ConvertFrom-Json
      if ($item.id) {
        $index[[string]$item.id] = [ordered]@{
          title = if ($item.thread_name) { [string]$item.thread_name } else { [string]$item.id }
          updatedAt = if ($item.updated_at) { [string]$item.updated_at } else { $null }
        }
      }
    } catch {
      continue
    }
  }

  return $index
}

function Get-SessionIdFromFileName($FileName) {
  if ($FileName -match "rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<id>[0-9a-f-]{36})\.jsonl$") {
    return $Matches.id
  }

  return [IO.Path]::GetFileNameWithoutExtension($FileName)
}

function Get-ProjectName($Cwd) {
  if ([string]::IsNullOrWhiteSpace($Cwd)) { return "Без папки" }

  $trimmed = ([string]$Cwd).TrimEnd("\", "/")
  $leaf = Split-Path -Leaf $trimmed

  if ([string]::IsNullOrWhiteSpace($leaf)) { return $trimmed }
  return $leaf
}

function New-DailyBucket($DateKey) {
  return [ordered]@{
    date = $DateKey
    inputTokens = [int64]0
    cachedInputTokens = [int64]0
    outputTokens = [int64]0
    reasoningOutputTokens = [int64]0
    otherTokens = [int64]0
    totalTokens = [int64]0
    turns = [int]0
    sessions = New-Object "System.Collections.Generic.HashSet[string]"
  }
}

function New-HourlyBucket($DateKey, $HourValue, $ProjectName) {
  return [ordered]@{
    date = $DateKey
    hour = [int]$HourValue
    project = $ProjectName
    inputTokens = [int64]0
    cachedInputTokens = [int64]0
    outputTokens = [int64]0
    reasoningOutputTokens = [int64]0
    otherTokens = [int64]0
    totalTokens = [int64]0
    turns = [int]0
    sessions = New-Object "System.Collections.Generic.HashSet[string]"
  }
}

function New-SessionDayBucket($DateKey, $SessionId, $ProjectName, $Cwd) {
  return [ordered]@{
    date = $DateKey
    sessionId = $SessionId
    project = $ProjectName
    cwd = if ($Cwd) { [string]$Cwd } else { $null }
    inputTokens = [int64]0
    cachedInputTokens = [int64]0
    outputTokens = [int64]0
    reasoningOutputTokens = [int64]0
    otherTokens = [int64]0
    totalTokens = [int64]0
    turns = [int]0
  }
}

function New-SessionHourBucket($DateKey, $HourValue, $SessionId, $ProjectName, $Cwd) {
  return [ordered]@{
    date = $DateKey
    hour = [int]$HourValue
    sessionId = $SessionId
    project = $ProjectName
    cwd = if ($Cwd) { [string]$Cwd } else { $null }
    inputTokens = [int64]0
    cachedInputTokens = [int64]0
    outputTokens = [int64]0
    reasoningOutputTokens = [int64]0
    otherTokens = [int64]0
    totalTokens = [int64]0
    turns = [int]0
  }
}

function Get-SourceName($FullName, $ActiveSessionsPath, $ArchivedSessionsPath) {
  if ($ActiveSessionsPath -and $FullName.StartsWith($ActiveSessionsPath, [StringComparison]::OrdinalIgnoreCase)) {
    return "sessions"
  }

  if ($ArchivedSessionsPath -and $FullName.StartsWith($ArchivedSessionsPath, [StringComparison]::OrdinalIgnoreCase)) {
    return "archived_sessions"
  }

  return "unknown"
}

function Read-SessionUsageCacheRecord($File) {
  $sessionId = Get-SessionIdFromFileName $File.Name
  $cwd = $null
  $originator = $null
  $cliVersion = $null
  $modelProvider = $null
  $model = $null
  $contextWindow = $null
  $startAt = $null
  $endAt = $null
  $latestTokenEventAt = $null
  $turnCount = 0
  $tokenEventCount = 0
  $sumLastUsage = New-UsageBucket
  $lastTotalUsage = New-UsageBucket
  $sessionRateLimits = $null
  $cachedTokenEvents = New-Object "System.Collections.Generic.List[object]"
  $cachedRateLimitEvents = @{}
  $stream = $null
  $reader = $null
  $parsedLength = [int64]$File.Length
  $parsedLastWriteUtcTicks = [int64]$File.LastWriteTimeUtc.Ticks

  try {
    $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)

    while ($null -ne ($line = $reader.ReadLine())) {
      $linePrefix = if ($line.Length -gt 320) { $line.Substring(0, 320) } else { $line }
      if (-not (
        $linePrefix.Contains('"type":"session_meta"') -or
        $linePrefix.Contains('"type":"turn_context"') -or
        $linePrefix.Contains('"type":"token_count"')
      )) {
        continue
      }

      try {
        $entry = $line | ConvertFrom-Json
      } catch {
        continue
      }

      $entryAt = Parse-DateTimeOffset $entry.timestamp
      if ($null -ne $entryAt) {
        if ($null -eq $startAt -or $entryAt -lt $startAt) { $startAt = $entryAt }
        if ($null -eq $endAt -or $entryAt -gt $endAt) { $endAt = $entryAt }
      }

      if ($entry.type -eq "session_meta") {
        $payload = $entry.payload
        if ($payload.id) { $sessionId = [string]$payload.id }
        if ($payload.cwd) { $cwd = [string]$payload.cwd }
        if ($payload.originator) { $originator = [string]$payload.originator }
        if ($payload.cli_version) { $cliVersion = [string]$payload.cli_version }
        if ($payload.model_provider) { $modelProvider = [string]$payload.model_provider }
        if ($payload.model) { $model = [string]$payload.model }
        continue
      }

      if ($entry.type -eq "turn_context") {
        $payload = $entry.payload
        if ($payload.cwd) { $cwd = [string]$payload.cwd }
        if ($payload.model) { $model = [string]$payload.model }
        continue
      }

      if ($entry.payload.type -ne "token_count") { continue }

      $tokenEventCount += 1
      $turnCount += 1
      $info = $entry.payload.info
      if ($entryAt -and ($null -eq $latestTokenEventAt -or $entryAt -gt $latestTokenEventAt)) {
        $latestTokenEventAt = $entryAt
      }

      if ($info.model_context_window) {
        $contextWindow = Get-Int64Value $info.model_context_window
      }

      if ($info.last_token_usage) {
        $normalizedUsage = Copy-Usage $info.last_token_usage
        Add-CachedUsageToBucket $sumLastUsage $normalizedUsage

        if ($entryAt) {
          $cachedTokenEvents.Add([ordered]@{
            at = Convert-ToIsoUtc $entryAt
            project = Get-ProjectName $cwd
            cwd = if ($cwd) { [string]$cwd } else { $null }
            inputTokens = Get-Int64Value $normalizedUsage.inputTokens
            cachedInputTokens = Get-Int64Value $normalizedUsage.cachedInputTokens
            outputTokens = Get-Int64Value $normalizedUsage.outputTokens
            reasoningOutputTokens = Get-Int64Value $normalizedUsage.reasoningOutputTokens
            otherTokens = Get-Int64Value $normalizedUsage.otherTokens
            totalTokens = Get-Int64Value $normalizedUsage.totalTokens
          }) | Out-Null
        }
      }

      if ($info.total_token_usage) {
        $lastTotalUsage = Copy-Usage $info.total_token_usage
      }

      $rateLimits = if ($entry.rate_limits) { $entry.rate_limits } elseif ($entry.payload.rate_limits) { $entry.payload.rate_limits } else { $null }
      if (-not $rateLimits) { continue }

      $sessionRateLimits = Convert-RateLimits $rateLimits $entryAt
      $weekly = $sessionRateLimits.weekly
      if (-not $entryAt -or -not $weekly -or $null -eq $weekly.usedPercent) { continue }

      $resetAt = Parse-DateTimeOffset $weekly.resetsAt
      $normalizedResetAt = Convert-ToMinuteFloor $resetAt
      $windowKey = if ($normalizedResetAt) {
        "$(Convert-ToIsoUtc $normalizedResetAt)|$($weekly.windowMinutes)"
      } else {
        "observed:$($entryAt.ToString('yyyy-MM-dd'))|$($weekly.windowMinutes)"
      }
      $candidate = [ordered]@{
        at = Convert-ToIsoUtc $entryAt
        rateLimits = $sessionRateLimits
      }
      $existing = $cachedRateLimitEvents[$windowKey]
      $usedPercent = Get-DoubleValue $weekly.usedPercent
      $existingUsedPercent = if ($existing) { Get-DoubleValue $existing.rateLimits.weekly.usedPercent } else { $null }
      $existingAt = if ($existing) { Parse-DateTimeOffset $existing.at } else { $null }

      if (
        -not $existing -or
        $usedPercent -gt $existingUsedPercent -or
        ($usedPercent -eq $existingUsedPercent -and $entryAt -gt $existingAt)
      ) {
        $cachedRateLimitEvents[$windowKey] = $candidate
      }
    }

    $parsedLength = [int64]$stream.Position
    $parsedFileState = Get-Item -LiteralPath $File.FullName
    $parsedLastWriteUtcTicks = [int64]$parsedFileState.LastWriteTimeUtc.Ticks
  } finally {
    if ($reader) {
      $reader.Dispose()
    } elseif ($stream) {
      $stream.Dispose()
    }
  }

  $usage = $sumLastUsage
  if ((Get-Int64Value $usage.totalTokens) -eq 0 -and (Get-Int64Value $lastTotalUsage.totalTokens) -gt 0) {
    $usage = $lastTotalUsage
  }

  return [ordered]@{
    path = [string]$File.FullName
    length = $parsedLength
    lastWriteUtcTicks = $parsedLastWriteUtcTicks
    sessionId = [string]$sessionId
    cwd = if ($cwd) { [string]$cwd } else { $null }
    originator = if ($originator) { [string]$originator } else { $null }
    cliVersion = if ($cliVersion) { [string]$cliVersion } else { $null }
    modelProvider = if ($modelProvider) { [string]$modelProvider } else { $null }
    model = if ($model) { [string]$model } else { $null }
    contextWindow = if ($contextWindow) { [int64]$contextWindow } else { $null }
    startAt = Convert-ToIsoUtc $startAt
    endAt = Convert-ToIsoUtc $endAt
    latestTokenEventAt = Convert-ToIsoUtc $latestTokenEventAt
    turns = [int]$turnCount
    tokenEventCount = [int]$tokenEventCount
    usage = $usage
    rateLimits = $sessionRateLimits
    tokenEvents = @($cachedTokenEvents.ToArray())
    rateLimitEvents = @($cachedRateLimitEvents.Values)
  }
}

function Test-SessionUsageCacheCanAppend($File, $Record) {
  if (-not $Record) { return $false }

  $cachedLength = Get-Int64Value $Record.length
  if ($cachedLength -le 0 -or [int64]$File.Length -le $cachedLength) { return $false }

  $stream = $null
  try {
    $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    [void]$stream.Seek($cachedLength - 1, [System.IO.SeekOrigin]::Begin)
    return $stream.ReadByte() -eq 10
  } catch {
    return $false
  } finally {
    if ($stream) { $stream.Dispose() }
  }
}

function Update-SessionUsageCacheRecord($File, $Record) {
  $cachedLength = Get-Int64Value $Record.length
  $targetLength = [int64]$File.Length
  $newByteCount = $targetLength - $cachedLength
  if ($newByteCount -le 0 -or $newByteCount -gt [int]::MaxValue) { return $null }

  $bytes = New-Object byte[] ([int]$newByteCount)
  $stream = $null
  $bytesRead = 0
  try {
    $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    [void]$stream.Seek($cachedLength, [System.IO.SeekOrigin]::Begin)
    while ($bytesRead -lt $bytes.Length) {
      $read = $stream.Read($bytes, $bytesRead, $bytes.Length - $bytesRead)
      if ($read -le 0) { break }
      $bytesRead += $read
    }
  } finally {
    if ($stream) { $stream.Dispose() }
  }

  $completeByteCount = $bytesRead
  while ($completeByteCount -gt 0 -and $bytes[$completeByteCount - 1] -ne 10) {
    $completeByteCount -= 1
  }
  if ($completeByteCount -le 0) { return $null }

  $sessionId = [string]$Record.sessionId
  $cwd = if ($Record.cwd) { [string]$Record.cwd } else { $null }
  $originator = if ($Record.originator) { [string]$Record.originator } else { $null }
  $cliVersion = if ($Record.cliVersion) { [string]$Record.cliVersion } else { $null }
  $modelProvider = if ($Record.modelProvider) { [string]$Record.modelProvider } else { $null }
  $model = if ($Record.model) { [string]$Record.model } else { $null }
  $contextWindow = if ($Record.contextWindow) { [int64]$Record.contextWindow } else { $null }
  $startAt = Parse-DateTimeOffset $Record.startAt
  $endAt = Parse-DateTimeOffset $Record.endAt
  $latestTokenEventAt = Parse-DateTimeOffset $Record.latestTokenEventAt
  $turnCount = [int]$Record.turns
  $tokenEventCount = [int]$Record.tokenEventCount
  $usage = New-UsageBucket
  Add-CachedUsageToBucket $usage $Record.usage
  $lastTotalUsage = $null
  $sessionRateLimits = $Record.rateLimits
  $recordAggregateVersion = if (Test-ObjectMember $Record "aggregateVersion") {
    [int]$Record.aggregateVersion
  } else {
    0
  }
  $cachedTokenEvents = New-Object "System.Collections.Generic.List[object]"
  $pendingAggregateEvents = New-Object "System.Collections.Generic.List[object]"
  if ($recordAggregateVersion -lt 2) {
    foreach ($cachedEvent in @($Record.tokenEvents)) { $cachedTokenEvents.Add($cachedEvent) | Out-Null }
  }
  $cachedRateLimitEvents = @{}
  foreach ($cachedRateLimitEvent in @($Record.rateLimitEvents)) {
    $weekly = $cachedRateLimitEvent.rateLimits.weekly
    if (-not $weekly) { continue }
    $resetAt = Parse-DateTimeOffset $weekly.resetsAt
    $normalizedResetAt = Convert-ToMinuteFloor $resetAt
    $eventAt = Parse-DateTimeOffset $cachedRateLimitEvent.at
    $windowKey = if ($normalizedResetAt) {
      "$(Convert-ToIsoUtc $normalizedResetAt)|$($weekly.windowMinutes)"
    } elseif ($eventAt) {
      "observed:$($eventAt.ToString('yyyy-MM-dd'))|$($weekly.windowMinutes)"
    } else {
      continue
    }
    $cachedRateLimitEvents[$windowKey] = $cachedRateLimitEvent
  }

  $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $completeByteCount)
  foreach ($lineValue in $text.Split([char]10)) {
    $line = $lineValue.TrimEnd([char]13)
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $linePrefix = if ($line.Length -gt 320) { $line.Substring(0, 320) } else { $line }
    if (-not (
      $linePrefix.Contains('"type":"session_meta"') -or
      $linePrefix.Contains('"type":"turn_context"') -or
      $linePrefix.Contains('"type":"token_count"')
    )) {
      continue
    }

    try {
      $entry = $line | ConvertFrom-Json
    } catch {
      continue
    }

    $entryAt = Parse-DateTimeOffset $entry.timestamp
    if ($entryAt) {
      if ($null -eq $startAt -or $entryAt -lt $startAt) { $startAt = $entryAt }
      if ($null -eq $endAt -or $entryAt -gt $endAt) { $endAt = $entryAt }
    }

    if ($entry.type -eq "session_meta") {
      $payload = $entry.payload
      if ($payload.id) { $sessionId = [string]$payload.id }
      if ($payload.cwd) { $cwd = [string]$payload.cwd }
      if ($payload.originator) { $originator = [string]$payload.originator }
      if ($payload.cli_version) { $cliVersion = [string]$payload.cli_version }
      if ($payload.model_provider) { $modelProvider = [string]$payload.model_provider }
      if ($payload.model) { $model = [string]$payload.model }
      continue
    }

    if ($entry.type -eq "turn_context") {
      $payload = $entry.payload
      if ($payload.cwd) { $cwd = [string]$payload.cwd }
      if ($payload.model) { $model = [string]$payload.model }
      continue
    }

    if ($entry.payload.type -ne "token_count") { continue }

    $tokenEventCount += 1
    $turnCount += 1
    $info = $entry.payload.info
    if ($entryAt -and ($null -eq $latestTokenEventAt -or $entryAt -gt $latestTokenEventAt)) {
      $latestTokenEventAt = $entryAt
    }
    if ($info.model_context_window) { $contextWindow = Get-Int64Value $info.model_context_window }

    if ($info.last_token_usage) {
      $normalizedUsage = Copy-Usage $info.last_token_usage
      Add-CachedUsageToBucket $usage $normalizedUsage
      if ($entryAt) {
        $cachedEvent = [ordered]@{
          at = Convert-ToIsoUtc $entryAt
          project = Get-ProjectName $cwd
          cwd = if ($cwd) { [string]$cwd } else { $null }
          inputTokens = Get-Int64Value $normalizedUsage.inputTokens
          cachedInputTokens = Get-Int64Value $normalizedUsage.cachedInputTokens
          outputTokens = Get-Int64Value $normalizedUsage.outputTokens
          reasoningOutputTokens = Get-Int64Value $normalizedUsage.reasoningOutputTokens
          otherTokens = Get-Int64Value $normalizedUsage.otherTokens
          totalTokens = Get-Int64Value $normalizedUsage.totalTokens
        }
        if ($recordAggregateVersion -ge 2) {
          $pendingAggregateEvents.Add($cachedEvent) | Out-Null
        } else {
          $cachedTokenEvents.Add($cachedEvent) | Out-Null
        }
      }
    }

    if ($info.total_token_usage) { $lastTotalUsage = Copy-Usage $info.total_token_usage }
    $rateLimits = if ($entry.rate_limits) { $entry.rate_limits } elseif ($entry.payload.rate_limits) { $entry.payload.rate_limits } else { $null }
    if (-not $rateLimits) { continue }

    $sessionRateLimits = Convert-RateLimits $rateLimits $entryAt
    $weekly = $sessionRateLimits.weekly
    if (-not $entryAt -or -not $weekly -or $null -eq $weekly.usedPercent) { continue }

    $resetAt = Parse-DateTimeOffset $weekly.resetsAt
    $normalizedResetAt = Convert-ToMinuteFloor $resetAt
    $windowKey = if ($normalizedResetAt) {
      "$(Convert-ToIsoUtc $normalizedResetAt)|$($weekly.windowMinutes)"
    } else {
      "observed:$($entryAt.ToString('yyyy-MM-dd'))|$($weekly.windowMinutes)"
    }
    $candidate = [ordered]@{ at = Convert-ToIsoUtc $entryAt; rateLimits = $sessionRateLimits }
    $existing = $cachedRateLimitEvents[$windowKey]
    $usedPercent = Get-DoubleValue $weekly.usedPercent
    $existingUsedPercent = if ($existing) { Get-DoubleValue $existing.rateLimits.weekly.usedPercent } else { $null }
    $existingAt = if ($existing) { Parse-DateTimeOffset $existing.at } else { $null }
    if (-not $existing -or $usedPercent -gt $existingUsedPercent -or ($usedPercent -eq $existingUsedPercent -and $entryAt -gt $existingAt)) {
      $cachedRateLimitEvents[$windowKey] = $candidate
    }
  }

  if ((Get-Int64Value $usage.totalTokens) -eq 0 -and $lastTotalUsage -and (Get-Int64Value $lastTotalUsage.totalTokens) -gt 0) {
    $usage = $lastTotalUsage
  }

  return [ordered]@{
    path = [string]$File.FullName
    length = [int64]($cachedLength + $completeByteCount)
    lastWriteUtcTicks = [int64]$File.LastWriteTimeUtc.Ticks
    sessionId = $sessionId
    cwd = $cwd
    originator = $originator
    cliVersion = $cliVersion
    modelProvider = $modelProvider
    model = $model
    contextWindow = $contextWindow
    startAt = Convert-ToIsoUtc $startAt
    endAt = Convert-ToIsoUtc $endAt
    latestTokenEventAt = Convert-ToIsoUtc $latestTokenEventAt
    turns = $turnCount
    tokenEventCount = $tokenEventCount
    usage = $usage
    rateLimits = $sessionRateLimits
    tokenEvents = @($cachedTokenEvents.ToArray())
    rateLimitEvents = @($cachedRateLimitEvents.Values)
    aggregateVersion = $recordAggregateVersion
    daily = if ($recordAggregateVersion -ge 2) { @($Record.daily) } else { @() }
    hourly = if ($recordAggregateVersion -ge 2) { @($Record.hourly) } else { @() }
    sessionDaily = if ($recordAggregateVersion -ge 2) { @($Record.sessionDaily) } else { @() }
    sessionHourly = if ($recordAggregateVersion -ge 2) { @($Record.sessionHourly) } else { @() }
    weeklyEvents = if ($recordAggregateVersion -ge 2) { @($Record.weeklyEvents) } else { @() }
    pendingAggregateEvents = @($pendingAggregateEvents.ToArray())
  }
}

function New-SessionUsageAggregateBucket($DateKey, $HourValue, $ProjectName, $Cwd) {
  return [ordered]@{
    date = [string]$DateKey
    hour = if ($null -eq $HourValue) { $null } else { [int]$HourValue }
    project = if ($ProjectName) { [string]$ProjectName } else { $null }
    cwd = if ($Cwd) { [string]$Cwd } else { $null }
    inputTokens = [int64]0
    cachedInputTokens = [int64]0
    outputTokens = [int64]0
    reasoningOutputTokens = [int64]0
    otherTokens = [int64]0
    totalTokens = [int64]0
    turns = [int]0
  }
}

function Add-SessionUsageAggregates($Record) {
  $aggregateVersion = if (Test-ObjectMember $Record "aggregateVersion") {
    [int]$Record.aggregateVersion
  } else {
    0
  }
  $hasExistingAggregates = $aggregateVersion -ge 2
  $hasPendingAggregateEvents = Test-ObjectMember $Record "pendingAggregateEvents"
  if ($aggregateVersion -eq 5 -and -not $hasPendingAggregateEvents) {
    return $Record
  }

  $separator = [string][char]31
  $daily = @{}
  $hourly = @{}
  $sessionDaily = @{}
  $sessionHourly = @{}
  $weeklyEvents = @{}

  if ($hasExistingAggregates) {
    foreach ($row in @($Record.daily)) {
      if ($row.date) { $daily[[string]$row.date] = $row }
    }
    foreach ($row in @($Record.hourly)) {
      if (-not $row.date) { continue }
      $projectName = if ($row.project) { [string]$row.project } else { "Без папки" }
      $key = "$($row.date)$separator$([int]$row.hour)$separator$projectName"
      $hourly[$key] = $row
    }
    foreach ($row in @($Record.sessionDaily)) {
      if (-not $row.date) { continue }
      $projectName = if ($row.project) { [string]$row.project } else { "Без папки" }
      $key = "$($row.date)$separator$projectName"
      $sessionDaily[$key] = $row
    }
    foreach ($row in @($Record.sessionHourly)) {
      if (-not $row.date) { continue }
      $projectName = if ($row.project) { [string]$row.project } else { "Без папки" }
      $key = "$($row.date)$separator$([int]$row.hour)$separator$projectName"
      $sessionHourly[$key] = $row
    }
    foreach ($row in @($Record.weeklyEvents)) {
      if (-not $row.at) { continue }
      $entryAt = if ((Test-ObjectMember $row "atUtcTicks") -and (Get-Int64Value $row.atUtcTicks) -gt 0) {
        [datetimeoffset]::new((Get-Int64Value $row.atUtcTicks), [timespan]::Zero)
      } else {
        Parse-DateTimeOffset $row.at
      }
      if (-not $entryAt) { continue }
      $minuteValue = Convert-ToMinuteFloor $entryAt
      $minuteAt = Convert-ToIsoUtc $minuteValue
      $projectName = if ($row.project) { [string]$row.project } else { "Без папки" }
      $key = "$minuteAt$separator$projectName"
      if (-not $weeklyEvents.ContainsKey($key)) {
        $weeklyEvents[$key] = [ordered]@{
          at = $minuteAt
          atUtcTicks = [int64]$minuteValue.UtcDateTime.Ticks
          date = Convert-ToLocalDateKey $minuteValue
          hour = Convert-ToLocalHourValue $minuteValue
          project = $projectName
          totalTokens = [int64]0
        }
      }
      $weeklyEvents[$key].totalTokens += Get-Int64Value $row.totalTokens
    }
  }

  $eventsToAggregate = if ($hasExistingAggregates) {
    if ($hasPendingAggregateEvents) { @($Record.pendingAggregateEvents) } else { @() }
  } else {
    @($Record.tokenEvents)
  }

  foreach ($event in $eventsToAggregate) {
    $entryAt = Parse-DateTimeOffset $event.at
    if (-not $entryAt) { continue }

    $dateKey = Convert-ToLocalDateKey $entryAt
    $hourValue = Convert-ToLocalHourValue $entryAt
    $projectName = if ($event.project) { [string]$event.project } else { "Без папки" }
    $eventCwd = if ($event.cwd) { [string]$event.cwd } elseif ($Record.cwd) { [string]$Record.cwd } else { $null }
    $weeklyMinuteValue = Convert-ToMinuteFloor $entryAt
    $weeklyEventAt = Convert-ToIsoUtc $weeklyMinuteValue
    $weeklyEventKey = "$weeklyEventAt$separator$projectName"
    if (-not $weeklyEvents.ContainsKey($weeklyEventKey)) {
      $weeklyEvents[$weeklyEventKey] = [ordered]@{
        at = $weeklyEventAt
        atUtcTicks = [int64]$weeklyMinuteValue.UtcDateTime.Ticks
        date = $dateKey
        hour = $hourValue
        project = $projectName
        totalTokens = [int64]0
      }
    }
    $weeklyEvents[$weeklyEventKey].totalTokens += Get-Int64Value $event.totalTokens

    if (-not $daily.ContainsKey($dateKey)) {
      $daily[$dateKey] = New-SessionUsageAggregateBucket $dateKey $null $null $null
    }
    Add-CachedUsageToBucket $daily[$dateKey] $event
    $daily[$dateKey].turns += 1

    $hourlyKey = "$dateKey$separator$hourValue$separator$projectName"
    if (-not $hourly.ContainsKey($hourlyKey)) {
      $hourly[$hourlyKey] = New-SessionUsageAggregateBucket $dateKey $hourValue $projectName $null
    }
    Add-CachedUsageToBucket $hourly[$hourlyKey] $event
    $hourly[$hourlyKey].turns += 1

    $sessionDayKey = "$dateKey$separator$projectName"
    if (-not $sessionDaily.ContainsKey($sessionDayKey)) {
      $sessionDaily[$sessionDayKey] = New-SessionUsageAggregateBucket $dateKey $null $projectName $eventCwd
    }
    Add-CachedUsageToBucket $sessionDaily[$sessionDayKey] $event
    $sessionDaily[$sessionDayKey].turns += 1

    $sessionHourKey = "$dateKey$separator$hourValue$separator$projectName"
    if (-not $sessionHourly.ContainsKey($sessionHourKey)) {
      $sessionHourly[$sessionHourKey] = New-SessionUsageAggregateBucket $dateKey $hourValue $projectName $eventCwd
    }
    Add-CachedUsageToBucket $sessionHourly[$sessionHourKey] $event
    $sessionHourly[$sessionHourKey].turns += 1
  }

  return [ordered]@{
    path = [string]$Record.path
    length = Get-Int64Value $Record.length
    lastWriteUtcTicks = Get-Int64Value $Record.lastWriteUtcTicks
    sessionId = [string]$Record.sessionId
    cwd = if ($Record.cwd) { [string]$Record.cwd } else { $null }
    originator = if ($Record.originator) { [string]$Record.originator } else { $null }
    cliVersion = if ($Record.cliVersion) { [string]$Record.cliVersion } else { $null }
    modelProvider = if ($Record.modelProvider) { [string]$Record.modelProvider } else { $null }
    model = if ($Record.model) { [string]$Record.model } else { $null }
    contextWindow = if ($Record.contextWindow) { [int64]$Record.contextWindow } else { $null }
    startAt = if ($Record.startAt) { [string]$Record.startAt } else { $null }
    endAt = if ($Record.endAt) { [string]$Record.endAt } else { $null }
    latestTokenEventAt = if ($Record.latestTokenEventAt) { [string]$Record.latestTokenEventAt } else { $null }
    turns = [int]$Record.turns
    tokenEventCount = [int]$Record.tokenEventCount
    usage = $Record.usage
    rateLimits = $Record.rateLimits
    tokenEvents = @()
    rateLimitEvents = @($Record.rateLimitEvents)
    aggregateVersion = 5
    daily = @($daily.Values | Sort-Object date)
    hourly = @($hourly.Values | Sort-Object date, hour, project)
    sessionDaily = @($sessionDaily.Values | Sort-Object date, project)
    sessionHourly = @($sessionHourly.Values | Sort-Object date, hour, project)
    weeklyEvents = @($weeklyEvents.Values | Sort-Object at, project)
  }
}

$threadIndex = Get-ThreadIndex $CodexHome
$activeSessionsPath = Join-Path $CodexHome "sessions"
$archivedSessionsPath = Join-Path $CodexHome "archived_sessions"
$sessionFiles = @()

if (Test-Path -LiteralPath $activeSessionsPath) {
  $sessionFiles += Get-ChildItem -LiteralPath $activeSessionsPath -Recurse -Filter "*.jsonl" -File
}

if (Test-Path -LiteralPath $archivedSessionsPath) {
  $sessionFiles += Get-ChildItem -LiteralPath $archivedSessionsPath -Recurse -Filter "*.jsonl" -File
}

$sessionRows = New-Object "System.Collections.Generic.List[object]"
$dailyBuckets = @{}
$hourlyBuckets = @{}
$sessionDayBuckets = @{}
$sessionHourBuckets = @{}
$bucketKeySeparator = [string][char]31
$latestRateLimits = $null
$latestRateLimitsAt = $null
$weeklyLimitBasisRateLimits = $null
$weeklyLimitBasisAt = $null
$tokenEventCount = 0
$latestTokenEventAt = $null
$tokenEvents = New-Object "System.Collections.Generic.List[object]"
$rateLimitEvents = New-Object "System.Collections.Generic.List[object]"
$cacheSchemaVersion = 1
$cachedRecordsByPath = @{}
$currentCacheRecords = New-Object "System.Collections.Generic.List[object]"
$cacheHits = 0
$cacheMisses = 0
$cacheAppends = 0

if (Test-Path -LiteralPath $CachePath) {
  try {
    $cachePayload = [System.IO.File]::ReadAllText($CachePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$cachePayload.schemaVersion -eq $cacheSchemaVersion) {
      foreach ($cachedRecord in @($cachePayload.files)) {
        if ($cachedRecord.path) {
          $cachedRecordsByPath[[string]$cachedRecord.path] = $cachedRecord
        }
      }
    }
  } catch {
    $cachedRecordsByPath = @{}
  }
}

$timingNow = $exportStopwatch.Elapsed.TotalSeconds
$exportTimings.discoveryAndCacheLoad = [Math]::Round($timingNow - $exportTimingCheckpoint, 2)
$exportTimingCheckpoint = $timingNow

foreach ($file in ($sessionFiles | Sort-Object FullName)) {
  $cacheRecord = $cachedRecordsByPath[[string]$file.FullName]
  $cacheMatches = (
    $cacheRecord -and
    (Get-Int64Value $cacheRecord.length) -eq [int64]$file.Length -and
    (Get-Int64Value $cacheRecord.lastWriteUtcTicks) -eq [int64]$file.LastWriteTimeUtc.Ticks
  )

  if ($cacheMatches) {
    $cacheHits += 1
  } else {
    $cacheMisses += 1
    $updatedCacheRecord = $null
    if (Test-SessionUsageCacheCanAppend $file $cacheRecord) {
      try {
        $updatedCacheRecord = Update-SessionUsageCacheRecord $file $cacheRecord
      } catch {
        $updatedCacheRecord = $null
      }
      if ($updatedCacheRecord) { $cacheAppends += 1 }
    }

    if ($updatedCacheRecord) {
      $cacheRecord = $updatedCacheRecord
    } else {
      try {
        $cacheRecord = Read-SessionUsageCacheRecord $file
      } catch {
        $cacheRecord = $null
      }
    }
  }

  if ($cacheRecord) {
    $cacheRecord = Add-SessionUsageAggregates $cacheRecord
    $currentCacheRecords.Add($cacheRecord) | Out-Null
    $sessionId = [string]$cacheRecord.sessionId
    $cwd = if ($cacheRecord.cwd) { [string]$cacheRecord.cwd } else { $null }
    $usage = $cacheRecord.usage
    $tokenEventCount += [int]$cacheRecord.tokenEventCount
    $recordLatestTokenEventAt = Parse-DateTimeOffset $cacheRecord.latestTokenEventAt
    if ($recordLatestTokenEventAt -and ($null -eq $latestTokenEventAt -or $recordLatestTokenEventAt -gt $latestTokenEventAt)) {
      $latestTokenEventAt = $recordLatestTokenEventAt
    }

    foreach ($cachedEvent in @($cacheRecord.weeklyEvents)) {
      $entryTicks = if (Test-ObjectMember $cachedEvent "atUtcTicks") {
        Get-Int64Value $cachedEvent.atUtcTicks
      } else {
        $parsedEventAt = Parse-DateTimeOffset $cachedEvent.at
        if ($parsedEventAt) { [int64]$parsedEventAt.UtcDateTime.Ticks } else { [int64]0 }
      }
      if ($entryTicks -le 0) { continue }

      $projectName = if ($cachedEvent.project) { [string]$cachedEvent.project } else { "Без папки" }
      $tokenEvents.Add([ordered]@{
        atTicks = $entryTicks
        date = if ($cachedEvent.date) { [string]$cachedEvent.date } else { $null }
        hour = if ($null -ne $cachedEvent.hour) { [int]$cachedEvent.hour } else { $null }
        project = $projectName
        totalTokens = Get-Int64Value $cachedEvent.totalTokens
      }) | Out-Null
    }

    foreach ($cachedDaily in @($cacheRecord.daily)) {
      $dateKey = [string]$cachedDaily.date
      if (-not $dailyBuckets.ContainsKey($dateKey)) {
        $dailyBuckets[$dateKey] = New-DailyBucket $dateKey
      }
      $dailyBucket = $dailyBuckets[$dateKey]
      Add-CachedUsageToBucket $dailyBucket $cachedDaily
      $dailyBucket.turns += [int]$cachedDaily.turns
      [void]$dailyBucket.sessions.Add($sessionId)
    }

    foreach ($cachedHourly in @($cacheRecord.hourly)) {
      $dateKey = [string]$cachedHourly.date
      $hourValue = [int]$cachedHourly.hour
      $projectName = if ($cachedHourly.project) { [string]$cachedHourly.project } else { "Без папки" }
      $hourlyKey = "$dateKey$bucketKeySeparator$hourValue$bucketKeySeparator$projectName"
      if (-not $hourlyBuckets.ContainsKey($hourlyKey)) {
        $hourlyBuckets[$hourlyKey] = New-HourlyBucket $dateKey $hourValue $projectName
      }
      $hourlyBucket = $hourlyBuckets[$hourlyKey]
      Add-CachedUsageToBucket $hourlyBucket $cachedHourly
      $hourlyBucket.turns += [int]$cachedHourly.turns
      [void]$hourlyBucket.sessions.Add($sessionId)
    }

    foreach ($cachedSessionDaily in @($cacheRecord.sessionDaily)) {
      $dateKey = [string]$cachedSessionDaily.date
      $projectName = if ($cachedSessionDaily.project) { [string]$cachedSessionDaily.project } else { "Без папки" }
      $eventCwd = if ($cachedSessionDaily.cwd) { [string]$cachedSessionDaily.cwd } else { $cwd }
      $sessionDayKey = "$dateKey$bucketKeySeparator$sessionId$bucketKeySeparator$projectName"
      if (-not $sessionDayBuckets.ContainsKey($sessionDayKey)) {
        $sessionDayBuckets[$sessionDayKey] = New-SessionDayBucket $dateKey $sessionId $projectName $eventCwd
      }
      $sessionDayBucket = $sessionDayBuckets[$sessionDayKey]
      Add-CachedUsageToBucket $sessionDayBucket $cachedSessionDaily
      $sessionDayBucket.turns += [int]$cachedSessionDaily.turns
    }

    foreach ($cachedSessionHourly in @($cacheRecord.sessionHourly)) {
      $dateKey = [string]$cachedSessionHourly.date
      $hourValue = [int]$cachedSessionHourly.hour
      $projectName = if ($cachedSessionHourly.project) { [string]$cachedSessionHourly.project } else { "Без папки" }
      $eventCwd = if ($cachedSessionHourly.cwd) { [string]$cachedSessionHourly.cwd } else { $cwd }
      $sessionHourKey = "$dateKey$bucketKeySeparator$hourValue$bucketKeySeparator$sessionId$bucketKeySeparator$projectName"
      if (-not $sessionHourBuckets.ContainsKey($sessionHourKey)) {
        $sessionHourBuckets[$sessionHourKey] = New-SessionHourBucket $dateKey $hourValue $sessionId $projectName $eventCwd
      }
      $sessionHourBucket = $sessionHourBuckets[$sessionHourKey]
      Add-CachedUsageToBucket $sessionHourBucket $cachedSessionHourly
      $sessionHourBucket.turns += [int]$cachedSessionHourly.turns
    }

    foreach ($cachedRateLimitEvent in @($cacheRecord.rateLimitEvents)) {
      $entryAt = Parse-DateTimeOffset $cachedRateLimitEvent.at
      $sessionRateLimits = $cachedRateLimitEvent.rateLimits
      if (-not $entryAt -or -not $sessionRateLimits) { continue }

      $rateLimitEvents.Add([pscustomobject]@{
        At = $entryAt
        RateLimits = $sessionRateLimits
      }) | Out-Null

      if ($null -eq $latestRateLimitsAt -or $entryAt -gt $latestRateLimitsAt) {
        $latestRateLimitsAt = $entryAt
        $latestRateLimits = $sessionRateLimits
      }

      $weeklyUsedPercent = Get-DoubleValue $sessionRateLimits.weekly.usedPercent
      if ($weeklyUsedPercent -and $weeklyUsedPercent -gt 0 -and ($null -eq $weeklyLimitBasisAt -or $entryAt -gt $weeklyLimitBasisAt)) {
        $weeklyLimitBasisAt = $entryAt
        $weeklyLimitBasisRateLimits = $sessionRateLimits
      }
    }

    $indexEntry = $threadIndex[$sessionId]
    $title = if ($indexEntry -and $indexEntry.title) { $indexEntry.title } else { $sessionId }
    $sourceName = Get-SourceName $file.FullName $activeSessionsPath $archivedSessionsPath
    $sessionRows.Add([ordered]@{
      id = $sessionId
      title = [string]$title
      project = Get-ProjectName $cwd
      cwd = $cwd
      source = $sourceName
      file = [string]$file.FullName
      start = if ($cacheRecord.startAt) { [string]$cacheRecord.startAt } else { $null }
      end = if ($cacheRecord.endAt) { [string]$cacheRecord.endAt } else { $null }
      inputTokens = Get-Int64Value $usage.inputTokens
      cachedInputTokens = Get-Int64Value $usage.cachedInputTokens
      outputTokens = Get-Int64Value $usage.outputTokens
      reasoningOutputTokens = Get-Int64Value $usage.reasoningOutputTokens
      otherTokens = Get-Int64Value $usage.otherTokens
      totalTokens = Get-Int64Value $usage.totalTokens
      turns = [int]$cacheRecord.turns
      model = if ($cacheRecord.model) { [string]$cacheRecord.model } else { $null }
      modelProvider = if ($cacheRecord.modelProvider) { [string]$cacheRecord.modelProvider } else { $null }
      originator = if ($cacheRecord.originator) { [string]$cacheRecord.originator } else { $null }
      cliVersion = if ($cacheRecord.cliVersion) { [string]$cacheRecord.cliVersion } else { $null }
      contextWindow = if ($cacheRecord.contextWindow) { [int64]$cacheRecord.contextWindow } else { $null }
      rateLimits = $cacheRecord.rateLimits
    })
    continue
  }

  # Fallback for a file that could not be represented in the cache.
  $sessionId = Get-SessionIdFromFileName $file.Name
  $cwd = $null
  $originator = $null
  $cliVersion = $null
  $modelProvider = $null
  $model = $null
  $contextWindow = $null
  $startAt = $null
  $endAt = $null
  $turnCount = 0
  $sumLastUsage = New-UsageBucket
  $lastTotalUsage = New-UsageBucket
  $sessionRateLimits = $null

  $stream = $null
  $reader = $null
  try {
    $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)

    while ($null -ne ($line = $reader.ReadLine())) {
      $linePrefix = if ($line.Length -gt 320) { $line.Substring(0, 320) } else { $line }
      if (-not (
        $linePrefix.Contains('"type":"session_meta"') -or
        $linePrefix.Contains('"type":"turn_context"') -or
        $linePrefix.Contains('"type":"token_count"')
      )) {
        continue
      }

      try {
        $entry = $line | ConvertFrom-Json
      } catch {
        continue
      }

    $entryAt = Parse-DateTimeOffset $entry.timestamp
    if ($null -ne $entryAt) {
      if ($null -eq $startAt -or $entryAt -lt $startAt) { $startAt = $entryAt }
      if ($null -eq $endAt -or $entryAt -gt $endAt) { $endAt = $entryAt }
    }

    if ($entry.type -eq "session_meta") {
      $payload = $entry.payload
      if ($payload.id) { $sessionId = [string]$payload.id }
      if ($payload.cwd) { $cwd = [string]$payload.cwd }
      if ($payload.originator) { $originator = [string]$payload.originator }
      if ($payload.cli_version) { $cliVersion = [string]$payload.cli_version }
      if ($payload.model_provider) { $modelProvider = [string]$payload.model_provider }
      if ($payload.model) { $model = [string]$payload.model }
      continue
    }

    if ($entry.type -eq "turn_context") {
      $payload = $entry.payload
      if ($payload.cwd) { $cwd = [string]$payload.cwd }
      if ($payload.model) { $model = [string]$payload.model }
      continue
    }

    if ($entry.payload.type -ne "token_count") { continue }

    $tokenEventCount += 1
    $turnCount += 1
    $info = $entry.payload.info
    if ($entryAt -and ($null -eq $latestTokenEventAt -or $entryAt -gt $latestTokenEventAt)) {
      $latestTokenEventAt = $entryAt
    }

    if ($info.model_context_window) {
      $contextWindow = Get-Int64Value $info.model_context_window
    }

    if ($info.last_token_usage) {
      $eventProjectName = Get-ProjectName $cwd
      Add-UsageToBucket $sumLastUsage $info.last_token_usage
      if ($null -ne $entryAt) {
        $tokenEvents.Add([ordered]@{
          atTicks = [int64]$entryAt.UtcDateTime.Ticks
          date = Convert-ToLocalDateKey $entryAt
          hour = Convert-ToLocalHourValue $entryAt
          project = $eventProjectName
          totalTokens = Get-Int64Value $info.last_token_usage.total_tokens
        }) | Out-Null
      }

      $dateKey = Convert-ToLocalDateKey $entryAt
      if ($dateKey) {
        if (-not $dailyBuckets.ContainsKey($dateKey)) {
          $dailyBuckets[$dateKey] = New-DailyBucket $dateKey
        }

        $dailyBucket = $dailyBuckets[$dateKey]
        Add-UsageToBucket $dailyBucket $info.last_token_usage
        $dailyBucket.turns += 1
        [void]$dailyBucket.sessions.Add([string]$sessionId)

        $projectName = $eventProjectName
        $hourValue = Convert-ToLocalHourValue $entryAt
        if ($null -ne $hourValue) {
          $hourlyKey = "$dateKey$bucketKeySeparator$hourValue$bucketKeySeparator$projectName"
          if (-not $hourlyBuckets.ContainsKey($hourlyKey)) {
            $hourlyBuckets[$hourlyKey] = New-HourlyBucket $dateKey $hourValue $projectName
          }

          $hourlyBucket = $hourlyBuckets[$hourlyKey]
          Add-UsageToBucket $hourlyBucket $info.last_token_usage
          $hourlyBucket.turns += 1
          [void]$hourlyBucket.sessions.Add([string]$sessionId)

          $sessionHourKey = "$dateKey$bucketKeySeparator$hourValue$bucketKeySeparator$sessionId$bucketKeySeparator$projectName"
          if (-not $sessionHourBuckets.ContainsKey($sessionHourKey)) {
            $sessionHourBuckets[$sessionHourKey] = New-SessionHourBucket $dateKey $hourValue ([string]$sessionId) $projectName $cwd
          }

          $sessionHourBucket = $sessionHourBuckets[$sessionHourKey]
          Add-UsageToBucket $sessionHourBucket $info.last_token_usage
          $sessionHourBucket.turns += 1
        }

        $sessionDayKey = "$dateKey$bucketKeySeparator$sessionId$bucketKeySeparator$projectName"
        if (-not $sessionDayBuckets.ContainsKey($sessionDayKey)) {
          $sessionDayBuckets[$sessionDayKey] = New-SessionDayBucket $dateKey ([string]$sessionId) $projectName $cwd
        }

        $sessionDayBucket = $sessionDayBuckets[$sessionDayKey]
        Add-UsageToBucket $sessionDayBucket $info.last_token_usage
        $sessionDayBucket.turns += 1
      }
    }

    if ($info.total_token_usage) {
      $lastTotalUsage = Copy-Usage $info.total_token_usage
    }

    $rateLimits = $null
    if ($entry.rate_limits) {
      $rateLimits = $entry.rate_limits
    } elseif ($entry.payload.rate_limits) {
      $rateLimits = $entry.payload.rate_limits
    }

    if ($rateLimits) {
      $sessionRateLimits = Convert-RateLimits $rateLimits $entryAt
      if ($entryAt) {
        $rateLimitEvents.Add([pscustomobject]@{
          At = $entryAt
          RateLimits = $sessionRateLimits
        }) | Out-Null
      }

      if ($null -eq $latestRateLimitsAt -or ($entryAt -and $entryAt -gt $latestRateLimitsAt)) {
        $latestRateLimitsAt = $entryAt
        $latestRateLimits = $sessionRateLimits
      }

      $weeklyUsedPercent = Get-DoubleValue $sessionRateLimits.weekly.usedPercent
      if ($weeklyUsedPercent -and $weeklyUsedPercent -gt 0) {
        if ($null -eq $weeklyLimitBasisAt -or ($entryAt -and $entryAt -gt $weeklyLimitBasisAt)) {
          $weeklyLimitBasisAt = $entryAt
          $weeklyLimitBasisRateLimits = $sessionRateLimits
        }
      }
    }
    }
  } finally {
    if ($reader) {
      $reader.Dispose()
    } elseif ($stream) {
      $stream.Dispose()
    }
  }

  $usage = $sumLastUsage
  if ((Get-Int64Value $usage.totalTokens) -eq 0 -and (Get-Int64Value $lastTotalUsage.totalTokens) -gt 0) {
    $usage = $lastTotalUsage
  }

  $indexEntry = $threadIndex[[string]$sessionId]
  $title = if ($indexEntry -and $indexEntry.title) { $indexEntry.title } else { [string]$sessionId }
  $sourceName = Get-SourceName $file.FullName $activeSessionsPath $archivedSessionsPath

  $sessionRows.Add([ordered]@{
    id = [string]$sessionId
    title = [string]$title
    project = Get-ProjectName $cwd
    cwd = if ($cwd) { [string]$cwd } else { $null }
    source = $sourceName
    file = $file.FullName
    start = Convert-ToIsoUtc $startAt
    end = Convert-ToIsoUtc $endAt
    inputTokens = Get-Int64Value $usage.inputTokens
    cachedInputTokens = Get-Int64Value $usage.cachedInputTokens
    outputTokens = Get-Int64Value $usage.outputTokens
    reasoningOutputTokens = Get-Int64Value $usage.reasoningOutputTokens
    otherTokens = Get-Int64Value $usage.otherTokens
    totalTokens = Get-Int64Value $usage.totalTokens
    turns = [int]$turnCount
    model = if ($model) { [string]$model } else { $null }
    modelProvider = if ($modelProvider) { [string]$modelProvider } else { $null }
    originator = if ($originator) { [string]$originator } else { $null }
    cliVersion = if ($cliVersion) { [string]$cliVersion } else { $null }
    contextWindow = if ($contextWindow) { [int64]$contextWindow } else { $null }
    rateLimits = $sessionRateLimits
  })
}

$timingNow = $exportStopwatch.Elapsed.TotalSeconds
$exportTimings.sessionMerge = [Math]::Round($timingNow - $exportTimingCheckpoint, 2)
$exportTimingCheckpoint = $timingNow

$cacheDirectory = Split-Path -Parent $CachePath
if (-not (Test-Path -LiteralPath $cacheDirectory)) {
  New-Item -ItemType Directory -Path $cacheDirectory | Out-Null
}
$cacheJson = [ordered]@{
  schemaVersion = $cacheSchemaVersion
  generatedAt = Convert-ToIsoUtc ([datetimeoffset]::Now)
  files = @($currentCacheRecords.ToArray())
} | ConvertTo-Json -Depth 20 -Compress
$cacheTempPath = "$CachePath.tmp"
[System.IO.File]::WriteAllText($cacheTempPath, $cacheJson, [System.Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $CachePath) {
  try {
    [System.IO.File]::Replace($cacheTempPath, $CachePath, $null)
  } catch {
    Move-Item -LiteralPath $cacheTempPath -Destination $CachePath -Force
  }
} else {
  [System.IO.File]::Move($cacheTempPath, $CachePath)
}

$timingNow = $exportStopwatch.Elapsed.TotalSeconds
$exportTimings.cacheWrite = [Math]::Round($timingNow - $exportTimingCheckpoint, 2)
$exportTimingCheckpoint = $timingNow

$tokenEventPrefixIndex = New-TokenEventPrefixIndex $tokenEvents
$referenceRateLimitAt = if ($latestTokenEventAt) { $latestTokenEventAt } elseif ($latestRateLimitsAt) { $latestRateLimitsAt } else { [datetimeoffset]::Now }
$rateLimitCandidates = @($rateLimitEvents.ToArray() | Where-Object {
  $_.RateLimits -and
  $_.RateLimits.weekly -and
  $null -ne $_.RateLimits.weekly.usedPercent
})
$activeRateLimitCandidates = @($rateLimitCandidates | Where-Object {
  $resetAt = Parse-DateTimeOffset $_.RateLimits.weekly.resetsAt
  $windowMinutes = if ($_.RateLimits.weekly.windowMinutes) { [int]$_.RateLimits.weekly.windowMinutes } else { 10080 }
  if (-not $resetAt) { return $false }

  $windowStart = $resetAt.AddMinutes(-1 * $windowMinutes)
  return $windowStart -le $referenceRateLimitAt -and $referenceRateLimitAt -le $resetAt
})
$activePositiveRateLimitCandidates = @($activeRateLimitCandidates | Where-Object {
  $usedPercent = Get-DoubleValue $_.RateLimits.weekly.usedPercent
  $null -ne $usedPercent -and $usedPercent -gt 0
})
$selectionPool = if ($activePositiveRateLimitCandidates.Count) {
  $activePositiveRateLimitCandidates
} elseif ($activeRateLimitCandidates.Count) {
  $activeRateLimitCandidates
} else {
  $rateLimitCandidates
}
$selectedRateLimitEvent = @(
  $selectionPool |
    Sort-Object `
      @{Expression = {
        $resetAt = Parse-DateTimeOffset $_.RateLimits.weekly.resetsAt
        $normalizedResetAt = Convert-ToMinuteFloor $resetAt
        if ($normalizedResetAt) { $normalizedResetAt } else { [datetimeoffset]::MinValue }
      }; Descending = $true}, `
      @{Expression = { Get-DoubleValue $_.RateLimits.weekly.usedPercent }; Descending = $true}, `
      @{Expression = { $_.At }; Descending = $true} |
    Select-Object -First 1
)

if ($selectedRateLimitEvent.Count) {
  $latestRateLimits = $selectedRateLimitEvent[0].RateLimits
  $latestRateLimitsAt = $selectedRateLimitEvent[0].At
  $weeklyLimitBasisRateLimits = $selectedRateLimitEvent[0].RateLimits
  $weeklyLimitBasisAt = $selectedRateLimitEvent[0].At
}

$weeklyLimitEstimate = $null
$weeklyBurndown = $null
$weeklyLimitTotalTokens = [int64]0
$weeklyWindowStart = $null
$weeklyWindowObservedAt = $null
$weeklyLimitEstimateRateLimits = if ($weeklyLimitBasisRateLimits) { $weeklyLimitBasisRateLimits } else { $latestRateLimits }
$weeklyLimitEstimateAt = if ($weeklyLimitBasisAt) { $weeklyLimitBasisAt } else { $latestRateLimitsAt }
if ($weeklyLimitEstimateRateLimits -and $weeklyLimitEstimateRateLimits.weekly -and $weeklyLimitEstimateAt) {
  $weeklyUsedPercent = Get-DoubleValue $weeklyLimitEstimateRateLimits.weekly.usedPercent
  $weeklyWindowMinutes = if ($weeklyLimitEstimateRateLimits.weekly.windowMinutes) { [int]$weeklyLimitEstimateRateLimits.weekly.windowMinutes } else { 10080 }

  if ($weeklyUsedPercent -and $weeklyUsedPercent -gt 0) {
    $weeklyResetAt = Parse-DateTimeOffset $weeklyLimitEstimateRateLimits.weekly.resetsAt
    $windowStart = $weeklyLimitEstimateAt.AddMinutes(-1 * $weeklyWindowMinutes)
    $windowBasis = "observed_lookback"

    if ($weeklyResetAt) {
      $resetBasedWindowStart = $weeklyResetAt.AddMinutes(-1 * $weeklyWindowMinutes)
      if ($resetBasedWindowStart -lt $weeklyLimitEstimateAt) {
        $windowStart = $resetBasedWindowStart
        $windowBasis = "reset_time"
      }
    }

    $windowTokens = [int64]0
    $windowTokens = Get-TokenEventWindowTotal $tokenEventPrefixIndex $windowStart $weeklyLimitEstimateAt

    if ($windowTokens -gt 0) {
      $weeklyLimitTotalTokens = [int64][Math]::Round($windowTokens * 100 / $weeklyUsedPercent)
      $windowEnd = $windowStart.AddMinutes($weeklyWindowMinutes)
      $weeklyWindowStart = $windowStart
      $weeklyWindowObservedAt = $weeklyLimitEstimateAt
      $hourCount = [int][Math]::Ceiling($weeklyWindowMinutes / 60)
      $burndownPoints = New-Object "System.Collections.Generic.List[object]"

      for ($hourIndex = 0; $hourIndex -le $hourCount; $hourIndex += 1) {
        $pointAt = $windowStart.AddHours($hourIndex)
        if ($pointAt -gt $weeklyLimitEstimateAt) { break }

        $cumulativeTokens = Get-TokenEventWindowTotal $tokenEventPrefixIndex $windowStart $pointAt
        $elapsedMinutes = [Math]::Max(0, [Math]::Min($weeklyWindowMinutes, ($pointAt - $windowStart).TotalMinutes))
        $burndownPoints.Add([ordered]@{
          hour = [int]$hourIndex
          at = Convert-ToIsoUtc $pointAt
          cumulativeTokens = $cumulativeTokens
          usedPercent = [Math]::Round($cumulativeTokens * 100 / $weeklyLimitTotalTokens, 2)
          planPercent = [Math]::Round($elapsedMinutes * 100 / $weeklyWindowMinutes, 2)
        }) | Out-Null
      }

      $currentElapsedMinutes = [Math]::Max(0, [Math]::Min($weeklyWindowMinutes, ($weeklyLimitEstimateAt - $windowStart).TotalMinutes))
      $currentPlanPercent = [Math]::Round($currentElapsedMinutes * 100 / $weeklyWindowMinutes, 2)
      $weeklyLimitEstimateAtIso = Convert-ToIsoUtc $weeklyLimitEstimateAt
      $windowStartIso = Convert-ToIsoUtc $windowStart
      $windowEndIso = Convert-ToIsoUtc $windowEnd
      $burndownPointRows = @($burndownPoints.ToArray())
      $weeklyLimitEstimate = [ordered]@{
        observedAt = $weeklyLimitEstimateAtIso
        usedPercent = $weeklyUsedPercent
        remainingPercent = [Math]::Max(0, 100 - $weeklyUsedPercent)
        windowMinutes = $weeklyWindowMinutes
        windowStart = $windowStartIso
        windowEnd = $windowEndIso
        windowBasis = $windowBasis
        windowTokenUsage = $windowTokens
        estimatedTotalTokens = $weeklyLimitTotalTokens
      }
      $weeklyBurndown = [ordered]@{
        observedAt = $weeklyLimitEstimateAtIso
        windowStart = $windowStartIso
        windowEnd = $windowEndIso
        windowMinutes = $weeklyWindowMinutes
        hourCount = $hourCount
        estimatedTotalTokens = $weeklyLimitTotalTokens
        windowTokenUsage = $windowTokens
        usedPercent = $weeklyUsedPercent
        remainingPercent = [Math]::Max(0, 100 - $weeklyUsedPercent)
        planPercent = $currentPlanPercent
        currentPoint = [ordered]@{
          at = $weeklyLimitEstimateAtIso
          cumulativeTokens = $windowTokens
          usedPercent = $weeklyUsedPercent
          planPercent = $currentPlanPercent
        }
        points = $burndownPointRows
      }
    }
  }
}

$weeklyLimitWindows = New-Object "System.Collections.Generic.List[object]"
$rateLimitWindowBestCandidates = @{}

foreach ($candidate in $rateLimitCandidates) {
  $usedPercent = Get-DoubleValue $candidate.RateLimits.weekly.usedPercent
  if ($null -eq $usedPercent -or $usedPercent -le 0) { continue }

  $windowMinutes = if ($candidate.RateLimits.weekly.windowMinutes) { [int]$candidate.RateLimits.weekly.windowMinutes } else { 10080 }
  $resetAt = Parse-DateTimeOffset $candidate.RateLimits.weekly.resetsAt
  $windowStart = $null
  $windowEnd = $null
  $basis = "observed_lookback"

  if ($resetAt) {
    $windowEnd = Convert-ToMinuteFloor $resetAt
    $windowStart = $windowEnd.AddMinutes(-1 * $windowMinutes)
    $basis = "reset_time"
  } elseif ($candidate.At) {
    $windowStart = $candidate.At.AddMinutes(-1 * $windowMinutes)
    $windowEnd = $windowStart.AddMinutes($windowMinutes)
  }

  if (-not $windowStart -or -not $windowEnd -or -not $candidate.At) { continue }
  if ($candidate.At -lt $windowStart -or $candidate.At -gt $windowEnd) { continue }

  $windowCandidate = [pscustomobject]@{
    Key = "$(Convert-ToIsoUtc $windowStart)|$(Convert-ToIsoUtc $windowEnd)|$windowMinutes"
    Start = $windowStart
    End = $windowEnd
    At = $candidate.At
    UsedPercent = $usedPercent
    WindowMinutes = $windowMinutes
    Basis = $basis
  }

  $existingCandidate = $rateLimitWindowBestCandidates[$windowCandidate.Key]
  if (
    -not $existingCandidate -or
    $windowCandidate.UsedPercent -gt $existingCandidate.UsedPercent -or
    ($windowCandidate.UsedPercent -eq $existingCandidate.UsedPercent -and $windowCandidate.At -gt $existingCandidate.At)
  ) {
    $rateLimitWindowBestCandidates[$windowCandidate.Key] = $windowCandidate
  }
}

foreach ($basisCandidate in ($rateLimitWindowBestCandidates.Values | Sort-Object Start)) {
  $windowTokens = Get-TokenEventWindowTotal $tokenEventPrefixIndex $basisCandidate.Start $basisCandidate.At

  if ($windowTokens -le 0) { continue }

  $estimatedTotalTokens = [int64][Math]::Round($windowTokens * 100 / $basisCandidate.UsedPercent)
  if ($estimatedTotalTokens -le 0) { continue }

  $weeklyLimitWindows.Add([pscustomobject]@{
    Start = $basisCandidate.Start
    End = $basisCandidate.End
    ObservedAt = $basisCandidate.At
    UsedPercent = $basisCandidate.UsedPercent
    EstimatedTotalTokens = $estimatedTotalTokens
    WindowTokenUsage = $windowTokens
    WindowMinutes = $basisCandidate.WindowMinutes
    Basis = $basisCandidate.Basis
  }) | Out-Null
}

$weeklyDailyTokenBuckets = @{}
$weeklyDailyPercentBuckets = @{}
$weeklyHourlyTokenBuckets = @{}
$weeklyHourlyPercentBuckets = @{}
$weeklyLimitWindowRows = New-Object "System.Collections.Generic.List[object]"
$rawWeeklyLimitWindowRows = @($weeklyLimitWindows.ToArray() | Sort-Object @{Expression = "ObservedAt"; Descending = $true}, @{Expression = "UsedPercent"; Descending = $true})
foreach ($candidateWindow in $rawWeeklyLimitWindowRows) {
  $isDuplicateWindow = $false
  foreach ($selectedWindow in $weeklyLimitWindowRows) {
    $overlapStart = if ($candidateWindow.Start -gt $selectedWindow.Start) { $candidateWindow.Start } else { $selectedWindow.Start }
    $overlapEnd = if ($candidateWindow.End -lt $selectedWindow.End) { $candidateWindow.End } else { $selectedWindow.End }
    $overlapMinutes = [Math]::Max(0, ($overlapEnd - $overlapStart).TotalMinutes)
    $shorterWindowMinutes = [Math]::Max(1, [Math]::Min([double]$candidateWindow.WindowMinutes, [double]$selectedWindow.WindowMinutes))

    if (($overlapMinutes / $shorterWindowMinutes) -ge 0.8) {
      $isDuplicateWindow = $true
      break
    }
  }

  if (-not $isDuplicateWindow) {
    $weeklyLimitWindowRows.Add($candidateWindow) | Out-Null
  }
}

$weeklyLimitWindowRows = @($weeklyLimitWindowRows | Sort-Object Start)
$latestKnownWeeklyLimitWindow = @($weeklyLimitWindowRows | Sort-Object ObservedAt | Select-Object -Last 1)
$fallbackWeeklyLimitTotalTokens = if ($latestKnownWeeklyLimitWindow.Count) { Get-Int64Value $latestKnownWeeklyLimitWindow[0].EstimatedTotalTokens } else { [int64]0 }
$currentRateLimitForFallback = if ($latestRateLimits) { $latestRateLimits } else { $weeklyLimitEstimateRateLimits }
$currentRateLimitAtForFallback = if ($latestRateLimitsAt) { $latestRateLimitsAt } else { $weeklyLimitEstimateAt }

if (
  -not $weeklyLimitEstimate -and
  $fallbackWeeklyLimitTotalTokens -gt 0 -and
  $currentRateLimitForFallback -and
  $currentRateLimitForFallback.weekly -and
  $currentRateLimitAtForFallback
) {
  $currentWeeklyWindowMinutes = if ($currentRateLimitForFallback.weekly.windowMinutes) { [int]$currentRateLimitForFallback.weekly.windowMinutes } else { 10080 }
  $currentWeeklyResetAt = Parse-DateTimeOffset $currentRateLimitForFallback.weekly.resetsAt
  $currentWeeklyWindowStart = $currentRateLimitAtForFallback.AddMinutes(-1 * $currentWeeklyWindowMinutes)
  $currentWeeklyWindowEnd = $currentWeeklyWindowStart.AddMinutes($currentWeeklyWindowMinutes)
  $currentWeeklyBasis = "token_fallback_observed_lookback"

  if ($currentWeeklyResetAt) {
    $currentWeeklyWindowEnd = Convert-ToMinuteFloor $currentWeeklyResetAt
    $currentWeeklyWindowStart = $currentWeeklyWindowEnd.AddMinutes(-1 * $currentWeeklyWindowMinutes)
    $currentWeeklyBasis = "token_fallback_reset_time"
  }

  $currentWeeklyObservedAt = if ($latestTokenEventAt -and $latestTokenEventAt -gt $currentWeeklyWindowStart) { $latestTokenEventAt } else { $currentRateLimitAtForFallback }
  if ($currentWeeklyObservedAt -gt $currentWeeklyWindowEnd) { $currentWeeklyObservedAt = $currentWeeklyWindowEnd }
  $currentWeeklyWindowTokens = Get-TokenEventWindowTotal $tokenEventPrefixIndex $currentWeeklyWindowStart $currentWeeklyObservedAt
  $currentWeeklyUsedPercent = if ($currentWeeklyWindowTokens -gt 0) { [Math]::Round($currentWeeklyWindowTokens * 100 / $fallbackWeeklyLimitTotalTokens, 2) } else { $null }

  if ($currentWeeklyWindowTokens -gt 0 -and $null -ne $currentWeeklyUsedPercent) {
    $currentFallbackWindow = [pscustomobject]@{
      Start = $currentWeeklyWindowStart
      End = $currentWeeklyWindowEnd
      ObservedAt = $currentWeeklyObservedAt
      UsedPercent = $currentWeeklyUsedPercent
      EstimatedTotalTokens = $fallbackWeeklyLimitTotalTokens
      WindowTokenUsage = $currentWeeklyWindowTokens
      WindowMinutes = $currentWeeklyWindowMinutes
      Basis = $currentWeeklyBasis
    }
    $weeklyLimitWindowRows = @($weeklyLimitWindowRows + $currentFallbackWindow)

    $fallbackHourCount = [int][Math]::Ceiling($currentWeeklyWindowMinutes / 60)
    $fallbackBurndownPoints = New-Object "System.Collections.Generic.List[object]"

    for ($hourIndex = 0; $hourIndex -le $fallbackHourCount; $hourIndex += 1) {
      $pointAt = $currentWeeklyWindowStart.AddHours($hourIndex)
      if ($pointAt -gt $currentWeeklyObservedAt) { break }

      $fallbackCumulativeTokens = Get-TokenEventWindowTotal $tokenEventPrefixIndex $currentWeeklyWindowStart $pointAt
      $elapsedMinutes = [Math]::Max(0, [Math]::Min($currentWeeklyWindowMinutes, ($pointAt - $currentWeeklyWindowStart).TotalMinutes))
      $fallbackBurndownPoints.Add([ordered]@{
        hour = [int]$hourIndex
        at = Convert-ToIsoUtc $pointAt
        cumulativeTokens = $fallbackCumulativeTokens
        usedPercent = [Math]::Round($fallbackCumulativeTokens * 100 / $fallbackWeeklyLimitTotalTokens, 2)
        planPercent = [Math]::Round($elapsedMinutes * 100 / $currentWeeklyWindowMinutes, 2)
      }) | Out-Null
    }

    $currentElapsedMinutes = [Math]::Max(0, [Math]::Min($currentWeeklyWindowMinutes, ($currentWeeklyObservedAt - $currentWeeklyWindowStart).TotalMinutes))
    $currentPlanPercent = [Math]::Round($currentElapsedMinutes * 100 / $currentWeeklyWindowMinutes, 2)
    $currentWeeklyObservedAtIso = Convert-ToIsoUtc $currentWeeklyObservedAt
    $currentWeeklyWindowStartIso = Convert-ToIsoUtc $currentWeeklyWindowStart
    $currentWeeklyWindowEndIso = Convert-ToIsoUtc $currentWeeklyWindowEnd
    $weeklyLimitTotalTokens = $fallbackWeeklyLimitTotalTokens
    $weeklyWindowStart = $currentWeeklyWindowStart
    $weeklyWindowObservedAt = $currentWeeklyObservedAt
    $weeklyLimitEstimate = [ordered]@{
      observedAt = $currentWeeklyObservedAtIso
      usedPercent = $currentWeeklyUsedPercent
      remainingPercent = [Math]::Max(0, 100 - $currentWeeklyUsedPercent)
      windowMinutes = $currentWeeklyWindowMinutes
      windowStart = $currentWeeklyWindowStartIso
      windowEnd = $currentWeeklyWindowEndIso
      windowBasis = $currentWeeklyBasis
      windowTokenUsage = $currentWeeklyWindowTokens
      estimatedTotalTokens = $fallbackWeeklyLimitTotalTokens
    }
    $weeklyBurndown = [ordered]@{
      observedAt = $currentWeeklyObservedAtIso
      windowStart = $currentWeeklyWindowStartIso
      windowEnd = $currentWeeklyWindowEndIso
      windowMinutes = $currentWeeklyWindowMinutes
      hourCount = $fallbackHourCount
      estimatedTotalTokens = $fallbackWeeklyLimitTotalTokens
      windowTokenUsage = $currentWeeklyWindowTokens
      usedPercent = $currentWeeklyUsedPercent
      remainingPercent = [Math]::Max(0, 100 - $currentWeeklyUsedPercent)
      planPercent = $currentPlanPercent
      currentPoint = [ordered]@{
        at = $currentWeeklyObservedAtIso
        cumulativeTokens = $currentWeeklyWindowTokens
        usedPercent = $currentWeeklyUsedPercent
        planPercent = $currentPlanPercent
      }
      points = @($fallbackBurndownPoints.ToArray())
    }
  }
}

$weeklyLimitWindowRows = @($weeklyLimitWindowRows | Sort-Object Start)
$weeklyLimitWindowSummaryRows = @(
  foreach ($window in $weeklyLimitWindowRows) {
    [ordered]@{
      windowStart = Convert-ToIsoUtc $window.Start
      windowEnd = Convert-ToIsoUtc $window.End
      observedAt = Convert-ToIsoUtc $window.ObservedAt
      usedPercent = [double]$window.UsedPercent
      windowTokenUsage = Get-Int64Value $window.WindowTokenUsage
      estimatedTotalTokens = Get-Int64Value $window.EstimatedTotalTokens
      windowMinutes = [int]$window.WindowMinutes
      windowBasis = [string]$window.Basis
    }
  }
)

$weeklyWindowStartTicks = New-Object "System.Collections.Generic.List[long]"
$weeklyWindowEndTicks = New-Object "System.Collections.Generic.List[long]"
foreach ($window in $weeklyLimitWindowRows) {
  $weeklyWindowStartTicks.Add([long]$window.Start.UtcDateTime.Ticks) | Out-Null
  $weeklyWindowEndTicks.Add([long]$window.End.UtcDateTime.Ticks) | Out-Null
}

foreach ($event in $tokenEvents) {
  $eventTicks = Get-Int64Value $event.atTicks
  if ($eventTicks -le 0) { continue }
  $windowIndex = Find-WeeklyWindowIndex $weeklyWindowStartTicks $weeklyWindowEndTicks $eventTicks
  if ($windowIndex -lt 0) { continue }
  $eventWindow = $weeklyLimitWindowRows[$windowIndex]

  $estimatedTotalTokens = Get-Int64Value $eventWindow.EstimatedTotalTokens
  if ($estimatedTotalTokens -le 0) { continue }

  $eventTokens = Get-Int64Value $event.totalTokens
  $eventPercent = $eventTokens * 100 / $estimatedTotalTokens
  $dateKey = if ($event.date) { [string]$event.date } else { $null }
  $hourValue = if ($null -ne $event.hour) { [int]$event.hour } else { $null }
  $projectName = if ($event.project) { [string]$event.project } else { "Без папки" }

  if ($dateKey) {
    if (-not $weeklyDailyTokenBuckets.ContainsKey($dateKey)) { $weeklyDailyTokenBuckets[$dateKey] = [int64]0 }
    if (-not $weeklyDailyPercentBuckets.ContainsKey($dateKey)) { $weeklyDailyPercentBuckets[$dateKey] = [double]0 }
    $weeklyDailyTokenBuckets[$dateKey] += $eventTokens
    $weeklyDailyPercentBuckets[$dateKey] += $eventPercent
  }

  if ($dateKey -and $null -ne $hourValue) {
    $hourlyKey = "$dateKey$bucketKeySeparator$hourValue$bucketKeySeparator$projectName"
    if (-not $weeklyHourlyTokenBuckets.ContainsKey($hourlyKey)) { $weeklyHourlyTokenBuckets[$hourlyKey] = [int64]0 }
    if (-not $weeklyHourlyPercentBuckets.ContainsKey($hourlyKey)) { $weeklyHourlyPercentBuckets[$hourlyKey] = [double]0 }
    $weeklyHourlyTokenBuckets[$hourlyKey] += $eventTokens
    $weeklyHourlyPercentBuckets[$hourlyKey] += $eventPercent
  }
}

$timingNow = $exportStopwatch.Elapsed.TotalSeconds
$exportTimings.weeklyModel = [Math]::Round($timingNow - $exportTimingCheckpoint, 2)
$exportTimingCheckpoint = $timingNow

$dailyRows = @(
  foreach ($dateKey in ($dailyBuckets.Keys | Sort-Object)) {
    $bucket = $dailyBuckets[$dateKey]
    $dailyWeeklyLimitPercent = $null
    $dailyWeeklyLimitTokens = if ($weeklyDailyTokenBuckets.ContainsKey($dateKey)) { Get-Int64Value $weeklyDailyTokenBuckets[$dateKey] } else { [int64]0 }
    if ($weeklyDailyPercentBuckets.ContainsKey($dateKey)) {
      $dailyWeeklyLimitPercent = [Math]::Round([double]$weeklyDailyPercentBuckets[$dateKey], 2)
    }

    [ordered]@{
      date = [string]$dateKey
      inputTokens = Get-Int64Value $bucket.inputTokens
      cachedInputTokens = Get-Int64Value $bucket.cachedInputTokens
      outputTokens = Get-Int64Value $bucket.outputTokens
      reasoningOutputTokens = Get-Int64Value $bucket.reasoningOutputTokens
      otherTokens = Get-Int64Value $bucket.otherTokens
      totalTokens = Get-Int64Value $bucket.totalTokens
      weeklyLimitTokens = $dailyWeeklyLimitTokens
      weeklyLimitPercent = $dailyWeeklyLimitPercent
      turns = [int]$bucket.turns
      sessions = [int]$bucket.sessions.Count
    }
  }
)

$hourlyRows = @(
  foreach ($key in ($hourlyBuckets.Keys | Sort-Object)) {
    $bucket = $hourlyBuckets[$key]
    $hourlyWeeklyLimitPercent = $null
    $hourlyWeeklyLimitTokens = if ($weeklyHourlyTokenBuckets.ContainsKey($key)) { Get-Int64Value $weeklyHourlyTokenBuckets[$key] } else { [int64]0 }
    if ($weeklyHourlyPercentBuckets.ContainsKey($key)) {
      $hourlyWeeklyLimitPercent = [Math]::Round([double]$weeklyHourlyPercentBuckets[$key], 2)
    }

    [ordered]@{
      date = [string]$bucket.date
      hour = [int]$bucket.hour
      project = [string]$bucket.project
      inputTokens = Get-Int64Value $bucket.inputTokens
      cachedInputTokens = Get-Int64Value $bucket.cachedInputTokens
      outputTokens = Get-Int64Value $bucket.outputTokens
      reasoningOutputTokens = Get-Int64Value $bucket.reasoningOutputTokens
      otherTokens = Get-Int64Value $bucket.otherTokens
      totalTokens = Get-Int64Value $bucket.totalTokens
      weeklyLimitTokens = $hourlyWeeklyLimitTokens
      weeklyLimitPercent = $hourlyWeeklyLimitPercent
      turns = [int]$bucket.turns
      sessions = [int]$bucket.sessions.Count
    }
  }
)

$sessionDailyRows = @(
  foreach ($key in ($sessionDayBuckets.Keys | Sort-Object)) {
    $bucket = $sessionDayBuckets[$key]
    $indexEntry = $threadIndex[[string]$bucket.sessionId]
    $title = if ($indexEntry -and $indexEntry.title) { $indexEntry.title } else { [string]$bucket.sessionId }

    [ordered]@{
      date = [string]$bucket.date
      sessionId = [string]$bucket.sessionId
      title = [string]$title
      project = [string]$bucket.project
      cwd = if ($bucket.cwd) { [string]$bucket.cwd } else { $null }
      inputTokens = Get-Int64Value $bucket.inputTokens
      cachedInputTokens = Get-Int64Value $bucket.cachedInputTokens
      outputTokens = Get-Int64Value $bucket.outputTokens
      reasoningOutputTokens = Get-Int64Value $bucket.reasoningOutputTokens
      otherTokens = Get-Int64Value $bucket.otherTokens
      totalTokens = Get-Int64Value $bucket.totalTokens
      turns = [int]$bucket.turns
    }
  }
)

$sessionHourlyRows = @(
  foreach ($key in ($sessionHourBuckets.Keys | Sort-Object)) {
    $bucket = $sessionHourBuckets[$key]
    $indexEntry = $threadIndex[[string]$bucket.sessionId]
    $title = if ($indexEntry -and $indexEntry.title) { $indexEntry.title } else { [string]$bucket.sessionId }

    [ordered]@{
      date = [string]$bucket.date
      hour = [int]$bucket.hour
      sessionId = [string]$bucket.sessionId
      title = [string]$title
      project = [string]$bucket.project
      cwd = if ($bucket.cwd) { [string]$bucket.cwd } else { $null }
      inputTokens = Get-Int64Value $bucket.inputTokens
      cachedInputTokens = Get-Int64Value $bucket.cachedInputTokens
      outputTokens = Get-Int64Value $bucket.outputTokens
      reasoningOutputTokens = Get-Int64Value $bucket.reasoningOutputTokens
      otherTokens = Get-Int64Value $bucket.otherTokens
      totalTokens = Get-Int64Value $bucket.totalTokens
      turns = [int]$bucket.turns
    }
  }
)

$timingNow = $exportStopwatch.Elapsed.TotalSeconds
$exportTimings.rowBuild = [Math]::Round($timingNow - $exportTimingCheckpoint, 2)
$exportTimingCheckpoint = $timingNow

$totalInput = [int64]0
$totalCached = [int64]0
$totalOutput = [int64]0
$totalReasoning = [int64]0
$totalOther = [int64]0
$totalTokens = [int64]0
$sessionsWithTokens = 0

foreach ($session in $sessionRows) {
  $totalInput += Get-Int64Value $session.inputTokens
  $totalCached += Get-Int64Value $session.cachedInputTokens
  $totalOutput += Get-Int64Value $session.outputTokens
  $totalReasoning += Get-Int64Value $session.reasoningOutputTokens
  $totalOther += Get-Int64Value $session.otherTokens
  $totalTokens += Get-Int64Value $session.totalTokens
  if ((Get-Int64Value $session.totalTokens) -gt 0) { $sessionsWithTokens += 1 }
}

$generatedAt = [datetimeoffset]::Now.ToUniversalTime().ToString("o")
$snapshot = [ordered]@{
  schemaVersion = 2
  generatedAt = $generatedAt
  codexHome = $CodexHome
  localTimeZone = [System.TimeZoneInfo]::Local.Id
  summary = [ordered]@{
    filesScanned = [int]$sessionFiles.Count
    cacheHits = [int]$cacheHits
    cacheMisses = [int]$cacheMisses
    cacheAppends = [int]$cacheAppends
    sessions = [int]$sessionRows.Count
    sessionsWithTokens = [int]$sessionsWithTokens
    tokenEvents = [int]$tokenEventCount
    inputTokens = $totalInput
    cachedInputTokens = $totalCached
    outputTokens = $totalOutput
    reasoningOutputTokens = $totalReasoning
    otherTokens = $totalOther
    totalTokens = $totalTokens
    latestTokenEventAt = Convert-ToIsoUtc $latestTokenEventAt
    latestRateLimits = $latestRateLimits
    weeklyLimitEstimate = $weeklyLimitEstimate
    weeklyBurndown = $weeklyBurndown
    weeklyLimitWindows = $weeklyLimitWindowSummaryRows
  }
  daily = $dailyRows
  hourly = $hourlyRows
  sessionHourly = $sessionHourlyRows
  sessionDaily = $sessionDailyRows
  sessions = @($sessionRows | Sort-Object @{Expression = "end"; Descending = $true}, @{Expression = "start"; Descending = $true})
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
  New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

$json = $snapshot | ConvertTo-Json -Depth 30 -Compress
$content = "window.CODEX_TOKEN_USAGE_SNAPSHOT = $json;"
[System.IO.File]::WriteAllText($OutputPath, $content, [System.Text.UTF8Encoding]::new($false))
$timingNow = $exportStopwatch.Elapsed.TotalSeconds
$exportTimings.snapshotWrite = [Math]::Round($timingNow - $exportTimingCheckpoint, 2)
$exportStopwatch.Stop()

[pscustomobject]@{
  OutputPath = $OutputPath
  FilesScanned = $sessionFiles.Count
  CacheHits = $cacheHits
  CacheMisses = $cacheMisses
  CacheAppends = $cacheAppends
  SessionsWithTokens = $sessionsWithTokens
  TokenEvents = $tokenEventCount
  TotalTokens = $totalTokens
  Stages = $exportTimings
  DurationSeconds = [Math]::Round($exportStopwatch.Elapsed.TotalSeconds, 2)
  GeneratedAt = $generatedAt
}
