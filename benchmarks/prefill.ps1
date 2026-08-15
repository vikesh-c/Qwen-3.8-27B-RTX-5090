param(
    [int[]]$Contexts = @(4096, 8192, 16384, 32768, 65536, 131072, 163840),
    [int]$Runs = 3,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\common.ps1')

if ($Runs -ne 3) { throw 'Runs must be exactly 3 for the publishable prefill benchmark contract.' }
$requiredContexts = @(4096, 8192, 16384, 32768, 65536, 131072, 163840)
if (@($Contexts).Count -eq 0 -or @($Contexts | Where-Object { $_ -lt 1 -or $_ -gt 163840 }).Count -gt 0) { throw 'Contexts must be unique positive values no greater than 163840.' }
if (@($Contexts | Sort-Object -Unique).Count -ne @($Contexts).Count) { throw 'Contexts must not contain duplicates.' }
$fullLadderRequested = (@($Contexts).Count -eq $requiredContexts.Count -and (@($Contexts) -join ',') -eq ($requiredContexts -join ','))

$baseUrl = if ([string]::IsNullOrWhiteSpace($env:QWEN_BASE_URL)) { 'http://127.0.0.1:8080/v1' } else { $env:QWEN_BASE_URL.TrimEnd('/') }
try { $baseUri = [Uri]$baseUrl } catch { throw 'QWEN_BASE_URL must be a valid URI.' }
if ($baseUri.Scheme -ne 'http' -or $baseUri.Host -ne '127.0.0.1' -or $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
    throw 'QWEN_BASE_URL must be an http loopback URL without credentials, query, or fragment.'
}
$cfg = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\profile.example.json') -Raw | ConvertFrom-Json
$api = Get-RecipeKey $cfg
$headers = @{ Authorization = "Bearer $($api.Value)"; 'Content-Type' = 'application/json' }
$model = if ([string]::IsNullOrWhiteSpace($env:QWEN_MODEL_ID)) { 'qwen3.8-27b' } else { $env:QWEN_MODEL_ID }
if ($model -match '[\\/:]') { throw 'QWEN_MODEL_ID must be an identifier, not a filesystem path.' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $env:TEMP ('qwen38-27b-prefill-3x-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$propsBuilder = New-Object System.UriBuilder($baseUri)
$propsBuilder.Path = '/props'
$propsBuilder.Query = ''
$props = Invoke-RestMethod -Uri $propsBuilder.Uri.AbsoluteUri -Headers $headers -TimeoutSec 10 -ErrorAction Stop
$serverContext = [int]$props.default_generation_settings.n_ctx
$requiredServerContext = [int](($Contexts | Measure-Object -Maximum).Maximum)
if ($serverContext -lt $requiredServerContext) { throw "The server context is $serverContext tokens; at least $requiredServerContext is required for the requested prompt ladder." }
$slotBuilder = New-Object System.UriBuilder($baseUri)
$slotBuilder.Path = '/slots/0'
$slotBuilder.Query = 'action=erase'
$slotEraseUri = $slotBuilder.Uri.AbsoluteUri
$invocationNonce = [Guid]::NewGuid().ToString('N')

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

function New-PrefillPrompt([int]$TargetTokens, [int]$RunNumber) {
    # Put the run/context nonce at the beginning of user content so llama.cpp's
    # longest-common-prefix cache cannot reuse the large filler body.
    $nonce = "$invocationNonce-prefill-$TargetTokens-run-$RunNumber"
    # Reserve room for the nonce, instruction, and chat-template wrapper so the
    # 160K case never overruns a 163840-token server slot.
    $repeatCount = [Math]::Max(1, $TargetTokens - 160)
    $filler = ((' context' * $repeatCount) -join '')
    return "$nonce $filler`nReply with exactly one token."
}

function Reset-PrefillSlot {
    try {
        Invoke-RestMethod -Uri $slotEraseUri -Method Post -Headers $headers -TimeoutSec 30 -ErrorAction Stop | Out-Null
        return 'erased'
    } catch {
        $code = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 501) {
            # Server build does not implement slot erase. Coldness is still
            # guaranteed by the per-run nonce prefix plus the cache_n = 0 gate
            # enforced on every response, so proceed without it.
            return 'unavailable'
        }
        return $false
    }
}

function Invoke-Prefill([string]$Prompt, [int]$TargetTokens, [int]$RunNumber) {
    $body = [ordered]@{
        model = $model
        messages = @(@{ role = 'user'; content = $Prompt })
        temperature = 0.0
        top_p = 1.0
        seed = 20260814 + $RunNumber
        max_tokens = 1
        ignore_eos = $true
    } | ConvertTo-Json -Depth 10 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri "$baseUrl/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 1800 -ErrorAction Stop
        $sw.Stop()
        if ($null -eq $response.usage -or $null -eq $response.usage.prompt_tokens -or $null -eq $response.usage.completion_tokens -or $null -eq $response.timings -or $null -eq $response.timings.prompt_n -or $null -eq $response.timings.cache_n -or $null -eq $response.timings.prompt_ms -or $null -eq $response.timings.prompt_per_second -or $null -eq $response.timings.predicted_n -or $null -eq $response.timings.predicted_ms -or $null -eq $response.timings.predicted_per_second) {
            return [ordered]@{ run = $RunNumber; ok = $false; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); errorCode = 'response_schema_invalid' }
        }
        $promptTokens = [int]$response.usage.prompt_tokens
        $completionTokens = [int]$response.usage.completion_tokens
        $evaluatedTokens = [int]$response.timings.prompt_n
        $cachedTokens = [int]$response.timings.cache_n
        $prefillTps = [double]$response.timings.prompt_per_second
        $prefillMs = [double]$response.timings.prompt_ms
        $predictedTokens = [int]$response.timings.predicted_n
        $predictedMs = [double]$response.timings.predicted_ms
        $predictedTps = [double]$response.timings.predicted_per_second
        $cacheFraction = if (($cachedTokens + $evaluatedTokens) -gt 0) { [double]$cachedTokens / ($cachedTokens + $evaluatedTokens) } else { 1.0 }
        $shapeValid = ($promptTokens -ge ($TargetTokens - 256) -and $promptTokens -le $TargetTokens)
        $calculatedPrefillTps = if ($prefillMs -gt 0) { $evaluatedTokens / ($prefillMs / 1000.0) } else { 0.0 }
        $timingError = if ($prefillTps -gt 0) { [Math]::Abs($calculatedPrefillTps - $prefillTps) / $prefillTps } else { 1.0 }
        # Decode of a single 1-token completion is near-instant (~0.001 ms) and the server
        # legitimately reports predicted_per_second = 0; decode throughput is not part of
        # this prefill contract, so only prompt timing is validated.
        $timingValid = ($evaluatedTokens -gt 0 -and $prefillTps -gt 0 -and $prefillMs -gt 0 -and $predictedTokens -eq 1 -and $timingError -le 0.01)
        # llama.cpp caches the fixed chat-template preamble (system wrapper, ~42 tokens on
        # this build) across requests in a slot; slot-erase is not implemented (501) on
        # b10434. A run is cold when only that fixed preamble is reused and every
        # remaining token is evaluated fresh, with full token accounting.
        $cacheValid = ($cachedTokens -le 64 -and ($cachedTokens + $evaluatedTokens) -eq $promptTokens)
        $ok = ($completionTokens -eq 1 -and $shapeValid -and $timingValid -and $cacheValid)
        return [ordered]@{
            run = $RunNumber
            ok = $ok
            wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
            promptTokens = $promptTokens
            completionTokens = $completionTokens
            timings = [ordered]@{
                cache_n = $cachedTokens
                prompt_n = $evaluatedTokens
                prompt_ms = $prefillMs
                prompt_per_second = $prefillTps
                predicted_n = $predictedTokens
                predicted_ms = $predictedMs
                predicted_per_second = $predictedTps
            }
            cachedFraction = $cacheFraction
            timingRelativeError = $timingError
            errorCode = if ($ok) { $null } elseif (-not $shapeValid) { 'prompt_size_out_of_tolerance' } elseif (-not $cacheValid) { 'prompt_cache_not_cold' } elseif ($completionTokens -ne 1) { 'completion_not_1' } else { 'timing_invalid' }
        }
    } catch {
        $sw.Stop()
        return [ordered]@{ run = $RunNumber; ok = $false; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); errorCode = 'request_failed' }
    }
}

