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
    try {
        $treeUrl = "https://api.github.com/repos/$Repo/git/trees/$branch`?recursive=1"
        $tree = Invoke-RestMethod -Uri $treeUrl -Headers $headers -Method Get
        $map = @{}
        $tree.tree | Where-Object { $_.type -eq 'blob' } | ForEach-Object { $map[$_.path] = $_.sha }
        return $map
    } catch {
        $statusCode = 0
        if ($null -ne $_.Exception -and $null -ne $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        $errMsg = $_.ErrorDetails.Message
        if (!$errMsg -and $null -ne $_.Exception) { $errMsg = $_.Exception.Message }
        
        if ($statusCode -eq 409 -or ($errMsg -and $errMsg -match 'empty')) {
            Write-Host "Repository is empty or uninitialized. Proceeding with empty file list." -ForegroundColor Yellow
            return @{}
        }
        throw $_
    }
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
    'secure_config.enc',
    'admin-local.html',
    'withdraw_error.log'
)

$excludePatterns = @(
    '*bigdata*',
    '*.log'
)

$excludeDirNames = @(
    'node_modules',
    'user_data',
    'user_data_old',
    'downloads',
    '__pycache__',
    'pdf_screenshot',
    'ลับไม่ต้องอัพโหลด_Binance_Bot'
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

$firebaseAllowList = @(
    'send.html',
	'app.js'
)

function Test-FirebaseConfig($localPath, $repoPath) {
    try {
        $filename = Split-Path $repoPath -Leaf
        if ($filename -in $firebaseAllowList) { return $false }
        $content = [IO.File]::ReadAllText($localPath)
        if ($content -match 'const firebaseConfig\s*=\s*\{[^}]*apiKey\s*:\s*"') {
            Write-Host "  [SKIP] $repoPath (contains firebaseConfig apiKey)" -ForegroundColor DarkYellow
            return $true
        }
    } catch {}
    return $false
}

function Test-ExcludeDir($repoPath) {
    $dirs = $repoPath.Split('/')
    foreach ($dn in $excludeDirNames) {
        if ($dirs -contains $dn) { return $true }
    }
    return $false
}

$dirQueue = New-Object System.Collections.Queue
$dirQueue.Enqueue($Root)

while ($dirQueue.Count -gt 0) {
    $currentDir = $dirQueue.Dequeue()

    foreach ($exDir in $excludeDirNames) {
        $childDir = Join-Path $currentDir $exDir
        if (Test-Path $childDir) {
            $relPath = $childDir.Substring($Root.Length + 1) -replace '\\', '/'
            Write-Host "  [SKIP DIR] $relPath" -ForegroundColor DarkYellow
        }
    }

    Get-ChildItem -Path $currentDir -Directory | Where-Object { $_.Name -notin $excludeDirNames } | ForEach-Object {
        $dirQueue.Enqueue($_.FullName)
    }

    Get-ChildItem -Path $currentDir -File | ForEach-Object {
        $localPath = $_.FullName
        $repoPath  = $localPath.Substring($Root.Length + 1) -replace '\\', '/'
        $filename  = Split-Path $repoPath -Leaf
        if ($repoPath -in $excludeFiles -or $filename -in $excludeFiles) {
            Write-Host "  [SKIP] $repoPath (excluded file)" -ForegroundColor DarkYellow
            return
        }
        $matched = $false
        foreach ($p in $excludePatterns) { if ($filename -like $p) { $matched = $true; break } }
        if ($matched) {
            Write-Host "  [SKIP] $repoPath (excluded filename)" -ForegroundColor DarkYellow
            return
        }
        if (Test-ExcludePath $repoPath) { return }
        if (Test-FirebaseConfig $localPath $repoPath) { return }
        $null = $localPaths.Add($repoPath)
        $null = Upload-File $localPath $repoPath $ghShaMap
    }
}

Write-Host 'Checking for orphaned files on GitHub...' -ForegroundColor Cyan

$deleted = 0
foreach ($path in $ghShaMap.Keys) {
    $ghFilename = Split-Path $path -Leaf
    if ($path -in $excludeFiles -or $ghFilename -in $excludeFiles) {
        continue
    }
    $matched = $false
    foreach ($p in $excludePatterns) { if ($ghFilename -like $p) { $matched = $true; break } }
    if ($matched) {
        continue
    }
    if ($path -in $allExcludePaths) {
        continue
    }
    if (Test-ExcludeDir $path) {
        continue
    }
    if (-not $localPaths.Contains($path)) {
        $null = Delete-File $path $ghShaMap[$path]
        $deleted++
    }
}
if ($deleted -eq 0) { Write-Host '  No orphaned files found.' -ForegroundColor Gray }

Write-Host 'Done!' -ForegroundColor Cyan
