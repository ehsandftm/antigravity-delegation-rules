[CmdletBinding()]
param(
    [string]$GeminiDir = (Join-Path $HOME '.gemini'),
    [string]$Ref = 'main',
    [switch]$VerifyOnly,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StartMarker = '<!-- antigravity-delegation-rules:start -->'
$EndMarker   = '<!-- antigravity-delegation-rules:end -->'
$RepoSlug    = 'ehsandftm/antigravity-delegation-rules'
$Utf8NoBom   = [System.Text.UTF8Encoding]::new($false)

function Normalize-LF {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`r", '')
}

function Get-Sha256HexLF {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $normalized = Normalize-LF -Text $Text
    $bytes = $Utf8NoBom.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-MarkerStats {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $norm = Normalize-LF -Text $Text

    $sc = 0
    $sp = -1
    $idx = 0
    while ($true) {
        $found = $norm.IndexOf($StartMarker, $idx, [System.StringComparison]::Ordinal)
        if ($found -lt 0) { break }
        $sc++
        if ($sc -eq 1) { $sp = $found }
        $idx = $found + $StartMarker.Length
    }

    $ec = 0
    $ep = -1
    $idx = 0
    while ($true) {
        $found = $norm.IndexOf($EndMarker, $idx, [System.StringComparison]::Ordinal)
        if ($found -lt 0) { break }
        $ec++
        if ($ec -eq 1) { $ep = $found }
        $idx = $found + $EndMarker.Length
    }

    return [PSCustomObject]@{
        StartCount = $sc
        EndCount   = $ec
        StartPos   = $sp
        EndPos     = $ep
        Normalized = $norm
    }
}

function Assert-MarkersStrict {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$FilePath
    )
    $stats = Get-MarkerStats -Text $Text
    if ($stats.StartCount -eq 0 -and $stats.EndCount -eq 0) {
        return [PSCustomObject]@{ State = 'none'; Stats = $stats }
    }
    if ($stats.StartCount -eq 1 -and $stats.EndCount -eq 1 -and $stats.StartPos -lt $stats.EndPos) {
        return [PSCustomObject]@{ State = 'present'; Stats = $stats }
    }
    Write-Error "Malformed delegation markers in $FilePath (start_count=$($stats.StartCount), end_count=$($stats.EndCount), start_pos=$($stats.StartPos), end_pos=$($stats.EndPos)). Aborting without modifying GEMINI.md."
    exit 1
}

function Extract-BlockLF {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $stats = Get-MarkerStats -Text $Text
    if ($stats.StartCount -ne 1 -or $stats.EndCount -ne 1 -or $stats.StartPos -ge $stats.EndPos) {
        return ''
    }
    $len = ($stats.EndPos + $EndMarker.Length) - $stats.StartPos
    return $stats.Normalized.Substring($stats.StartPos, $len)
}

function Write-FileAtomicUtf8 {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Path $TargetPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $tmpPath = "$TargetPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmpPath, $Content, $Utf8NoBom)
        Move-Item -LiteralPath $tmpPath -Destination $TargetPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmpPath -PathType Leaf) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Backup-GeminiMd {
    param(
        [Parameter(Mandatory = $true)][string]$GeminiMdPath,
        [Parameter(Mandatory = $true)][string]$BackupDir
    )
    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $BackupDir "GEMINI.md.bak-$stamp"
    Copy-Item -LiteralPath $GeminiMdPath -Destination $backupPath -Force
    Write-Host "BACKUP  : $backupPath"
}

function Get-RemoteText {
    param([Parameter(Mandatory = $true)][string]$Url)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing
    return [string]$resp.Content
}

function Resolve-Payloads {
    param([Parameter(Mandatory = $true)][string]$GitRef)

    $blockText = $null
    $skillText = $null

    $localRoot = $PSScriptRoot
    $useLocal = $false
    if (-not [string]::IsNullOrWhiteSpace($localRoot)) {
        $localBlockPath = Join-Path $localRoot 'rules\delegation-block.md'
        $localSkillPath = Join-Path $localRoot 'skills\swarm-delegation\SKILL.md'
        if ((Test-Path -LiteralPath $localBlockPath -PathType Leaf) -and (Test-Path -LiteralPath $localSkillPath -PathType Leaf)) {
            $blockText = [System.IO.File]::ReadAllText($localBlockPath, $Utf8NoBom)
            $skillText = [System.IO.File]::ReadAllText($localSkillPath, $Utf8NoBom)
            $useLocal = $true
        }
    }

    if (-not $useLocal) {
        $baseUrl = "https://raw.githubusercontent.com/$RepoSlug/$GitRef"
        $blockText = Get-RemoteText -Url "$baseUrl/rules/delegation-block.md"
        $skillText = Get-RemoteText -Url "$baseUrl/skills/swarm-delegation/SKILL.md"
    }

    if ([string]::IsNullOrWhiteSpace($blockText)) {
        Write-Error 'Downloaded/local delegation-block.md is empty.'
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($skillText)) {
        Write-Error 'Downloaded/local SKILL.md is empty.'
        exit 1
    }

    $bStats = Get-MarkerStats -Text $blockText
    if ($bStats.StartCount -ne 1 -or $bStats.EndCount -ne 1 -or $bStats.StartPos -ge $bStats.EndPos) {
        Write-Error 'Invalid delegation-block.md payload (markers missing or malformed).'
        exit 1
    }
    if ($skillText -notmatch 'name:\s*swarm-delegation') {
        Write-Error "Invalid SKILL.md payload (missing 'name: swarm-delegation')."
        exit 1
    }

    return [PSCustomObject]@{
        BlockText = $blockText
        SkillText = $skillText
    }
}

function Invoke-Verify {
    param(
        [Parameter(Mandatory = $true)][string]$GeminiMdPath,
        [Parameter(Mandatory = $true)][string]$SkillDstPath,
        [Parameter(Mandatory = $true)][string]$CanonicalBlockText,
        [Parameter(Mandatory = $true)][string]$CanonicalSkillText
    )
    $allOk = $true
    $canonicalBlock = Extract-BlockLF -Text $CanonicalBlockText
    $expectedBlockHash = Get-Sha256HexLF -Text $canonicalBlock

    if (-not (Test-Path -LiteralPath $GeminiMdPath -PathType Leaf)) {
        Write-Host "MISSING : $GeminiMdPath"
        $allOk = $false
    } else {
        $liveGeminiText = [System.IO.File]::ReadAllText($GeminiMdPath, $Utf8NoBom)
        $res = Assert-MarkersStrict -Text $liveGeminiText -FilePath $GeminiMdPath
        if ($res.State -eq 'none') {
            Write-Host "MISSING : delegation block in $GeminiMdPath"
            $allOk = $false
        } else {
            $liveBlock = Extract-BlockLF -Text $liveGeminiText
            $actualBlockHash = Get-Sha256HexLF -Text $liveBlock
            if ($expectedBlockHash -eq $actualBlockHash) {
                Write-Host "MATCH   : GEMINI.md delegation block ($actualBlockHash)"
            } else {
                Write-Host "MISMATCH: GEMINI.md delegation block (expected=$expectedBlockHash live=$actualBlockHash)"
                $allOk = $false
            }
        }
    }

    $expectedSkillHash = Get-Sha256HexLF -Text $CanonicalSkillText
    if (-not (Test-Path -LiteralPath $SkillDstPath -PathType Leaf)) {
        Write-Host "MISSING : $SkillDstPath"
        $allOk = $false
    } else {
        $liveSkillText = [System.IO.File]::ReadAllText($SkillDstPath, $Utf8NoBom)
        $actualSkillHash = Get-Sha256HexLF -Text $liveSkillText
        if ($expectedSkillHash -eq $actualSkillHash) {
            Write-Host "MATCH   : skills/swarm-delegation/SKILL.md ($actualSkillHash)"
        } else {
            Write-Host "MISMATCH: skills/swarm-delegation/SKILL.md (expected=$expectedSkillHash live=$actualSkillHash)"
            $allOk = $false
        }
    }

    return $allOk
}

function Invoke-Uninstall {
    param([Parameter(Mandatory = $true)][string]$TargetGeminiDir)

    $geminiMdPath = Join-Path $TargetGeminiDir 'GEMINI.md'
    $backupDir    = Join-Path $TargetGeminiDir 'backups'
    $skillDstPath = Join-Path $TargetGeminiDir 'config\skills\swarm-delegation\SKILL.md'

    if (Test-Path -LiteralPath $geminiMdPath -PathType Leaf) {
        $liveText = [System.IO.File]::ReadAllText($geminiMdPath, $Utf8NoBom)
        $res = Assert-MarkersStrict -Text $liveText -FilePath $geminiMdPath
        if ($res.State -eq 'present') {
            Backup-GeminiMd -GeminiMdPath $geminiMdPath -BackupDir $backupDir
            $norm = $res.Stats.Normalized
            $before = $norm.Substring(0, $res.Stats.StartPos) -replace '\n+$', ''
            $after  = $norm.Substring($res.Stats.EndPos + $EndMarker.Length) -replace '^\n+', ''

            $remaining = ''
            if (-not [string]::IsNullOrEmpty($before) -and -not [string]::IsNullOrEmpty($after)) {
                $remaining = "$before`n`n$after`n"
            } elseif (-not [string]::IsNullOrEmpty($before)) {
                $remaining = "$before`n"
            } elseif (-not [string]::IsNullOrEmpty($after)) {
                $remaining = "$after`n"
            }

            if ([string]::IsNullOrWhiteSpace($remaining)) {
                Remove-Item -LiteralPath $geminiMdPath -Force
                Write-Host "REMOVED : $geminiMdPath (empty after removing delegation block)"
            } else {
                Write-FileAtomicUtf8 -TargetPath $geminiMdPath -Content $remaining
                Write-Host "UPDATED : $geminiMdPath (delegation block removed)"
            }
        }
    }

    if (Test-Path -LiteralPath $skillDstPath -PathType Leaf) {
        Remove-Item -LiteralPath $skillDstPath -Force
        $skillDir = Split-Path -Path $skillDstPath -Parent
        if ((Test-Path -LiteralPath $skillDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $skillDir -Force).Count -eq 0)) {
            Remove-Item -LiteralPath $skillDir -Force
        }
        Write-Host "REMOVED : $skillDstPath"
    }
}