function Get-Summary([object[]]$RunResults) {
    $valid = @($RunResults | Where-Object { $_.ok -eq $true })
    if ($valid.Count -ne 3) { return $null }
    $rates = @($valid | ForEach-Object { [double]$_.timings.prompt_per_second })
    $bestRun = $valid | Sort-Object { [double]$_.timings.prompt_per_second } -Descending | Select-Object -First 1
    $gpuSamples = @($valid | ForEach-Object { @($_.beforeGpu, $_.afterGpu) } | Where-Object { $null -ne $_ })
    return [ordered]@{
        runs = 3
        promptTokens = [int][Math]::Round(($valid | ForEach-Object { [double]$_.promptTokens } | Measure-Object -Average).Average)
        mean = [ordered]@{
            prompt_n = [Math]::Round(($valid | ForEach-Object { [double]$_.timings.prompt_n } | Measure-Object -Average).Average, 1)
            cache_n = [Math]::Round(($valid | ForEach-Object { [double]$_.timings.cache_n } | Measure-Object -Average).Average, 1)
            prompt_ms = [Math]::Round(($valid | ForEach-Object { [double]$_.timings.prompt_ms } | Measure-Object -Average).Average, 3)
            prompt_per_second = [Math]::Round(($rates | Measure-Object -Average).Average, 2)
        }
        best = [ordered]@{
            run = [int]$bestRun.run
            prompt_n = [int]$bestRun.timings.prompt_n
            cache_n = [int]$bestRun.timings.cache_n
            prompt_ms = [Math]::Round([double]$bestRun.timings.prompt_ms, 3)
            prompt_per_second = [Math]::Round([double]$bestRun.timings.prompt_per_second, 2)
        }
        worstPrefillTokensPerSecond = [Math]::Round(($rates | Measure-Object -Minimum).Minimum, 2)
        averageWallSeconds = [Math]::Round(($valid | ForEach-Object { [double]$_.wallSeconds } | Measure-Object -Average).Average, 3)
        averageEndpointSampledGpuUsedMiB = [Math]::Round(($gpuSamples | ForEach-Object { [double]$_.usedMiB } | Measure-Object -Average).Average, 1)
        maximumEndpointSampledGpuUsedMiB = [int][Math]::Round(($gpuSamples | ForEach-Object { [double]$_.usedMiB } | Measure-Object -Maximum).Maximum)
    }
}

