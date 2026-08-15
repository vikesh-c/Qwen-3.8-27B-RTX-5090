$ErrorActionPreference = 'Stop'

function Get-CimInstance {
    param(
        [string]$ClassName,
        [string]$Filter,
        [string]$ErrorAction
    )

    [pscustomobject]@{
        ProcessId = 4242
        Name = 'llama-server.exe'
        CommandLine = 'llama-server.exe --port 8080'
    }
}

. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$processes = @(Get-RecipeProcesses)
if ($processes.Count -ne 1 -or $processes[0].ProcessId -ne 4242) {
    throw 'Single-process discovery returned an unexpected result.'
}

Write-Host 'Process discovery regression test passed.'
