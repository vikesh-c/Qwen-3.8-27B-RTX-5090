param(
    [string]$LocalRoot = $env:LOCAL_LLM_ROOT,
    [string]$ModelUrl = 'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/430473d9d0e975450ce1f445642b6527cb4faea1/Qwen3.8-27B-UD-Q4_K_XL.gguf?download=true',
    [string]$MmprojUrl = 'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/430473d9d0e975450ce1f445642b6527cb4faea1/mmproj-F16.gguf?download=true',
    [string]$ChatTemplateUrl = 'https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/resolve/9f14778c92c3b5ed3e0738085694c0d3452802dd/chat_template.jinja',
    [string]$LlamaReleaseApiUrl = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest',
    [string]$CudaVersion,
    [switch]$SkipRuntime,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest renders a progress bar per chunk in PS 5.1, which throttles
# large downloads to a fraction of line speed. Silencing progress restores it.
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($LocalRoot)) { throw 'Set LOCAL_LLM_ROOT or pass -LocalRoot to an external runtime directory.' }
if ($LocalRoot.IndexOfAny([char[]]'*?[]') -ge 0) { throw 'LocalRoot must not contain wildcard characters.' }
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$rootFull = [IO.Path]::GetFullPath($LocalRoot).TrimEnd('\')
$repoPrefix = $repoRoot + '\'
if ($rootFull.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or $rootFull.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'LocalRoot must be outside this repository; model weights and runtime binaries do not belong in Git.' }
New-Item -ItemType Directory -Force -Path $rootFull | Out-Null

function Assert-HttpsDownloadUrl {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Label)
    try { $uri = [Uri]$Url } catch { throw "$Label URL is invalid." }
    if ($uri.Scheme -ne 'https') { throw "$Label URL must use HTTPS." }
    $allowedHosts = @('api.github.com', 'github.com', 'huggingface.co')
    if ($allowedHosts -notcontains $uri.Host.ToLowerInvariant()) { throw "$Label URL host '$($uri.Host)' is not an approved source." }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Assert-Sha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected, [Parameter(Mandatory)][string]$Label)
    if ($Expected -notmatch '^[A-Fa-f0-9]{64}$') { throw "$Label SHA-256 is not valid." }
    $actual = Get-Sha256 $Path
    if ($actual -ne $Expected.ToUpperInvariant()) { throw "$Label SHA-256 mismatch. Expected $($Expected.ToUpperInvariant()), got $actual." }
}