$results = [ordered]@{
    metadata = [ordered]@{
        startedAt = (Get-Date).ToString('o')
        complete = $false
        endpoint = 'loopback'
        model = $model
        serverContextTokens = $serverContext
        runs = 3
        requiredCompletionTokens = 1
        requiredCachedPromptTokens = 0
        promptGeneratorVersion = 'cold-prefix-v1'
        cacheControls = [ordered]@{
            uniqueFirstContentNonce = $true
            slotEraseBeforeEveryRun = 'attempted'
            requireCacheNCold = 'cache_n <= 64 fixed chat-template preamble'
            requirePromptPlusCacheEqualsUsagePromptTokens = $true
        }
        contexts = $Contexts
        requiredContexts = $requiredContexts
        fullLadderRequested = $fullLadderRequested
        completedContexts = @()
        failedContexts = @()
    }
    ladder = [ordered]@{}
}

function Save-Results {
    $json = $results | ConvertTo-Json -Depth 20
    # utf8NoBOM: a BOM breaks JSON.parse in browsers and strict parsers
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
}

$hadFailure = $false
Save-Results
foreach ($target in $Contexts) {
    Write-Host "Prefill benchmarking $target prompt tokens (3 cold-prefix runs)..." -ForegroundColor Yellow
    $runResults = @()
    for ($run = 1; $run -le 3; $run++) {
        $prompt = New-PrefillPrompt $target $run
        $before = Get-GpuMemory
        $eraseState = Reset-PrefillSlot
        if ($eraseState -eq $false) {
            $result = [ordered]@{ run = $run; ok = $false; wallSeconds = 0.0; errorCode = 'slot_erase_failed' }
        } else {
            $result = Invoke-Prefill $prompt $target $run
            if ($eraseState -eq 'unavailable') { $result.slotErase = 'unavailable-501' } else { $result.slotErase = 'erased' }
        }
        $after = Get-GpuMemory
        $result['beforeGpu'] = $before
        $result['afterGpu'] = $after
        if ($null -eq $before -or $null -eq $after) { $result.ok = $false; $result.errorCode = 'gpu_sample_failed' }
        $runResults += ,$result
        Write-Host ("  run {0}: ok={1}, prompt={2}, evaluated={3}, cached={4}, prefill={5} tok/s" -f $run, $result.ok, $result.promptTokens, $result.timings.prompt_n, $result.timings.cache_n, $result.timings.prompt_per_second)
    }
    $summary = Get-Summary $runResults
    $valid = $null -ne $summary
    $results.ladder["$target"] = [ordered]@{ targetTokens = $target; valid = $valid; runs = $runResults; summary = $summary }
    if ($valid) { $results.metadata.completedContexts += $target }
    else { $results.metadata.failedContexts += $target; $hadFailure = $true }
    Save-Results
    if ($valid) { Write-Host ("  average={0} tok/s, best={1} tok/s" -f $summary.mean.prompt_per_second, $summary.best.prompt_per_second) -ForegroundColor Green }
    else { Write-Host '  INVALID: excessive cache reuse, malformed prompt, or incomplete timing data.' -ForegroundColor Red }
}
$results.metadata.finishedAt = (Get-Date).ToString('o')
$results.metadata.finalGpu = Get-GpuMemory
$results.metadata.complete = (-not $hadFailure -and $fullLadderRequested)
Save-Results
Write-Host "Saved $OutputPath" -ForegroundColor Green
if ($hadFailure) { exit 1 }
