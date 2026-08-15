param(
    [int[]]$Contexts = @(4096, 8192, 16384, 32768, 65536, 131072, 163840),
    [int]$Runs = 3,
    [int]$MaxTokens = 500,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\common.ps1')

if ($Runs -ne 3) { throw 'Runs must be exactly 3 for the publishable benchmark contract.' }
if ($MaxTokens -ne 500) { throw 'MaxTokens must be exactly 500; the benchmark rejects shorter or partial completions.' }

$baseUrl = if ([string]::IsNullOrWhiteSpace($env:QWEN_BASE_URL)) { 'http://127.0.0.1:8080/v1' } else { $env:QWEN_BASE_URL.TrimEnd('/') }
try { $baseUri = [Uri]$baseUrl } catch { throw 'QWEN_BASE_URL must be a valid URI.' }
if ($baseUri.Scheme -ne 'http' -or $baseUri.Host -ne '127.0.0.1' -or $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
    throw 'QWEN_BASE_URL must be an http loopback URL without credentials, query, or fragment.'
}
if (@($Contexts).Count -eq 0 -or @($Contexts | Where-Object { $_ -lt 1 -or $_ -gt 163840 }).Count -gt 0) { throw 'Contexts must be unique positive values no greater than 245760.' }
if (@($Contexts | Sort-Object -Unique).Count -ne @($Contexts).Count) { throw 'Contexts must not contain duplicates.' }
$requiredContexts = @(4096, 8192, 16384, 32768, 65536, 131072, 163840)
$fullLadderRequested = (@($Contexts).Count -eq $requiredContexts.Count -and (@($Contexts) -join ',') -eq ($requiredContexts -join ','))
$cfg = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\profile.example.json') -Raw | ConvertFrom-Json
$api = Get-RecipeKey $cfg
$model = if ([string]::IsNullOrWhiteSpace($env:QWEN_MODEL_ID)) { 'qwen3.8-27b' } else { $env:QWEN_MODEL_ID }
if ($model -match '[\\/:]') { throw 'QWEN_MODEL_ID must be an identifier, not a filesystem path.' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $env:TEMP ('qwen38-27b-262k-500-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

function Get-GpuMemory {
    try {
        $line = & nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        $parts = @($line -split ',')
        if ($parts.Count -lt 3) { return $null }
        $used = [int]$parts[1].Trim()
        $total = [int]$parts[2].Trim()
        return [ordered]@{ name = $parts[0].Trim(); usedMiB = $used; totalMiB = $total; freeMiB = $total - $used }
    } catch { return $null }
}

function New-Prompt([int]$TargetTokens) {
    # Keep the prompt deterministic and deliberately ask for a non-terminating
    # 500-token continuation. ignore_eos below is a second guard against a
    # natural EOS being mistaken for a valid throughput point.
    $repeatCount = [Math]::Max(1, $TargetTokens - 24)
    $filler = ((' context' * $repeatCount) -join '')
    return "$filler`nOutput exactly 500 tokens consisting only of the word x separated by spaces. Do not stop early and do not add a conclusion."
}

function Invoke-Decode([string]$Prompt, [int]$RunNumber) {
    $body = [ordered]@{
        model = $model
        messages = @(@{ role = 'user'; content = $Prompt })
        temperature = 0.0
        top_p = 1.0
        seed = 20260814
        max_tokens = 500
        ignore_eos = $true
    } | ConvertTo-Json -Depth 10 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri "$baseUrl/chat/completions" -Method Post -Headers @{ Authorization = "Bearer $($api.Value)"; 'Content-Type' = 'application/json' } -Body $body -TimeoutSec 1800 -ErrorAction Stop
        $sw.Stop()
        if ($null -eq $response.usage -or $null -eq $response.usage.prompt_tokens -or $null -eq $response.usage.completion_tokens -or $null -eq $response.timings -or $null -eq $response.timings.predicted_per_second) {
            return [ordered]@{ run = $RunNumber; ok = $false; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); errorCode = 'response_schema_invalid' }
        }
        $completionTokens = [int]$response.usage.completion_tokens
        $decodeTokensPerSecond = [double]$response.timings.predicted_per_second
        if ($completionTokens -ne 500) {
            return [ordered]@{ run = $RunNumber; ok = $false; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); promptTokens = [int]$response.usage.prompt_tokens; completionTokens = $completionTokens; decodeTokensPerSecond = $decodeTokensPerSecond; errorCode = 'completion_not_500' }
        }
        return [ordered]@{ run = $RunNumber; ok = $true; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); promptTokens = [int]$response.usage.prompt_tokens; completionTokens = $completionTokens; decodeTokensPerSecond = $decodeTokensPerSecond }
    } catch {
        $sw.Stop()
        return [ordered]@{ run = $RunNumber; ok = $false; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); errorCode = 'request_failed' }
    }
}

