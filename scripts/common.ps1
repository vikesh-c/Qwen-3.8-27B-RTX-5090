$script:RecipeRoot = Split-Path -Parent $PSScriptRoot

function Get-RecipeRoot {
    return $script:RecipeRoot
}

function Get-RecipeExternalRoot {
    $configured = [Environment]::GetEnvironmentVariable('LOCAL_LLM_ROOT')
    if ([string]::IsNullOrWhiteSpace($configured)) { throw 'Set LOCAL_LLM_ROOT to the external artifact/runtime root.' }
    if ($configured.IndexOfAny([char[]]'*?[]') -ge 0) { throw 'LOCAL_LLM_ROOT must not contain wildcard characters.' }
    $external = [IO.Path]::GetFullPath($configured).TrimEnd('\\')
    $repo = [IO.Path]::GetFullPath($script:RecipeRoot).TrimEnd('\\')
    if ($external.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or $external.StartsWith($repo + '\\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LOCAL_LLM_ROOT must be outside the recipe repository.'
    }
    if (-not (Test-Path -LiteralPath $external -PathType Container)) { throw "LOCAL_LLM_ROOT does not exist: $external" }
    return $external
}

function Read-RecipeConfig {
    param([string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $script:RecipeRoot 'config\profile.example.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Recipe config not found: $ConfigPath"
    }
    try {
        return [pscustomobject]@{
            Path = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
            Data = (Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json)
        }
    } catch {
        throw "Unable to read recipe config '$ConfigPath': $($_.Exception.Message)"
    }
}

function Get-RecipeProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Resolve-RecipeRelativePath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label,
        [switch]$MustExist,
        [switch]$Directory
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw "$Label path is empty." }
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$Label must be relative to the recipe root: $RelativePath"
    }
    $path = Join-Path $script:RecipeRoot $RelativePath
    if ($MustExist -and -not (Test-Path -LiteralPath $path -PathType $(if ($Directory) { 'Container' } else { 'Leaf' }))) {
        throw "$Label does not exist: $path"
    }
    return [IO.Path]::GetFullPath($path)
}

function Resolve-RecipeExternalPath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label,
        [switch]$MustExist,
        [switch]$Directory
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw "$Label path is empty." }
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$Label must be relative to LOCAL_LLM_ROOT: $RelativePath"
    }
    $path = Join-Path (Get-RecipeExternalRoot) $RelativePath
    if ($MustExist -and -not (Test-Path -LiteralPath $path -PathType $(if ($Directory) { 'Container' } else { 'Leaf' }))) {
        throw "$Label does not exist: $path"
    }
    return [IO.Path]::GetFullPath($path)
}

function Assert-RecipeNotReparsePoint {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point: $Path"
    }
}

function Protect-RecipeApiKeyDirectory {
    param([Parameter(Mandatory)][string]$Path)
    Assert-RecipeNotReparsePoint -Path $Path -Label 'API key directory'
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($userSid)
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $none = [Security.AccessControl.PropagationFlags]::None
    $inherit = [Security.AccessControl.InheritanceFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($userSid, $systemSid, $adminSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, $none, $allow)
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
}

function Protect-RecipeApiKeyFile {
    param([Parameter(Mandatory)][string]$Path)
    Assert-RecipeNotReparsePoint -Path $Path -Label 'API key file'
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($userSid)
    $none = [Security.AccessControl.PropagationFlags]::None
    $inherit = [Security.AccessControl.InheritanceFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($userSid, $systemSid, $adminSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, $none, $allow)
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
}

function Assert-RecipeApiKeyAcl {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Path)
    Assert-RecipeNotReparsePoint -Path $Directory -Label 'API key directory'
    Assert-RecipeNotReparsePoint -Path $Path -Label 'API key file'
}

function Get-RecipeKey {
    param([Parameter(Mandatory)][object]$Config)
    $envName = [string](Get-RecipeProperty $Config 'apiKeyFileEnv' 'LLAMA_SERVER_API_KEY_FILE')
    if ($envName -notmatch '^[A-Z][A-Z0-9_]{1,127}$') { throw "Invalid API-key path environment variable name: $envName" }
    $configured = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ($configured.IndexOfAny([char[]]'*?[]') -ge 0) { throw "$envName must not contain wildcard characters." }
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) { throw "Configured $envName does not exist: $configured" }
        Assert-RecipeNotReparsePoint -Path $configured -Label 'Configured API key file'
        $values = @(Get-Content -LiteralPath $configured -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($values.Count -ne 1) { throw "API key file must contain exactly one non-empty line: $configured" }
        return [pscustomobject]@{ Value = [string]$values[0]; SourcePath = (Resolve-Path -LiteralPath $configured).ProviderPath }
    }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw "Windows LocalAppData is unavailable; set $envName explicitly." }
    $directory = Join-Path $localAppData 'Qwen3.8-27B-RTX-5090'
    $path = Join-Path $directory 'llama-server.key'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Protect-RecipeApiKeyDirectory -Path $directory
    }
    Assert-RecipeNotReparsePoint -Path $directory -Label 'API key directory'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $guid = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
        $bytes = [Text.Encoding]::ASCII.GetBytes($guid)
        $temp = Join-Path $directory ('.llama-server.key.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            Protect-RecipeApiKeyFile -Path $temp
            Move-Item -LiteralPath $temp -Destination $path -Force
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "Created a new 64-char API key at $path (ACL: user/SYSTEM/Administrators only)." -ForegroundColor Cyan
    }
    Assert-RecipeNotReparsePoint -Path $path -Label 'API key file'
    Assert-RecipeApiKeyAcl -Directory $directory -Path $path
    $values = @(Get-Content -LiteralPath $path -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -ne 1) { throw "API key file must contain exactly one non-empty line: $path" }
    return [pscustomobject]@{ Value = [string]$values[0]; SourcePath = (Resolve-Path -LiteralPath $path).ProviderPath }
}

