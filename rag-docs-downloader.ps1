# ============================================
# RAG Documentation Downloader
# Config: rag-docs.toml (same folder as script)
# ============================================

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "rag-docs.toml")
)

# -----------------------------------------------
# Minimal TOML parser (no dependencies)
# Supports: [section], [[array]], key = "value",
#           key = ["a","b"], inline comments (#)
# -----------------------------------------------
function Read-TomlConfig {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        Write-Error "[CONFIG] File not found: $FilePath"
        exit 1
    }

    $lines       = Get-Content $FilePath -Encoding UTF8
    $config      = @{}
    $currentSect = $null
    $arrayKey    = $null

    foreach ($rawLine in $lines) {
        # Strip inline comments and trim
        $line = ($rawLine -replace '#.*$', '').Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # [[array-of-tables]]
        if ($line -match '^\[\[(.+)\]\]$') {
            $arrayKey    = $matches[1].Trim()
            $currentSect = $arrayKey
            if (-not $config.ContainsKey($arrayKey)) { $config[$arrayKey] = [System.Collections.Generic.List[hashtable]]::new() }
            $newEntry = @{}
            $config[$arrayKey].Add($newEntry)
            continue
        }

        # [section] or [section.sub]
        if ($line -match '^\[(.+)\]$') {
            $arrayKey    = $null
            $currentSect = $matches[1].Trim()
            # Build nested path
            $parts = $currentSect -split '\.'
            $node  = $config
            foreach ($p in $parts) {
                if (-not $node.ContainsKey($p)) { $node[$p] = @{} }
                $node = $node[$p]
            }
            continue
        }

        # key = value
        if ($line -match '^(\w+)\s*=\s*(.+)$') {
            $key   = $matches[1].Trim()
            $value = $matches[2].Trim()

            # Inline array ["a","b","c"]
            if ($value -match '^\[(.+)\]$') {
                $items = $matches[1] -split ',' | ForEach-Object {
                    $_.Trim().Trim('"').Trim("'")
                }
                $parsed = [string[]]$items
            }
            # Quoted string
            elseif ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
                $parsed = $matches[1]
            }
            else {
                $parsed = $value
            }

            # Write to correct node
            if ($arrayKey -and $config[$arrayKey].Count -gt 0) {
                $config[$arrayKey][$config[$arrayKey].Count - 1][$key] = $parsed
            }
            elseif ($currentSect) {
                $parts = $currentSect -split '\.'
                $node  = $config
                foreach ($p in $parts) { $node = $node[$p] }
                $node[$key] = $parsed
            }
            else {
                $config[$key] = $parsed
            }
        }
    }

    return $config
}

# -----------------------------------------------
# Load config
# -----------------------------------------------
Write-Host "[CONFIG] Loading: $ConfigPath" -ForegroundColor Cyan
$CFG = Read-TomlConfig -FilePath $ConfigPath

$BASE_PATH    = [System.IO.Path]::GetFullPath($CFG["paths"]["base"])
$INCLUDE_DIRS = [string[]]$CFG["filter"]["include"]["folders"]
$EXCLUDE_DIRS = [string[]]$CFG["filter"]["exclude"]["folders"]
$ALLOWED_EXT  = @(".md",".markdown",".mdx",".txt",".toml",".json",".yaml",".yml",".html",".htm")
if ($CFG["filter"]["exclude"].ContainsKey("extensions")) {
    $ALLOWED_EXT = [string[]]$CFG["filter"]["exclude"]["extensions"]
}

$ALLOWED_SET = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$ALLOWED_EXT,
    [System.StringComparer]::OrdinalIgnoreCase
)

$INCLUDE_SET = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$INCLUDE_DIRS,
    [System.StringComparer]::OrdinalIgnoreCase
)

$EXCLUDE_SET = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$EXCLUDE_DIRS,
    [System.StringComparer]::OrdinalIgnoreCase
)

$REPOS = $CFG["repos"]

# -----------------------------------------------
# Bootstrap base path
# -----------------------------------------------
if (-not (Test-Path $BASE_PATH)) {
    New-Item -ItemType Directory -Path $BASE_PATH -Force | Out-Null
    Write-Host "[INIT] Base folder created: $BASE_PATH" -ForegroundColor Cyan
}

# -----------------------------------------------
# Safety: no operations outside BASE_PATH
# -----------------------------------------------
function Assert-SafePath {
    param([string]$TargetPath)
    $resolved = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not $resolved.StartsWith($BASE_PATH, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "[SECURITY] Path not allowed: $resolved"
        exit 1
    }
}

# -----------------------------------------------
# Write permission check
# -----------------------------------------------
function Assert-WritePermission {
    param([string]$FolderPath)
    $testFile = Join-Path $FolderPath ".write_test_$(New-Guid)"
    try {
        [System.IO.File]::WriteAllText($testFile, "")
        Remove-Item $testFile -Force
    } catch {
        Write-Error "[ERROR] No write access on: $FolderPath"
        exit 1
    }
}

Assert-WritePermission -FolderPath $BASE_PATH

# -----------------------------------------------
# Git dependency check
# -----------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "[ERROR] 'git' not found in system PATH."
    exit 1
}

# -----------------------------------------------
# Canonical URL normalization
# -----------------------------------------------
function Get-CanonicalGitUrl {
    param([string]$Url)
    return "$($Url.TrimEnd('/').TrimEnd('.git')).git"
}

