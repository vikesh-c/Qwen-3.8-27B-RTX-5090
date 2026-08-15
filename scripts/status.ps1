[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$loaded = Read-RecipeConfig -ConfigPath $ConfigPath
$cfg = $loaded.Data
$root = Get-RecipeRoot
$hostName = [string](Get-RecipeProperty $cfg 'host' '127.0.0.1')
$configuredPort = [int](Get-RecipeProperty $cfg 'port' 8080)
if ($Port -eq 0) { $Port = $configuredPort }
Assert-RecipeLoopback $hostName
Assert-RecipePort $Port
$modelId = [string](Get-RecipeProperty $cfg 'modelId' 'qwen3.8-27b')
$binary = Get-RecipeRuntimePath $cfg
$model = Get-RecipeModelPath $cfg
$errors = New-Object System.Collections.Generic.List[string]
$key = $null
try { $key = Get-RecipeKey $cfg } catch { $errors.Add('api_key_source_failed') }
$headers = if ($key) { Get-RecipeHeaders $key } else { @{} }
$base = "http://127.0.0.1`:$Port"
$health = $null; $props = $null; $models = $null
try { $health = Invoke-RestMethod -Uri "$base/health" -Headers $headers -TimeoutSec 10 -ErrorAction Stop } catch { $errors.Add('health_request_failed') }
try { $props = Invoke-RestMethod -Uri "$base/props" -Headers $headers -TimeoutSec 10 -ErrorAction Stop } catch { $errors.Add('props_request_failed') }
try { $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 10 -ErrorAction Stop } catch { $errors.Add('models_request_failed') }

$processes = @(Get-RecipeProcesses)
$matching = @($processes | Where-Object { Test-RecipeProcessMatch $_ $binary $model })
if ($matching.Count -ne 1) { $errors.Add("matching_process_count_$($matching.Count)") }
if ($processes.Count -gt 1) { $errors.Add('multiple_llama_server_processes') }
$commandLine = if ($matching.Count -eq 1) { [string]$matching[0].CommandLine } else { '' }
$visionTemplate = [bool]($props -and $props.chat_template -and ([string]$props.chat_template).Contains('<|image_pad|>'))
$visionMmproj = $commandLine -match '(?i)(^|\s)--mmproj(\s|$)'
$vision = [bool](($props -and $props.is_vision -eq $true) -or ($visionTemplate -and $visionMmproj))
if (-not $vision) { $errors.Add('vision_signal_missing') }
$mtp = [bool]($commandLine -match '(?i)--spec-type\s+draft-mtp')
$kv = [bool]($commandLine -match '(?i)--cache-type-k\s+q8_0' -and $commandLine -match '(?i)--cache-type-v\s+q8_0')
if (-not $kv) { $errors.Add('q8_kv_flags_missing') }
$reportedModel = if ($models -and $models.data) { [string]$models.data[0].id } else { $null }
if ($reportedModel -ne $modelId) { $errors.Add('model_identity_mismatch') }
$reportedContext = if ($props) { [int]$props.default_generation_settings.n_ctx } else { $null }
if ($reportedContext -ne [int](Get-RecipeProperty $cfg 'context' 262144)) { $errors.Add('context_mismatch') }
$gpu = $null
try { $gpu = Get-RecipeGpuInfo } catch { $errors.Add('gpu_probe_failed') }

[ordered]@{
    ok = ($errors.Count -eq 0 -and $health -and $health.status -eq 'ok')
    endpoint = $base
    health = if ($health) { [string]$health.status } else { $null }
    model = $reportedModel
    context = $reportedContext
    vision = $vision
    visionSignal = if ($props -and $props.is_vision -eq $true) { 'props.is_vision' } elseif ($visionTemplate -and $visionMmproj) { 'chat_template_image_pad+mmproj_arg' } else { $null }
    mtp = $mtp
    q8Kv = $kv
    pid = if ($matching.Count -eq 1) { [int]$matching[0].ProcessId } else { $null }
    build = if ($props) { [string]$props.build_info } else { $null }
    gpu = if ($gpu) { [ordered]@{ name = $gpu.name; usedMiB = $gpu.usedMiB; totalMiB = $gpu.totalMiB; freeMiB = $gpu.freeMiB } } else { $null }
    errors = @($errors)
} | ConvertTo-Json -Depth 10
if ($errors.Count -gt 0) { exit 1 }
