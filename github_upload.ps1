param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Root,
    [Parameter(Mandatory=$true, Position=1)]
    [string]$Repo,
    [string]$ExtraExcludePathsCsv = '',
    [string]$SanitizeVarsCsv = ''
)

$Root = $Root.TrimEnd('.', '\')
$ExtraExcludePaths = if ($ExtraExcludePathsCsv) { $ExtraExcludePathsCsv -split ',' } else { @() }
$SanitizeVars = if ($SanitizeVarsCsv) { $SanitizeVarsCsv -split ',' } else { @() }
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\token.ps1"

$apiRoot   = "https://api.github.com/repos/$Repo/contents"
$branch    = 'main'
$headers   = @{
    Authorization = "token $token"
    Accept        = 'application/vnd.github.v3+json'
}

function Get-GitHubFiles {
    $treeUrl = "https://api.github.com/repos/$Repo/git/trees/$branch`?recursive=1"
    $tree = Invoke-RestMethod -Uri $treeUrl -Headers $headers -Method Get
    $map = @{}
    $tree.tree | Where-Object { $_.type -eq 'blob' } | ForEach-Object { $map[$_.path] = $_.sha }
    return $map
}

function Get-BlobSha($bytes) {
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = $header + $bytes
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $hash = $sha1.ComputeHash($all)
    return [BitConverter]::ToString($hash).Replace('-', '').ToLower()
}

function Delete-File($repoPath, $sha) {
    try {
        $body = @{
            message = "Delete $repoPath"
            sha     = $sha
            branch  = $branch
        }
        $url = "$apiRoot/$([uri]::EscapeDataString($repoPath))"
        Invoke-RestMethod -Uri $url -Headers $headers -Method Delete -Body ($body | ConvertTo-Json) -ContentType 'application/json' | Out-Null
        Write-Host "  [DEL] $repoPath" -ForegroundColor DarkYellow
        return $true
    } catch {
        Write-Host "  [DEL FAIL] $repoPath - $_" -ForegroundColor Red
        return $false
    }
}

function Sanitize-Content($localPath, $repoPath) {
    try {
        $bytes = [IO.File]::ReadAllBytes($localPath)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $original = $text

        if ($localPath -like '*For Chrome Addon*contentScript*') {
            $text = $text -replace "const token = '.*?';", "const token = 'YOUR_GITHUB_TOKEN';"
        }

        foreach ($var in $SanitizeVars) {
            $escaped = [regex]::Escape("`$$var")
            $text = $text -replace "$escaped\s*=\s*'[^']*';", "`$$var = 'xxx';"
        }

        if ($text -ne $original) {
            Write-Host "  [SANITIZED] Sanitized $repoPath" -ForegroundColor Yellow
            return [Text.Encoding]::UTF8.GetBytes($text)
        }
    } catch {
        Write-Host "  [SANITIZE FAIL] $repoPath - $_" -ForegroundColor Red
    }
    return $null
}

function Upload-File($localPath, $repoPath, $ghShaMap) {
    try {
        $sanitizedBytes = Sanitize-Content $localPath $repoPath
        $bytes = if ($sanitizedBytes) { $sanitizedBytes } else { [IO.File]::ReadAllBytes($localPath) }
        $localSha = Get-BlobSha $bytes
        $ghSha = $ghShaMap[$repoPath]

        if ($ghSha -and ($ghSha -eq $localSha)) {
            Write-Host "  [SAME] $repoPath" -ForegroundColor Gray
            return $true
        }

        $b64 = [Convert]::ToBase64String($bytes)
        $body = @{
            message = if ($ghSha) { "Update $repoPath" } else { "Create $repoPath" }
            content = $b64
            branch  = $branch
        }
        if ($ghSha) { $body.sha = $ghSha }

        $url = "$apiRoot/$([uri]::EscapeDataString($repoPath))"
        Invoke-RestMethod -Uri $url -Headers $headers -Method Put -Body ($body | ConvertTo-Json) -ContentType 'application/json' | Out-Null
        Write-Host "  [OK] $repoPath" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [FAIL] $repoPath - $_" -ForegroundColor Red
        return $false
    }
}

Write-Host "Fetching GitHub file list..." -ForegroundColor Cyan
$ghShaMap = Get-GitHubFiles

Write-Host "Uploading to $Repo (main)" -ForegroundColor Cyan

$localPaths = [System.Collections.Generic.HashSet[string]]::new()

$excludeFiles = @(
    'github_upload.ps1',
    'admin-local.html'
)

$excludePatterns = @(
    '*reel*',
    '*bigdata*'
)

$allExcludePaths = @() + $ExtraExcludePaths

function Test-ExcludePath($repoPath) {
    foreach ($ep in $allExcludePaths) {
        if ($repoPath -eq $ep) {
            Write-Host "  [SKIP] $repoPath (excluded path)" -ForegroundColor DarkYellow
            return $true
        }
    }
    return $false
}

function Test-FirebaseConfig($localPath, $repoPath) {
    try {
        $content = [IO.File]::ReadAllText($localPath)
        if ($content -match 'const firebaseConfig\s*=\s*\{[^}]*apiKey\s*:\s*"') {
            Write-Host "  [SKIP] $repoPath (contains firebaseConfig apiKey)" -ForegroundColor DarkYellow
            return $true
        }
    } catch {}
    return $false
}

Get-ChildItem -Path $Root -File -Recurse | ForEach-Object {
    $localPath = $_.FullName
    $repoPath  = $localPath.Substring($Root.Length + 1) -replace '\\', '/'
    if ($repoPath -in $excludeFiles) {
        return
    }
    $filename = Split-Path $repoPath -Leaf
    $matched = $false
    foreach ($p in $excludePatterns) { if ($filename -like $p) { $matched = $true; break } }
    if ($matched) {
        Write-Host "  [SKIP] $repoPath (excluded filename)" -ForegroundColor DarkYellow
        return
    }
    if (Test-ExcludePath $repoPath) {
        return
    }
    if (Test-FirebaseConfig $localPath $repoPath) {
        return
    }
    $null = $localPaths.Add($repoPath)
    $null = Upload-File $localPath $repoPath $ghShaMap
}

Write-Host 'Checking for orphaned files on GitHub...' -ForegroundColor Cyan

$deleted = 0
foreach ($path in $ghShaMap.Keys) {
    if ($path -in $excludeFiles) {
        continue
    }
    $ghFilename = Split-Path $path -Leaf
    $matched = $false
    foreach ($p in $excludePatterns) { if ($ghFilename -like $p) { $matched = $true; break } }
    if ($matched) {
        continue
    }
    if ($path -in $allExcludePaths) {
        continue
    }
    if (-not $localPaths.Contains($path)) {
        $null = Delete-File $path $ghShaMap[$path]
        $deleted++
    }
}
if ($deleted -eq 0) { Write-Host '  No orphaned files found.' -ForegroundColor Gray }

Write-Host 'Done!' -ForegroundColor Cyan