# -----------------------------------------------
# Resolve default branch
# -----------------------------------------------
function Get-DefaultBranch {
    param([string]$FolderPath)
    Assert-SafePath $FolderPath
    Push-Location $FolderPath
    try {
        $symref = git symbolic-ref refs/remotes/origin/HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($symref)) {
            git remote set-head origin --auto 2>&1 | Out-Null
            $symref = git symbolic-ref refs/remotes/origin/HEAD 2>$null
        }
        if (-not [string]::IsNullOrWhiteSpace($symref)) {
            return ($symref.Trim() -replace '^refs/remotes/origin/', '')
        }
        Write-Warning "[WARN] Default branch not detected, falling back to 'main'."
        return "main"
    } finally {
        Pop-Location
    }
}

# -----------------------------------------------
# Sparse-checkout: whitelist paths only
# Builds patterns from INCLUDE_SET filtered by
# EXCLUDE_SET at checkout level.
# -----------------------------------------------
function Set-SparseCheckout {
    param([string]$FolderPath)
    Assert-SafePath $FolderPath
    Push-Location $FolderPath
    try {
        git config core.longpaths true
        git sparse-checkout init --no-cone 2>&1 | Out-Null

        # Build include patterns: docs/**/*.md, etc.
        $patterns = foreach ($dir in $INCLUDE_SET) {
            foreach ($ext in $ALLOWED_EXT) {
                "**/$dir/**/*$ext"
                "$dir/**/*$ext"
            }
        }

        git sparse-checkout set --no-cone $patterns 2>&1 | Write-Host
    } finally {
        Pop-Location
    }
}

# -----------------------------------------------
# Post-checkout: remove excluded folders and
# any files not matching allowed extensions
# -----------------------------------------------
function Remove-UnwantedFiles {
    param([string]$FolderPath)
    Assert-SafePath $FolderPath

    $gitDir  = Join-Path $FolderPath ".git"
    $removed = 0

    # --- Remove excluded directories ---
    Get-ChildItem -Path $FolderPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch [regex]::Escape($gitDir) } |
        Where-Object {
            $dirName = $_.Name.ToLower()
            $EXCLUDE_SET | Where-Object { $dirName -eq $_.ToLower() }
        } |
        Sort-Object FullName -Descending |
        ForEach-Object {
            Assert-SafePath $_.FullName
            try {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "  [DEL-DIR] $($_.FullName)" -ForegroundColor DarkGray
                $removed++
            } catch {
                Write-Warning "[WARN] Could not remove directory: $($_.FullName)"
            }
        }

    # --- Remove files with disallowed extensions ---
    Get-ChildItem -Path $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch [regex]::Escape($gitDir) } |
        Where-Object { -not $ALLOWED_SET.Contains($_.Extension) } |
        ForEach-Object {
            Assert-SafePath $_.FullName
            try {
                Remove-Item $_.FullName -Force -ErrorAction Stop
                $removed++
            } catch {
                Write-Warning "[WARN] Could not remove file: $($_.FullName)"
            }
        }

    # --- Remove empty folders ---
    Get-ChildItem -Path $FolderPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch [regex]::Escape($gitDir) } |
        Sort-Object FullName -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
                Assert-SafePath $_.FullName
                try { Remove-Item $_.FullName -Force -Recurse -ErrorAction Stop } catch {}
            }
        }

    $kept = (Get-ChildItem -Path $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch [regex]::Escape($gitDir) }).Count

    Write-Host "  [FILTER] Removed: $removed | Kept: $kept useful files" -ForegroundColor Cyan
}

# -----------------------------------------------
# MAIN LOOP
# -----------------------------------------------
foreach ($repo in $REPOS) {

    $repoUrl       = $repo["url"]
    $repoNote      = if ($repo["note"]) { $repo["note"] } else { "" }
    $canonicalUrl  = Get-CanonicalGitUrl $repoUrl
    $repoName      = ($repoUrl.TrimEnd('/') -split '/')[-1]
    $repoOwner     = ($repoUrl.TrimEnd('/') -split '/')[-2]
    $repoDirName   = "${repoOwner}_${repoName}"
    $repoLocalPath = Join-Path $BASE_PATH $repoDirName

    Assert-SafePath $repoLocalPath

    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Yellow
    Write-Host " $repoOwner/$repoName"                    -ForegroundColor Yellow
    if ($repoNote) { Write-Host " $repoNote"              -ForegroundColor DarkYellow }
    Write-Host " PATH: $repoLocalPath"                    -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Yellow

    if (Test-Path (Join-Path $repoLocalPath ".git")) {

        Write-Host "[UPDATE] Updating existing repo..." -ForegroundColor Cyan
        $branch = Get-DefaultBranch -FolderPath $repoLocalPath
        Set-SparseCheckout -FolderPath $repoLocalPath
        Push-Location $repoLocalPath
        try {
            git fetch --all --prune 2>&1 | Write-Host
            git reset --hard "origin/$branch" 2>&1 | Write-Host
        } finally {
            Pop-Location
        }
        Remove-UnwantedFiles -FolderPath $repoLocalPath

    } else {

        if (Test-Path $repoLocalPath) {
            Assert-SafePath $repoLocalPath
            Remove-Item -Path $repoLocalPath -Recurse -Force
        }

        Write-Host "[CLONE] Partial clone + sparse-checkout..." -ForegroundColor Green
        git clone --depth 1 --filter=blob:none --no-checkout $canonicalUrl $repoLocalPath 2>&1 | Write-Host

        if (Test-Path $repoLocalPath) {
            Assert-SafePath $repoLocalPath
            $branch = Get-DefaultBranch -FolderPath $repoLocalPath
            Set-SparseCheckout -FolderPath $repoLocalPath
            Push-Location $repoLocalPath
            try {
                git checkout $branch 2>&1 | Write-Host
            } finally {
                Pop-Location
            }
            Remove-UnwantedFiles -FolderPath $repoLocalPath
        }
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " DOWNLOAD COMPLETED"                       -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
