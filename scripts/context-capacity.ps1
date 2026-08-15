[CmdletBinding()]
param(
    [ValidateRange(1,261120)][int]$TargetTokens = 245760,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$loaded = Read-RecipeConfig -ConfigPath $ConfigPath
$cfg = $loaded.Data
Assert-RecipeLoopback ([string](Get-RecipeProperty $cfg 'host' '127.0.0.1'))
$port = [int](Get-RecipeProperty $cfg 'port' 8080)
Assert-RecipePort $port
$key = Get-RecipeKey $cfg
$headers = Get-RecipeHeaders $key
$base = "http://127.0.0.1`:$port/v1"
$modelId = [string](Get-RecipeProperty $cfg 'modelId' 'qwen3.8-27b')
$props = Invoke-RestMethod -Uri "http://127.0.0.1`:$port/props" -Headers $headers -TimeoutSec 15 -ErrorAction Stop
$serverContext = [int]$props.default_generation_settings.n_ctx
if ($serverContext -ne 262144) { throw "Expected n_ctx=262144; detected $serverContext." }

function Get-CapacityGpu {
    try {
        $gpu = Get-RecipeGpuInfo
        return [ordered]@{ name = $gpu.name; usedMiB = $gpu.usedMiB; totalMiB = $gpu.totalMiB; freeMiB = $gpu.freeMiB }
    } catch { return $null }
}

$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$nonce = [Guid]::NewGuid().ToString('N')
$repeatCount = [Math]::Max(1, $TargetTokens - 160)
$filler = (' context' * $repeatCount)
$prompt = "$nonce-qwen38-prefill-$TargetTokens $filler`nReply with exactly one token."
$beforeGpu = Get-CapacityGpu
$slotEraseStatus = $null
$slotEraseSupported = $false
try {
    $erase = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1`:$port/slots/0?action=erase" -Method Post -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $slotEraseStatus = [int]$erase.StatusCode
    $slotEraseSupported = $true
} catch {
    if ($_.Exception.Response) { $slotEraseStatus = [int]$_.Exception.Response.StatusCode }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$valid = $false
$run = [ordered]@{}
try {
    $body = [ordered]@{
        model = $modelId
        messages = @(@{ role = 'user'; content = $prompt })
        temperature = 0.0
        top_p = 1.0
        top_k = 20
        min_p = 0.0
        seed = 20260814
        max_tokens = 1
        ignore_eos = $true
        cache_prompt = $false
        chat_template_kwargs = [ordered]@{ enable_thinking = $false; preserve_thinking = $true }
    } | ConvertTo-Json -Depth 12 -Compress
    $response = Invoke-RestMethod -Uri "$base/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 1800 -ErrorAction Stop
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
        shapeValid = $shapeValid
        timings = [ordered]@{ cache_n = $cacheN; prompt_n = $promptN; prompt_ms = $promptMs; prompt_per_second = $promptPerSecond; predicted_n = [int]$response.timings.predicted_n; predicted_ms = [double]$response.timings.predicted_ms; predicted_per_second = [double]$response.timings.predicted_per_second }
        beforeGpu = $beforeGpu
        afterGpu = Get-CapacityGpu
        errorCode = if ($valid) { $null } else { 'validation_failed' }
    }
} catch {
    $sw.Stop()
    $run = [ordered]@{ ok = $false; wallSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3); beforeGpu = $beforeGpu; afterGpu = Get-CapacityGpu; errorCode = 'request_failed' }
}
if ($null -eq $run.beforeGpu -or $null -eq $run.afterGpu) { $valid = $false; $run.ok = $false; $run.errorCode = 'gpu_sample_failed' }
$parent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$result = [ordered]@{
    schema = 1
    kind = 'qwen38-context-capacity-near-limit'
    metadata = [ordered]@{ startedAt = $startedAt; finishedAt = (Get-Date).ToUniversalTime().ToString('o'); complete = $valid; benchmarkType = 'single cold-prefill near-limit capacity check'; endpoint = 'loopback'; model = $modelId; targetTokens = $TargetTokens; serverContextTokens = $serverContext; requiredCompletionTokens = 1; cacheControls = [ordered]@{ requestCachePrompt = $false; slotEraseAttempted = $true; slotEraseSupported = $slotEraseSupported; slotEraseObservedStatus = $slotEraseStatus; requireCacheNZero = $true; requirePromptNEqualsUsagePromptTokens = $true } }
    run = $run
}
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output (($result.metadata + [ordered]@{ output = $OutputPath }) | ConvertTo-Json -Compress)
if (-not $valid) { exit 1 }
