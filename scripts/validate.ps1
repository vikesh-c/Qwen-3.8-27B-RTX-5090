[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$errors = New-Object System.Collections.Generic.List[string]
function Add-Error([string]$Message) { $errors.Add($Message) }
function Read-Json([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { Add-Error "JSON parse failed: $Path"; return $null }
}

Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { Add-Error "PowerShell parse failed: $($_.FullName)" }
}
Get-ChildItem -LiteralPath $root -Recurse -Filter *.json -File | ForEach-Object { Read-Json $_.FullName | Out-Null }

$profilePath = Join-Path $root 'config\profile.example.json'
$profile = Read-Json $profilePath
if ($profile) {
    if ($profile.schema -ne 1 -or $profile.profile -ne 'qwen3.8-27b-rtx5090') { Add-Error 'Profile identity/schema is incorrect.' }
    if ($profile.host -ne '127.0.0.1' -or $profile.parallel -ne 1) { Add-Error 'Profile must remain loopback-only and single-slot.' }
    if ($profile.context -ne 262144 -or $profile.maxContext -ne 262144) { Add-Error 'Profile context must remain exactly 262144.' }
    if ($profile.cacheK -ne 'q8_0' -or $profile.cacheV -ne 'q8_0') { Add-Error 'Profile K/V cache must remain q8_0.' }
    if ($profile.mtp.enabled -ne $true -or $profile.mtp.type -ne 'draft-mtp' -or $profile.mtp.draftNMax -ne 2) { Add-Error 'Bundled MTP normal profile changed.' }
    foreach ($name in @('runtimeRelativePath','runtimeManifestRelativePath','modelRelativePath','mmprojRelativePath','logRelativePath','stateRelativePath')) {
        $value = [string]$profile.$name
        if ([IO.Path]::IsPathRooted($value) -or $value -match '(^|[\\/])\.\.([\\/]|$)') { Add-Error "Profile path is not portable: $name" }
    }
    foreach ($name in @('modelSha256','mmprojSha256')) {
        if ([string]$profile.artifacts.$name -notmatch '^[A-Fa-f0-9]{64}$') { Add-Error "Profile artifact hash is not SHA-256: $name" }
    }
}

$windowsUserPathPattern = '(?i)' + [regex]::Escape(('C:' + '\' + 'Users' + '\'))
$unixUserPathPattern = '(?i)' + [regex]::Escape(('/' + 'home' + '/')) + '|' + [regex]::Escape(('/' + 'root' + '/'))
$forbidden = @(
    '(?i)ghp_[A-Za-z0-9]{20,}',
    '(?i)github_pat_[A-Za-z0-9_]{20,}',
    '(?i)gho_[A-Za-z0-9]{20,}',
    '(?i)BEGIN (RSA|OPENSSH|PRIVATE) KEY',
    $windowsUserPathPattern,
    $unixUserPathPattern
)
$textExtensions = @('.ps1','.json','.md','.yml','.yaml','.txt','.license','')
$files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notlike "$(Join-Path $root '.git')\*" -and $_.FullName -notlike "$(Join-Path $root 'logs')\*" -and $_.FullName -notlike "$(Join-Path $root 'state')\*" -and $_.FullName -notlike "$(Join-Path $root 'local')\*" }
foreach ($item in $files) {
    $relative = $item.FullName.Substring($root.Length + 1).Replace('/','\')
    if ($relative -eq 'scripts\validate.ps1') { continue }
    if ($item.Length -gt 5242880) { Add-Error "Unexpectedly large file: $relative"; continue }
    if ($relative -match '(?i)(^|\\)(profile\.json|\.env($|\.)|.*\.(key|secret|token)$)') { Add-Error "Local-only secret/config file present: $relative"; continue }
    if ($item.Extension.ToLowerInvariant() -in @('.gguf','.exe','.dll','.zip','.log','.bin')) { Add-Error "Binary/log artifact present: $relative"; continue }
    if ($item.Extension.ToLowerInvariant() -notin $textExtensions -and $item.Name -ne '.gitignore') { continue }
    $text = Get-Content -LiteralPath $item.FullName -Raw
    foreach ($pattern in $forbidden) { if ($text -match $pattern) { Add-Error "Forbidden pattern in $relative"; break } }
}

if (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container) {
    $gitStdout = [IO.Path]::GetTempFileName()
    $gitStderr = [IO.Path]::GetTempFileName()
    try {
        $gitProc = Start-Process -FilePath 'git.exe' -ArgumentList @('-C', $root, 'diff', '--check') -RedirectStandardOutput $gitStdout -RedirectStandardError $gitStderr -Wait -PassThru -WindowStyle Hidden
        if ($gitProc.ExitCode -ne 0) { Add-Error 'git diff --check failed.' }
    } finally {
        Remove-Item -LiteralPath $gitStdout,$gitStderr -Force -ErrorAction SilentlyContinue
    }
}
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Output 'Repository validation passed.'
