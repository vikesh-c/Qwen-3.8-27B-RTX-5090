param(
    [int]$TargetTokens = (255 * 1024),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\common.ps1')

if ($TargetTokens -lt 1 -or $TargetTokens -gt (255 * 1024)) {
    throw 'TargetTokens must be between 1 and 245760 so the chat wrapper and one completion token remain below the 262144-token server limit.'
}

$baseUrl = if ([string]::IsNullOrWhiteSpace($env:QWEN_BASE_URL)) { 'http://127.0.0.1:8080/v1' } else { $env:QWEN_BASE_URL.TrimEnd('/') }
try { $baseUri = [Uri]$baseUrl } catch { throw 'QWEN_BASE_URL must be a valid URI.' }
if ($baseUri.Scheme -ne 'http' -or $baseUri.Host -ne '127.0.0.1' -or $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
    throw 'QWEN_BASE_URL must be an http loopback URL without credentials, query, or fragment.'
}

$model = if ([string]::IsNullOrWhiteSpace($env:QWEN_MODEL_ID)) { 'qwen3.8-27b' } else { $env:QWEN_MODEL_ID }
if ($model -match '[\/:]') { throw 'QWEN_MODEL_ID must be an identifier, not a filesystem path.' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $env:TEMP ('qwen38-27b-rtx5090-prefill-near-limit-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$cfg = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\profile.example.json') -Raw | ConvertFrom-Json
$api = Get-RecipeKey $cfg
$headers = @{ Authorization = "Bearer $($api.Value)"; 'Content-Type' = 'application/json' }
$propsBuilder = New-Object System.UriBuilder($baseUri)
$propsBuilder.Path = '/props'
$propsBuilder.Query = ''
$props = Invoke-RestMethod -Uri $propsBuilder.Uri.AbsoluteUri -Headers $headers -TimeoutSec 10 -ErrorAction Stop
$serverContext = [int]$props.default_generation_settings.n_ctx
if ($serverContext -ne 262144) { throw "The near-limit capacity check requires a 262144-token server; detected $serverContext." }

$slotBuilder = New-Object System.UriBuilder($baseUri)
$slotBuilder.Path = '/slots/0'
$slotBuilder.Query = 'action=erase'

function Get-GpuMemory {
    try {
        $gpu = Get-QwenGpuInfo
        return [ordered]@{ name = $gpu.name; usedMiB = $gpu.usedMiB; totalMiB = $gpu.totalMiB; freeMiB = $gpu.freeMiB }
    } catch { return $null }
}

$startedAt = (Get-Date).ToString('o')
$nonce = [Guid]::NewGuid().ToString('N')
$repeatCount = [Math]::Max(1, $TargetTokens - 160)
$filler = ((' context' * $repeatCount) -join '')
$prompt = "$nonce-prefill-$TargetTokens-run-1 $filler`nReply with exactly one token."
$beforeGpu = Get-GpuMemory
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    Invoke-RestMethod -Uri $slotBuilder.Uri.AbsoluteUri -Method Post -Headers $headers -TimeoutSec 30 -ErrorAction Stop | Out-Null
    $body = [ordered]@{
        model = $model
        messages = @(@{ role = 'user'; content = $prompt })
        temperature = 0.0
        top_p = 1.0
        seed = 20260809
        max_tokens = 1
        ignore_eos = $true
    } | ConvertTo-Json -Depth 10 -Compress
    $response = Invoke-RestMethod -Uri "$baseUrl/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 1800 -ErrorAction Stop
    $sw.Stop()

    $promptTokens = [int]$response.usage.prompt_tokens
    $completionTokens = [int]$response.usage.completion_tokens
    $promptN = [int]$response.timings.prompt_n
    $cacheN = [int]$response.timings.cache_n
    $promptMs = [double]$response.timings.prompt_ms
    $promptPerSecond = [double]$response.timings.prompt_per_second
    $shapeValid = ($promptTokens -ge ($TargetTokens - 256) -and $promptTokens -le $TargetTokens)
    $valid = ($completionTokens -eq 1 -and $shapeValid -and $cacheN -eq 0 -and $promptN -eq $promptTokens -and $promptMs -gt 0 -and $promptPerSecond -gt 0)
    $run = [ordered]@{
        ok = $valid
        wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
        promptTokens = $promptTokens
        completionTokens = $completionTokens
        timings = [ordered]@{
            cache_n = $cacheN
            prompt_n = $promptN
            prompt_ms = $promptMs
            prompt_per_second = $promptPerSecond
            predicted_n = [int]$response.timings.predicted_n
            predicted_ms = [double]$response.timings.predicted_ms
            predicted_per_second = [double]$response.timings.predicted_per_second
        }
        beforeGpu = $beforeGpu
        afterGpu = Get-GpuMemory
        errorCode = if ($valid) { $null } else { 'validation_failed' }
    }
} catch {
    $sw.Stop()
    $valid = $false
    $run = [ordered]@{
        ok = $false
        wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
        beforeGpu = $beforeGpu
        afterGpu = Get-GpuMemory
        errorCode = 'request_failed'
    }
}

if ($null -eq $run.beforeGpu -or $null -eq $run.afterGpu) {
    $valid = $false
    $run.ok = $false
    $run.errorCode = 'gpu_sample_failed'
}

$result = [ordered]@{
    metadata = [ordered]@{
        startedAt = $startedAt
        finishedAt = (Get-Date).ToString('o')
        complete = $valid
        benchmarkType = 'single cold-prefill near-limit capacity check'
        endpoint = 'loopback'
        model = $model
        targetTokens = $TargetTokens
        targetDefinition = if ($TargetTokens -eq (255 * 1024)) { '255 * 1024' } else { 'custom' }
        serverContextTokens = $serverContext
        requiredCompletionTokens = 1
        requiredCachedPromptTokens = 0
        cacheControls = [ordered]@{
            uniqueFirstContentNonce = $true
            slotEraseBeforeRequest = $true
            requireCacheNZero = $true
            requirePromptNEqualsUsagePromptTokens = $true
        }
    }
    run = $run
}
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Saved $OutputPath" -ForegroundColor Green
if (-not $valid) { exit 1 }
