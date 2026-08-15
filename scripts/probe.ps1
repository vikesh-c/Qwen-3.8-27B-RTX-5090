[CmdletBinding()]
param(
    [ValidateSet('xhigh','medium','low','none')][string]$ReasoningEffort = 'xhigh',
    [switch]$Vision,
    [switch]$Tools,
    [switch]$Streaming,
    [switch]$NonThinking,
    [int]$MaxTokens = 32,
    [string]$ConfigPath,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$loaded = Read-RecipeConfig -ConfigPath $ConfigPath
$cfg = $loaded.Data
$key = Get-RecipeKey $cfg
$headers = Get-RecipeHeaders $key
$configuredPort = [int](Get-RecipeProperty $cfg 'port' 8080)
if ($Port -eq 0) { $Port = $configuredPort }
Assert-RecipeLoopback ([string](Get-RecipeProperty $cfg 'host' '127.0.0.1'))
Assert-RecipePort $Port
$base = "http://127.0.0.1`:$Port"
$modelId = [string](Get-RecipeProperty $cfg 'modelId' 'qwen3.8-27b')
$enableThinking = -not [bool]$NonThinking
$samplingRoot = Get-RecipeProperty $cfg 'sampling'
$sampling = if ($enableThinking) { Get-RecipeProperty $samplingRoot 'thinking' } else { Get-RecipeProperty $samplingRoot 'nonThinking' }
$defaultTemperature = if ($enableThinking) { 1.0 } else { 0.7 }
$defaultTopP = if ($enableThinking) { 0.95 } else { 0.8 }
$kwargs = [ordered]@{ enable_thinking = $enableThinking; preserve_thinking = $true }
$userText = if ($Vision) { 'Describe the supplied image in one short phrase.' } elseif ($Tools) { 'Call the echo_value tool with the value READY.' } else { 'Reply with the single word READY.' }
$content = if ($Vision) {
    @(
        [ordered]@{ type = 'text'; text = $userText },
        [ordered]@{ type = 'image_url'; image_url = [ordered]@{ url = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' } }
    )
} else { $userText }
$body = [ordered]@{
    model = $modelId
    messages = @([ordered]@{ role = 'user'; content = $content })
    max_tokens = $MaxTokens
    temperature = [double](Get-RecipeProperty $sampling 'temperature' $defaultTemperature)
    top_p = [double](Get-RecipeProperty $sampling 'topP' $defaultTopP)
    top_k = [int](Get-RecipeProperty $sampling 'topK' 20)
    min_p = [double](Get-RecipeProperty $sampling 'minP' 0.0)
    presence_penalty = [double](Get-RecipeProperty $sampling 'presencePenalty' 0.0)
    repetition_penalty = [double](Get-RecipeProperty $sampling 'repetitionPenalty' 1.0)
    reasoning_effort = $ReasoningEffort
    chat_template_kwargs = $kwargs
    stream = [bool]$Streaming
}
if ($Tools) {
    $body['tools'] = @([ordered]@{
        type = 'function'
        function = [ordered]@{
            name = 'echo_value'
            description = 'Echo one value.'
            parameters = [ordered]@{ type = 'object'; properties = [ordered]@{ value = [ordered]@{ type = 'string' } }; required = @('value'); additionalProperties = $false }
        }
    })
    $body['tool_choice'] = 'required'
}
$json = $body | ConvertTo-Json -Depth 15 -Compress
$started = Get-Date
try {
    if ($Streaming) {
        $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$base/v1/chat/completions" -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec 300 -ErrorAction Stop
        $raw = [string]$response.Content
        $chunkCount = @($raw -split '[\r\n]+' | Where-Object { $_ -match '^data:\s*\{' }).Count
        $done = $raw -match '(?m)^data:\s*\[DONE\]\s*$'
        $ok = ($chunkCount -gt 0 -and $done)
        [ordered]@{ ok = $ok; mode = 'streaming'; reasoningEffort = $ReasoningEffort; enableThinking = $enableThinking; streamChunks = $chunkCount; streamDone = [bool]$done; responseBytes = [Text.Encoding]::UTF8.GetByteCount($raw); elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds } | ConvertTo-Json -Depth 8
        if (-not $ok) { exit 1 }
        exit 0
    }
    $response = Invoke-RestMethod -Method Post -Uri "$base/v1/chat/completions" -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec 300 -ErrorAction Stop
    $choice = if ($response.choices) { $response.choices[0] } else { $null }
    $message = if ($choice) { $choice.message } else { $null }
    $text = if ($message -and $null -ne $message.content) { [string]$message.content } else { '' }
    $reasoning = if ($message -and $message.reasoning_content) { [string]$message.reasoning_content } elseif ($message -and $message.reasoning) { [string]$message.reasoning } else { '' }
    $toolCalls = if ($message -and $message.tool_calls) { @($message.tool_calls).Count } else { 0 }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $outputSha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    [ordered]@{
        ok = ($null -ne $choice)
        mode = if ($Vision) { 'vision' } elseif ($Tools) { 'tools' } elseif ($NonThinking) { 'non-thinking' } else { 'thinking' }
        reasoningEffort = $ReasoningEffort
        enableThinking = $enableThinking
        finishReason = if ($choice) { [string]$choice.finish_reason } else { $null }
        outputChars = $text.Length
        reasoningChars = $reasoning.Length
        hasOutput = ($text.Length -gt 0)
        readyLike = (($text.Trim() -replace '\s+', ' ') -match '^READY[.!]?$')
        outputSha256 = $outputSha256
        toolCalls = $toolCalls
        hasToolCall = ($toolCalls -gt 0)
        elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        usage = if ($response.usage) { $response.usage } else { $null }
    } | ConvertTo-Json -Depth 10
    if ($null -eq $choice) { exit 1 }
} catch {
    [ordered]@{ ok = $false; mode = if ($Vision) { 'vision' } elseif ($Tools) { 'tools' } elseif ($NonThinking) { 'non-thinking' } else { 'thinking' }; reasoningEffort = $ReasoningEffort; error = ($_.Exception.Message -replace '[\r\n]+', ' ').Substring(0, [Math]::Min(240, ($_.Exception.Message -replace '[\r\n]+', ' ').Length)) } | ConvertTo-Json -Depth 8
    exit 1
}
