[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$loaded = Read-RecipeConfig -ConfigPath $ConfigPath
$cfg = $loaded.Data
$root = Get-RecipeRoot

$hostName = [string](Get-RecipeProperty $cfg 'host' '127.0.0.1')
$port = [int](Get-RecipeProperty $cfg 'port' 8080)
$context = [int](Get-RecipeProperty $cfg 'context' 262144)
$maxContext = [int](Get-RecipeProperty $cfg 'maxContext' 262144)
$parallel = [int](Get-RecipeProperty $cfg 'parallel' 1)
Assert-RecipeLoopback $hostName
Assert-RecipePort $port
if ($context -lt 1 -or $context -gt $maxContext -or $maxContext -gt 262144) { throw 'Context exceeds the pinned Qwen3.8 262144-token profile.' }
if ($parallel -ne 1) { throw 'This recipe is serial one-model-at-a-time; parallel must be 1.' }
$gpu = Assert-RecipeGpu

$binary = Get-RecipeRuntimePath $cfg
$model = Get-RecipeModelPath $cfg
$mmproj = Get-RecipeMmprojPath $cfg
# Chat template: use the bootstrap-downloaded Froggeric v22 template when present;
# fall back to the model's embedded HF template (--jinja alone).
$modelsRoot = Split-Path -Parent (Split-Path -Parent $mmproj)
$templatePath = Join-Path $modelsRoot 'chat_templates\chat_template.jinja'
if (-not (Test-Path $templatePath)) {
    Write-Host "Chat template not found at $templatePath - using the model's embedded template."
    $templatePath = $null
}
$manifestPath = Get-RecipeRuntimeManifestPath $cfg
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$artifacts = Get-RecipeProperty $cfg 'artifacts'
$null = Assert-RecipeSha256 -Path $binary -Expected ([string]$manifest.binarySha256) -Label 'llama-server'
$null = Assert-RecipeSha256 -Path $model -Expected ([string]$artifacts.modelSha256) -Label 'model'
$null = Assert-RecipeSha256 -Path $mmproj -Expected ([string]$artifacts.mmprojSha256) -Label 'vision projector'
# Chat template: bootstrap downloads the Froggeric v22 fixed template (hash-pinned); if absent, the embedded GGUF template is used.
$key = Get-RecipeKey $cfg

$base = "http://127.0.0.1`:$port"
$headers = Get-RecipeHeaders $key

$logDir = Resolve-RecipeRelativePath -RelativePath ([string](Get-RecipeProperty $cfg 'logRelativePath')) -Label 'log directory'
$stateDir = Resolve-RecipeRelativePath -RelativePath ([string](Get-RecipeProperty $cfg 'stateRelativePath')) -Label 'state directory'
New-Item -ItemType Directory -Force -Path $logDir,$stateDir | Out-Null
$logPath = Join-Path $logDir ("qwen3.8-27b-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$modelId = [string](Get-RecipeProperty $cfg 'modelId' 'qwen3.8-27b')
$mtp = Get-RecipeProperty $cfg 'mtp'
$enableMtp = $true # MTP-only recipe: speculative decoding is always on
$sampling = Get-RecipeProperty $cfg 'sampling'
$thinking = Get-RecipeProperty $sampling 'thinking'
$flashAttention = if ([bool](Get-RecipeProperty $cfg 'flashAttention' $true)) { 'on' } else { 'off' }

$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":true,"preserve_thinking":true}'
$env:LLAMA_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":true,"preserve_thinking":true}'
$arguments = @(
    '-m', $model,
    '--alias', $modelId,
    '--device', [string](Get-RecipeProperty $cfg 'device' 'CUDA0'),
    '--split-mode', 'none',
    '-ngl', '99',
    '-c', $context,
    '-np', $parallel,
    '-fa', $flashAttention,
    '--jinja',
    '--cache-type-k', [string](Get-RecipeProperty $cfg 'cacheK' 'q8_0'),
    '--cache-type-v', [string](Get-RecipeProperty $cfg 'cacheV' 'q8_0'),
    '--host', $hostName,
    '--port', $port,
    '--api-key-file', $key.SourcePath,
    '--log-file', $logPath,
    '--log-timestamps',
    '--temp', [string](Get-RecipeProperty $thinking 'temperature' 1.0),
    '--top-p', [string](Get-RecipeProperty $thinking 'topP' 0.95),
    '--min-p', [string](Get-RecipeProperty $thinking 'minP' 0.0),
    '--presence-penalty', [string](Get-RecipeProperty $thinking 'presencePenalty' 0.0),
    '--repeat-penalty', [string](Get-RecipeProperty $thinking 'repetitionPenalty' 1.0),
    '--top-k', [string](Get-RecipeProperty $thinking 'topK' 20),
    '--reasoning', 'on',
    '--reasoning-format', 'auto',
    '--reasoning-preserve',
    '-b', [string](Get-RecipeProperty $cfg 'batch' 256),
    '-ub', [string](Get-RecipeProperty $cfg 'ubatch' 256),
    '--mmproj', $mmproj
)
if ($null -ne $templatePath -and (Test-Path $templatePath)) {
    $arguments += @('--chat-template-file', $templatePath)
}
if ($enableMtp) {
    $arguments += @('--spec-type', [string](Get-RecipeProperty $mtp 'type' 'draft-mtp'), '--spec-draft-n-max', [string](Get-RecipeProperty $mtp 'draftNMax' 2), '--spec-draft-p-min', [string](Get-RecipeProperty $mtp 'draftPMin' 0.0))
}
$quoted = $arguments | ForEach-Object {
    $s = [string]$_
    if ($s -match '[\s"]') { '"' + $s.Replace('"', '\"') + '"' } else { $s }
}
$argumentString = $quoted -join ' '
$sha = [Security.Cryptography.SHA256]::Create()
try { $argumentsSha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($argumentString)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }

if ($DryRun) {
    [ordered]@{
        mode = 'dry-run'
        modelId = $modelId
        context = $context
        loopback = "$hostName`:$port"
        mtp = $enableMtp
        argumentCount = $arguments.Count
        argumentsSha256 = $argumentsSha256
        gpu = [ordered]@{ name = $gpu.name; totalMiB = $gpu.totalMiB }
        keySourceConfigured = $true
    } | ConvertTo-Json -Depth 8
    exit 0
}

$existingHealthy = $false
try {
    $h = Invoke-RestMethod -Uri "$base/health" -Headers $headers -TimeoutSec 5 -ErrorAction Stop
    $existingHealthy = ($h.status -eq 'ok')
} catch { }
if ($existingHealthy) { throw "A healthy endpoint already owns $base; refusing to start a second model." }
$allProcesses = Get-RecipeProcesses
if ($allProcesses.Count -gt 0) { throw "Found $($allProcesses.Count) llama-server.exe process(es); stop the exact owner before launch." }

$proc = $null
$ready = $false
try {
    $proc = Start-Process -FilePath $binary -ArgumentList $argumentString -WorkingDirectory $root -WindowStyle Hidden -PassThru
    $state = [ordered]@{ pid = [int]$proc.Id; binary = $binary; model = $model; mtp = $enableMtp; startedAt = (Get-Date).ToString('o'); argumentsSha256 = $argumentsSha256 }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateDir 'process.json') -Encoding ascii
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { throw 'llama-server exited during startup.' }
        try {
            $health = Invoke-RestMethod -Uri "$base/health" -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            if ($health.status -eq 'ok') {
                $props = Invoke-RestMethod -Uri "$base/props" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
                $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
                if ([int]$props.default_generation_settings.n_ctx -ne $context) { throw 'Healthy endpoint context does not match the profile.' }
                if (-not $models.data -or [string]$models.data[0].id -ne $modelId) { throw 'Healthy endpoint model identity does not match the profile.' }
                $ready = $true
                [ordered]@{ status = 'ready'; pid = [int]$proc.Id; model = $modelId; context = $context; mtp = $enableMtp; endpoint = $base } | ConvertTo-Json -Compress
                break
            }
        } catch { }
    }
    if (-not $ready) { throw 'Timed out waiting for a healthy llama-server response.' }
} finally {
    if (-not $ready -and $null -ne $proc) {
        Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath (Join-Path $stateDir 'process.json') -Force -ErrorAction SilentlyContinue
    }
}
exit 0