function Invoke-HfCli {
    # Two Windows hazards around the HF CLI (huggingface_hub 1.x, Python 3.12):
    # 1. PowerShell 5.1 promotes native stderr (version hints, usage text) to
    #    terminating errors under EAP=Stop, which kills bootstrap. EAP is
    #    relaxed around the call; exit code + stdout decide the outcome.
    # 2. The CLI writes a UTF-8 check-mark to a cp1252 console and crashes
    #    with a charmap codec error unless Python is told to emit UTF-8.
    param([Parameter(Mandatory)][string[]]$HfArgs)
    $prevEap = $ErrorActionPreference
    $prevEncoding = [Console]::OutputEncoding
    $prevPythonIo = $env:PYTHONIOENCODING
    $ErrorActionPreference = 'Continue'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $env:PYTHONIOENCODING = 'utf-8'
    try {
        $out = & $script:hfPath @HfArgs 2>$null | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        [Console]::OutputEncoding = $prevEncoding
        if ($null -ne $prevPythonIo) { $env:PYTHONIOENCODING = $prevPythonIo } else { Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Assert-HuggingFaceAuth {
    # Hugging Face rate-limits anonymous downloads. The model is ~17 GB, so an
    # authenticated session (HF CLI token) is required for a reliable full-speed
    # download. Installs the CLI if missing and guides login when needed.
    $hf = Get-Command hf -ErrorAction SilentlyContinue
    if (-not $hf) {
        Write-Host "Installing Hugging Face CLI (pip)..." -ForegroundColor Yellow
        $python = Get-Command python -ErrorAction SilentlyContinue
        $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
        if (-not $python -and -not $pyLauncher) { throw "Python is required to install the Hugging Face CLI (pip install huggingface_hub[cli])." }
        $pip = if ($python) { @('python', '-m', 'pip') } else { @('py', '-m', 'pip') }
        & $pip[0] $pip[1] $pip[2] 'install', '--quiet', '--upgrade', 'huggingface_hub[cli]' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to install the Hugging Face CLI. Install it manually: pip install huggingface_hub[cli]" }
        $hf = Get-Command hf -ErrorAction SilentlyContinue
        if (-not $hf) {
            $userScripts = Join-Path $env:LOCALAPPDATA 'Python'
            $hf = Get-ChildItem -Path $userScripts, "$env:APPDATA\Python\Scripts" -Filter 'hf.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $hf) { throw "The Hugging Face CLI was installed but not found on PATH. Open a new terminal and rerun bootstrap." }
            Set-Alias -Name hf -Value $hf.FullName -Scope Script
            $script:hfPath = $hf.FullName
        } else { $script:hfPath = $hf.Source }
    } else { $script:hfPath = $hf.Source }
    $whoResult = Invoke-HfCli @('auth', 'whoami')
    $who = $whoResult.Output
    if ($whoResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(([string]$who).Trim())) {
        Write-Host "Hugging Face authentication required for a reliable high-speed download of the 17 GB model." -ForegroundColor Yellow
        Write-Host "A browser tab will open to generate a token; paste it when prompted." -ForegroundColor Yellow
        $login = Invoke-HfCli @('auth', 'login')
        if ($login.ExitCode -ne 0) { throw "Hugging Face login failed. Run 'hf login' manually, then rerun bootstrap." }
        $whoResult = Invoke-HfCli @('auth', 'whoami')
        $who = $whoResult.Output
        if ($whoResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(([string]$who).Trim())) { throw "Hugging Face login did not complete. Run 'hf login' manually, then rerun bootstrap." }
    }
    Write-Host "Hugging Face authenticated ($(((($who | Select-Object -First 1) -replace '\s.*','')).Trim()))." -ForegroundColor Green
}

function Get-HuggingFaceAuthHeaders {
    # Sends the HF CLI token with huggingface.co downloads so the transfer is
    # not rate-limited as anonymous. Returns an empty table for non-HF hosts.
    if (-not $script:__hfHeaders) { $script:__hfHeaders = @{} }
    if ($script:__hfHeaders.ContainsKey('Authorization')) { return $script:__hfHeaders }
    $t = $null
    $tokenPath = Join-Path $env:USERPROFILE '.cache\huggingface\token'
    if (Test-Path -LiteralPath $tokenPath -PathType Leaf) { $t = (Get-Content -LiteralPath $tokenPath -Raw).Trim() }
    if (-not $t) {
        $cachedTokenPath = Join-Path $env:USERPROFILE '.cache\huggingface\stored_tokens'
        if (Test-Path -LiteralPath $cachedTokenPath -PathType Leaf) {
            $files = Get-ChildItem -LiteralPath $cachedTokenPath -Filter '*.token' -ErrorAction SilentlyContinue
            if ($files) { $t = (Get-Content -LiteralPath $files[0].FullName -Raw).Trim() }
        }
    }
    $script:__hfHeaders = if ($t) { @{ Authorization = "Bearer $t" } } else { @{} }
    return $script:__hfHeaders
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [AllowNull()][string]$Sha256,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-HttpsDownloadUrl $Url $Label
    if (-not [string]::IsNullOrWhiteSpace($Sha256) -and $Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw "$Label SHA-256 is not valid." }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existingHash = Get-Sha256 $Destination
        if ([string]::IsNullOrWhiteSpace($Sha256) -or $existingHash -eq $Sha256.ToUpperInvariant()) {
            Write-Host "$Label already present; SHA-256 $existingHash." -ForegroundColor Green
            return $existingHash
        }
        if (-not $Force) { throw "$Label exists but does not match the expected hash. Move it aside or rerun with -Force." }
    }
    $partial = Join-Path $parent ('.' + ([IO.Path]::GetFileName($Destination)) + '.' + [Guid]::NewGuid().ToString('N') + '.partial')
    try {
        Write-Host "Downloading $Label..." -ForegroundColor Yellow
        $hfHeaders = if ($Url -match '^https://huggingface\.co/') { Get-HuggingFaceAuthHeaders } else { @{} }
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -MaximumRedirection 5 -Headers $hfHeaders -ErrorAction Stop
        $actualHash = Get-Sha256 $partial
        if (-not [string]::IsNullOrWhiteSpace($Sha256) -and $actualHash -ne $Sha256.ToUpperInvariant()) { throw "$Label SHA-256 mismatch. Expected $($Sha256.ToUpperInvariant()), got $actualHash." }
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Write-Host "$Label downloaded; SHA-256 $actualHash." -ForegroundColor Green
        return $actualHash
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AssetCudaVersion {
    param([Parameter(Mandatory)][string]$Name)
    $match = [regex]::Match($Name, 'cuda-(\d+\.\d+)-x64\.zip$')
    if (-not $match.Success) { return $null }
    return [version]$match.Groups[1].Value
}

function Get-AssetDigest {
    param([Parameter(Mandatory)][object]$Asset)
    $digest = [string]$Asset.digest
    if ($digest -match '^sha256:([A-Fa-f0-9]{64})$') { return $matches[1].ToUpperInvariant() }
    return $null
}

function Assert-ExtractedRuntime {
    param([Parameter(Mandatory)][string]$RuntimeDirectory)
    $binary = Join-Path $RuntimeDirectory 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "The runtime archive did not produce $binary." }
    foreach ($pattern in @('cublas64_*.dll', 'cublasLt64_*.dll', 'cudart64_*.dll')) {
        if (@(Get-ChildItem -LiteralPath $RuntimeDirectory -Filter $pattern -File -ErrorAction SilentlyContinue).Count -lt 1) { throw "The CUDA runtime is missing a DLL matching $pattern." }
    }
    return Get-Sha256 $binary
}

function Get-LatestLlamaRelease {
    param([Parameter(Mandatory)][string]$ApiUrl)
    Assert-HttpsDownloadUrl $ApiUrl 'llama.cpp release API'
    return Invoke-RestMethod -Uri $ApiUrl -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'qwen38-rtx5090-recipe' } -TimeoutSec 30 -ErrorAction Stop
}

$downloads = Join-Path $rootFull 'downloads\llama.cpp'
$runtimeDirectory = Join-Path $rootFull 'bin\llama.cpp\current'
$runtimeManifestPath = Join-Path $runtimeDirectory 'runtime-manifest.json'
$modelDirectory = Join-Path $rootFull 'models\qwen3.8-27b'

if (-not $SkipRuntime) {
    $release = Get-LatestLlamaRelease $LlamaReleaseApiUrl
    if ([string]::IsNullOrWhiteSpace([string]$release.tag_name)) { throw 'The llama.cpp release API returned no tag.' }
    $runtimeCandidates = @($release.assets | Where-Object { $_.name -match '^llama-.*-bin-win-cuda-\d+\.\d+-x64\.zip$' })
    if ($runtimeCandidates.Count -eq 0) { throw "No Windows CUDA llama.cpp runtime asset was found in release $($release.tag_name)." }
    if (-not [string]::IsNullOrWhiteSpace($CudaVersion)) {
        $runtimeCandidates = @($runtimeCandidates | Where-Object { (Get-AssetCudaVersion $_.name).ToString() -eq $CudaVersion })
        if ($runtimeCandidates.Count -eq 0) { throw "Release $($release.tag_name) has no Windows CUDA runtime for version $CudaVersion." }
    } else {
        $runtimeCandidates = @($runtimeCandidates | Sort-Object @{ Expression = { Get-AssetCudaVersion $_.name }; Descending = $true })
    }
    $runtimeAsset = $runtimeCandidates[0]
    $selectedCudaVersion = (Get-AssetCudaVersion $runtimeAsset.name).ToString()
    $cudaAssetName = "cudart-llama-bin-win-cuda-$selectedCudaVersion-x64.zip"
    $cudaAsset = @($release.assets | Where-Object { $_.name -eq $cudaAssetName }) | Select-Object -First 1
    if ($null -eq $cudaAsset) { throw "Release $($release.tag_name) is missing matching CUDA runtime asset $cudaAssetName." }

    $runtimeDigest = Get-AssetDigest $runtimeAsset
    $cudaDigest = Get-AssetDigest $cudaAsset
    if ([string]::IsNullOrWhiteSpace($runtimeDigest) -or [string]::IsNullOrWhiteSpace($cudaDigest)) { throw "Release $($release.tag_name) does not publish SHA-256 digests for the selected runtime assets; refusing an unverified latest runtime." }

    $runtimeZip = Join-Path $downloads $runtimeAsset.name
    $cudaZip = Join-Path $downloads $cudaAsset.name
    $runtimeDigest = Get-AssetDigest $runtimeAsset
    $cudaDigest = Get-AssetDigest $cudaAsset
    if ([string]::IsNullOrWhiteSpace($runtimeDigest) -or [string]::IsNullOrWhiteSpace($cudaDigest)) { throw "Release $($release.tag_name) does not publish SHA-256 digests for the selected runtime assets; refusing an unverified latest runtime." }
    $runtimeZipHash = Get-VerifiedDownload $runtimeAsset.browser_download_url $runtimeZip $runtimeDigest "llama.cpp $($release.tag_name) Windows CUDA archive"
    $cudaZipHash = Get-VerifiedDownload $cudaAsset.browser_download_url $cudaZip $cudaDigest "CUDA $selectedCudaVersion runtime archive"
    New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath $runtimeDirectory -Force
    Expand-Archive -LiteralPath $cudaZip -DestinationPath $runtimeDirectory -Force
    $binaryHash = Assert-ExtractedRuntime $runtimeDirectory
    [ordered]@{
        schema = 1
        channel = 'latest'
        tag = [string]$release.tag_name
        releaseUrl = [string]$release.html_url
        publishedAt = [string]$release.published_at
        cudaVersion = $selectedCudaVersion
        runtimeAsset = [string]$runtimeAsset.name
        runtimeAssetSha256 = $runtimeZipHash
        cudaRuntimeAsset = [string]$cudaAsset.name
        cudaRuntimeAssetSha256 = $cudaZipHash
        binaryRelativePath = 'llama-server.exe'
        binarySha256 = $binaryHash
        generatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $runtimeManifestPath -Encoding utf8
    Write-Host "Using latest llama.cpp release $($release.tag_name) with CUDA $selectedCudaVersion." -ForegroundColor Cyan
} else {
    if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) { throw "Runtime manifest is missing: $runtimeManifestPath" }
    $manifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
    $binaryPath = Join-Path $runtimeDirectory 'llama-server.exe'
    if ([string]$manifest.channel -ne 'latest') { throw 'The runtime manifest is not a latest-channel manifest.' }
    Assert-Sha256 $binaryPath ([string]$manifest.binarySha256) "llama-server ($($manifest.tag))"
}

Assert-HuggingFaceAuth

$modelPath = Join-Path $modelDirectory 'Qwen3.8-27B-UD-Q4_K_XL.gguf'
$mmprojPath = Join-Path $modelDirectory 'mmproj-F16.gguf'
Get-VerifiedDownload $ModelUrl $modelPath 'BEE238BBEB3DC0A34BDE4D0DEDBAEE1F98C009E8BB4226F03070054C12FB1372' 'Qwen3.8-27B-UD-Q4_K_XL MTP model'
Get-VerifiedDownload $MmprojUrl $mmprojPath 'CBB841A9EE0636B2EC172F5BB8DF2EA8DFEB01E90FE7C6126581D662A0B4E43E' 'Qwen3.8 F16 vision projector'

# Froggeric v22 chat template: fixes official Qwen 3.8 template regressions
# (fatal enable_thinking=false exception, empty-think poisoning, tool-arg crashes).
# Pinned to immutable revision 9f14778; embedded GGUF template remains the fallback.
$templatesDirectory = Join-Path $rootFull 'models\chat_templates'
New-Item -ItemType Directory -Force -Path $templatesDirectory | Out-Null
$templatePath = Join-Path $templatesDirectory 'chat_template.jinja'
$null = Get-VerifiedDownload $ChatTemplateUrl $templatePath '398EDF5B5BB802FB6B9C9A8DBA670D09F2AAEEF6FDCAA0B2CA307265F59F78DC' 'Froggeric v22 fixed chat template'

Write-Host "Bootstrap complete under $rootFull. Chat template: the model's embedded default (no custom template file). Runtime defaults to the latest stable llama.cpp release; no API key or repository-local secret was created." -ForegroundColor Green
