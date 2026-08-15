[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$loaded = Read-RecipeConfig -ConfigPath $ConfigPath
$cfg = $loaded.Data
$binary = Get-RecipeRuntimePath $cfg
$model = Get-RecipeModelPath $cfg
$stateDir = Resolve-RecipeRelativePath -RelativePath ([string](Get-RecipeProperty $cfg 'stateRelativePath')) -Label 'state directory'
$matching = @(Get-RecipeProcesses | Where-Object { Test-RecipeProcessMatch $_ $binary $model })
if ($matching.Count -eq 0) {
    Remove-Item -LiteralPath (Join-Path $stateDir 'process.json') -Force -ErrorAction SilentlyContinue
    [ordered]@{ status = 'not_running' } | ConvertTo-Json -Compress
    exit 0
}
if ($matching.Count -gt 1) { throw "Found $($matching.Count) matching Qwen3.8 processes; refusing ambiguous stop." }
$targetPid = [int]$matching[0].ProcessId
Stop-Process -Id $targetPid -ErrorAction Stop
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath (Join-Path $stateDir 'process.json') -Force -ErrorAction SilentlyContinue
        [ordered]@{ status = 'stopped'; pid = $targetPid } | ConvertTo-Json -Compress
        exit 0
    }
}
if ($Force) {
    Stop-Process -Id $targetPid -Force -ErrorAction Stop
    Remove-Item -LiteralPath (Join-Path $stateDir 'process.json') -Force -ErrorAction SilentlyContinue
    [ordered]@{ status = 'force_stopped'; pid = $targetPid } | ConvertTo-Json -Compress
    exit 0
}
throw "Qwen3.8 PID $targetPid did not exit gracefully; refusing implicit force stop."