function Get-Average([object[]]$RunResults) {
    $valid = @($RunResults | Where-Object { $_.ok -eq $true })
    if ($valid.Count -ne $Runs) { return $null }
    $decode = ($valid | ForEach-Object { [double]$_.decodeTokensPerSecond } | Measure-Object -Average).Average
    $wall = ($valid | ForEach-Object { [double]$_.wallSeconds } | Measure-Object -Average).Average
    $prompt = ($valid | ForEach-Object { [double]$_.promptTokens } | Measure-Object -Average).Average
    $gpuSamples = @($valid | ForEach-Object { @($_.beforeGpu, $_.afterGpu) } | Where-Object { $null -ne $_ })
    $gpuUsed = if ($gpuSamples.Count -gt 0) { ($gpuSamples | ForEach-Object { [double]$_.usedMiB } | Measure-Object -Average).Average } else { $null }
    $gpuPeak = if ($gpuSamples.Count -gt 0) { ($gpuSamples | ForEach-Object { [double]$_.usedMiB } | Measure-Object -Maximum).Maximum } else { $null }
    return [ordered]@{
        runs = $Runs
        promptTokens = [int][Math]::Round($prompt)
        completionTokens = 500
        decodeTokensPerSecond = [Math]::Round($decode, 2)
        wallSeconds = [Math]::Round($wall, 3)
        averageSampledGpuUsedMiB = if ($null -eq $gpuUsed) { $null } else { [Math]::Round($gpuUsed, 1) }
        peakSampledGpuUsedMiB = if ($null -eq $gpuPeak) { $null } else { [int][Math]::Round($gpuPeak) }
    }
}

$results = [ordered]@{
    metadata = [ordered]@{
        startedAt = (Get-Date).ToString('o')
        complete = $false
        endpoint = 'loopback'
        model = $model
        runs = $Runs
        requiredCompletionTokens = 500
        temperature = 0.0
        seed = 20260814
        ignoreEos = $true
        contexts = $Contexts
        requiredContexts = $requiredContexts
        fullLadderRequested = $fullLadderRequested
        completedContexts = @()
        failedContexts = @()
    }
    ladder = [ordered]@{}
}

function Save-Results {
    $results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

$hadFailure = $false
Save-Results
foreach ($target in $Contexts) {
    Write-Host "Benchmarking $target prompt tokens ($Runs runs; 500 completion tokens each)..." -ForegroundColor Yellow
    $prompt = New-Prompt $target
    $runResults = @()
    for ($run = 1; $run -le $Runs; $run++) {
        $before = Get-GpuMemory
        $result = Invoke-Decode $prompt $run
        $after = Get-GpuMemory
        $result['beforeGpu'] = $before
        $result['afterGpu'] = $after
        $runResults += ,$result
        Write-Host ("  run {0}: ok={1}, prompt={2}, completion={3}, t/s={4}" -f $run, $result.ok, $result.promptTokens, $result.completionTokens, $result.decodeTokensPerSecond)
    }
    $average = Get-Average $runResults
    $valid = $null -ne $average
    $results.ladder["$target"] = [ordered]@{ targetTokens = $target; valid = $valid; runs = $runResults; average = $average }
    if ($valid) { $results.metadata.completedContexts += $target }
    else { $results.metadata.failedContexts += $target; $hadFailure = $true }
    Save-Results
    if ($valid) { Write-Host ("  average: {0} tok/s over {1} complete runs" -f $average.decodeTokensPerSecond, $Runs) -ForegroundColor Green }
    else { Write-Host '  INVALID: every run must return exactly 500 completion tokens.' -ForegroundColor Red }
}
$results.metadata.finishedAt = (Get-Date).ToString('o')
$results.metadata.finalGpu = Get-GpuMemory
$results.metadata.complete = (-not $hadFailure -and $fullLadderRequested -and $Runs -eq 3)
Save-Results
Write-Host "Saved $OutputPath" -ForegroundColor Green
if ($hadFailure) {
    Write-Host 'Benchmark incomplete: at least one context did not produce three 500-token runs.' -ForegroundColor Red
    exit 1
}