function Assert-RecipeLoopback {
    param([Parameter(Mandatory)][string]$BindHost)
    if ($BindHost -ne '127.0.0.1') { throw "Only 127.0.0.1 is supported; refusing host '$BindHost'." }
}

function Assert-RecipePort {
    param([Parameter(Mandatory)][int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535; received $Port." }
}

function Get-RecipeGpuInfo {
    $line = & nvidia-smi --query-gpu=name,memory.used,memory.total,memory.free,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'nvidia-smi returned no GPU record.' }
    $parts = @($line -split ',')
    if ($parts.Count -lt 6) { throw 'nvidia-smi returned an incomplete GPU record.' }
    return [pscustomobject]@{
        name = $parts[0].Trim()
        usedMiB = [int]$parts[1].Trim()
        totalMiB = [int]$parts[2].Trim()
        freeMiB = [int]$parts[3].Trim()
        utilizationPercent = [int]$parts[4].Trim()
        temperatureC = [int]$parts[5].Trim()
    }
}

function Assert-RecipeGpu {
    $gpu = Get-RecipeGpuInfo
    if ($gpu.name -ne 'NVIDIA GeForce RTX 5090' -or $gpu.totalMiB -lt 32000) {
        throw "Measured recipe requires a 32 GiB NVIDIA GeForce RTX 5090; detected $($gpu.name) with $($gpu.totalMiB) MiB."
    }
    return $gpu
}

function Assert-RecipeSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Expected -notmatch '^[A-Fa-f0-9]{64}$') { throw "$Label SHA-256 is not pinned." }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) { throw "$Label SHA-256 mismatch." }
    return $actual
}

function Get-RecipeProcesses {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction Stop)
    } catch {
        throw "Unable to inspect llama-server processes; refusing to assume the endpoint is free. $($_.Exception.Message)"
    }
}

function Test-RecipeProcessMatch {
    param([Parameter(Mandatory)][object]$Process, [Parameter(Mandatory)][string]$Binary, [Parameter(Mandatory)][string]$Model)
    if ([string]::IsNullOrWhiteSpace([string]$Process.ExecutablePath) -or [string]::IsNullOrWhiteSpace([string]$Process.CommandLine)) { return $false }
    try {
        $sameBinary = [IO.Path]::GetFullPath([string]$Process.ExecutablePath).Equals([IO.Path]::GetFullPath($Binary), [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
    return $sameBinary -and ([string]$Process.CommandLine).IndexOf($Model, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-RecipeHeaders {
    param([Parameter(Mandatory)][object]$Key)
    return @{ Authorization = "Bearer $($Key.Value)"; 'Content-Type' = 'application/json' }
}

function Get-RecipeModelPath {
    param([Parameter(Mandatory)][object]$Config)
    return Resolve-RecipeExternalPath -RelativePath ([string](Get-RecipeProperty $Config 'modelRelativePath')) -Label 'model' -MustExist
}

function Get-RecipeMmprojPath {
    param([Parameter(Mandatory)][object]$Config)
    return Resolve-RecipeExternalPath -RelativePath ([string](Get-RecipeProperty $Config 'mmprojRelativePath')) -Label 'vision projector' -MustExist
}

function Get-RecipeRuntimePath {
    param([Parameter(Mandatory)][object]$Config)
    return Resolve-RecipeExternalPath -RelativePath ([string](Get-RecipeProperty $Config 'runtimeRelativePath')) -Label 'llama-server runtime' -MustExist
}

function Get-RecipeRuntimeManifestPath {
    param([Parameter(Mandatory)][object]$Config)
    return Resolve-RecipeExternalPath -RelativePath ([string](Get-RecipeProperty $Config 'runtimeManifestRelativePath')) -Label 'runtime manifest' -MustExist
}