function Invoke-Install {
    param(
        [Parameter(Mandatory = $true)][string]$TargetGeminiDir,
        [Parameter(Mandatory = $true)][string]$CanonicalBlockText,
        [Parameter(Mandatory = $true)][string]$CanonicalSkillText
    )

    $geminiMdPath = Join-Path $TargetGeminiDir 'GEMINI.md'
    $backupDir    = Join-Path $TargetGeminiDir 'backups'
    $skillDstPath = Join-Path $TargetGeminiDir 'config\skills\swarm-delegation\SKILL.md'

    if (-not (Test-Path -LiteralPath $TargetGeminiDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $TargetGeminiDir | Out-Null
    }

    $canonicalBlock = Extract-BlockLF -Text $CanonicalBlockText

    if (-not (Test-Path -LiteralPath $geminiMdPath -PathType Leaf)) {
        Write-FileAtomicUtf8 -TargetPath $geminiMdPath -Content "$canonicalBlock`n"
    } else {
        $liveText = [System.IO.File]::ReadAllText($geminiMdPath, $Utf8NoBom)
        $res = Assert-MarkersStrict -Text $liveText -FilePath $geminiMdPath
        if ($res.State -eq 'none') {
            Backup-GeminiMd -GeminiMdPath $geminiMdPath -BackupDir $backupDir
            $trimmedBefore = $res.Stats.Normalized -replace '\n+$', ''
            $newContent = if ([string]::IsNullOrEmpty($trimmedBefore)) {
                "$canonicalBlock`n"
            } else {
                "$trimmedBefore`n`n$canonicalBlock`n"
            }
            Write-FileAtomicUtf8 -TargetPath $geminiMdPath -Content $newContent
        } else {
            $expectedHash = Get-Sha256HexLF -Text $canonicalBlock
            $liveBlock = Extract-BlockLF -Text $liveText
            $liveHash = Get-Sha256HexLF -Text $liveBlock
            if ($expectedHash -ne $liveHash) {
                Backup-GeminiMd -GeminiMdPath $geminiMdPath -BackupDir $backupDir
                $norm = $res.Stats.Normalized
                $before = $norm.Substring(0, $res.Stats.StartPos)
                $after  = $norm.Substring($res.Stats.EndPos + $EndMarker.Length)
                $newContent = "$before$canonicalBlock$after"
                if (-not $newContent.EndsWith("`n")) {
                    $newContent += "`n"
                }
                Write-FileAtomicUtf8 -TargetPath $geminiMdPath -Content $newContent
            }
        }
    }

    $normalizedSkill = (Normalize-LF -Text $CanonicalSkillText)
    $skillNeedsWrite = $true
    if (Test-Path -LiteralPath $skillDstPath -PathType Leaf) {
        $liveSkill = [System.IO.File]::ReadAllText($skillDstPath, $Utf8NoBom)
        if ((Get-Sha256HexLF -Text $normalizedSkill) -eq (Get-Sha256HexLF -Text $liveSkill)) {
            $skillNeedsWrite = $false
        }
    }
    if ($skillNeedsWrite) {
        Write-FileAtomicUtf8 -TargetPath $skillDstPath -Content $normalizedSkill
    }

    if (Invoke-Verify -GeminiMdPath $geminiMdPath -SkillDstPath $skillDstPath -CanonicalBlockText $CanonicalBlockText -CanonicalSkillText $CanonicalSkillText) {
        exit 0
    } else {
        exit 1
    }
}

if ($VerifyOnly -and $Uninstall) {
    Write-Error '-VerifyOnly and -Uninstall are mutually exclusive.'
    exit 1
}

if ($Uninstall) {
    Invoke-Uninstall -TargetGeminiDir $GeminiDir
    exit 0
}

$payloads = Resolve-Payloads -GitRef $Ref

if ($VerifyOnly) {
    $ok = Invoke-Verify `
        -GeminiMdPath (Join-Path $GeminiDir 'GEMINI.md') `
        -SkillDstPath (Join-Path $GeminiDir 'config\skills\swarm-delegation\SKILL.md') `
        -CanonicalBlockText $payloads.BlockText `
        -CanonicalSkillText $payloads.SkillText
    if ($ok) { exit 0 } else { exit 1 }
}

Invoke-Install -TargetGeminiDir $GeminiDir -CanonicalBlockText $payloads.BlockText -CanonicalSkillText $payloads.SkillText
