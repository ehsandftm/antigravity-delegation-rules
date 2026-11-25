[CmdletBinding()]
param(
    [string]$GeminiDir = (Join-Path $HOME '.gemini'),
    [string]$Ref = 'main',
    [switch]$VerifyOnly,
    [switch]$Uninstall,
    [switch]$WithHooks,
    [ValidateSet('single', 'dual')]
    [string]$CheckerMode = '',
    [string]$SlotAModel = '',
    [string]$SlotBModel = '',
    [switch]$NonInteractive,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StartMarker = '<!-- antigravity-delegation-rules:start -->'
$EndMarker   = '<!-- antigravity-delegation-rules:end -->'
$RepoSlug    = 'ehsandftm/antigravity-delegation-rules'
$Utf8NoBom   = [System.Text.UTF8Encoding]::new($false)
$DefaultSlotA = 'claude-opus-5-5-medium'
$DefaultSlotB = 'gemini-4-carbon-medium'
$ModelIdRegex = '^[a-zA-Z0-9][a-zA-Z0-9._-]*$'

function Normalize-LF {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`r", '')
}

function Get-LineCountLF {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $norm = Normalize-LF -Text $Text
    if ([string]::IsNullOrEmpty($norm)) { return 0 }
    $trimmed = $norm.TrimEnd("`n")
    if ([string]::IsNullOrEmpty($trimmed)) { return 0 }
    return @($trimmed -split "`n").Count
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

function Assert-ValidModelId {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ModelId,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($ModelId) -or ($ModelId -notmatch $ModelIdRegex)) {
        [Console]::Error.WriteLine("Error: Invalid model ID for ${Label}: '$ModelId'. Must match $ModelIdRegex.")
        exit 1
    }
}

function Get-LowModelId {
    param([Parameter(Mandatory = $true)][string]$ModelId)
    if ($ModelId.EndsWith('-medium', [System.StringComparison]::Ordinal)) {
        return $ModelId.Substring(0, $ModelId.Length - 7) + '-low'
    }
    return $ModelId
}

function Read-ModelChoice {
    param(
        [Parameter(Mandatory = $true)][string]$SlotLabel,
        [Parameter(Mandatory = $true)][int]$DefaultNum
    )
    $models = @(
        'claude-opus-5-5-medium',
        'gemini-4-carbon-medium',
        'gemini-4-argon-medium',
        'claude-sonnet-5-5-medium'
    )
    while ($true) {
        Write-Host ""
        Write-Host "Select model for $SlotLabel (default [$DefaultNum]):"
        Write-Host "  1) claude-opus-5-5-medium (smaller quota; best cross-family contrast)"
        Write-Host "  2) gemini-4-carbon-medium (larger Gemini quota pool)"
        Write-Host "  3) gemini-4-argon-medium (Gemini quota pool)"
        Write-Host "  4) claude-sonnet-5-5-medium (Claude quota pool)"
        Write-Host "  5) Custom model ID"
        $choice = Read-Host "Enter choice [1-5] (default $DefaultNum)"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $models[$DefaultNum - 1]
        }
        $choice = $choice.Trim()
        if ($choice -in @('1', '2', '3', '4')) {
            return $models[[int]$choice - 1]
        }
        if ($choice -eq '5') {
            $custom = Read-Host "Enter custom model ID"
            if (-not [string]::IsNullOrWhiteSpace($custom) -and ($custom.Trim() -match $ModelIdRegex)) {
                return $custom.Trim()
            }
            Write-Host "Invalid model ID. Must match $ModelIdRegex."
            continue
        }
        Write-Host "Invalid selection '$choice'. Please enter 1-5."
    }
}

function Resolve-CheckerConfigInteractive {
    Write-Host ""
    Write-Host "=== Antigravity Delegation Rules v1.3 Setup ==="
    Write-Host "Step 1 — Checker Mode:"
    Write-Host "  [1] Dual-Checker (Recommended)"
    Write-Host "  [2] Single-Checker"
    $modeChoice = ''
    while ($true) {
        $rawMode = Read-Host "Select mode [1-2] (default 1)"
        if ([string]::IsNullOrWhiteSpace($rawMode) -or $rawMode.Trim() -eq '1') {
            $modeChoice = 'dual'
            break
        }
        if ($rawMode.Trim() -eq '2') {
            $modeChoice = 'single'
            break
        }
        Write-Host "Invalid selection '$rawMode'. Please enter 1 or 2."
    }

    Write-Host ""
    Write-Host "Step 2 — Checker Model Selection:"
    Write-Host "Note: Claude Opus 5.5 has a smaller quota pool and hits rate limits faster than Gemini Carbon. In Dual-Checker mode, if one model hits quota/rate-limit, QA automatically continues with the surviving model."

    $slotA = Read-ModelChoice -SlotLabel 'Slot A (checker-rN-a)' -DefaultNum 1
    $slotB = ''
    if ($modeChoice -eq 'dual') {
        while ($true) {
            $slotB = Read-ModelChoice -SlotLabel 'Slot B (checker-rN-b)' -DefaultNum 2
            if ($slotA -eq $slotB) {
                Write-Warning "Slot A and Slot B are both set to '$slotA'. Using the same model reduces cross-family independence."
                $confirm = Read-Host "Proceed with identical Slot A and Slot B models? [y/N]"
                if ($confirm -match '^(?i)y(es)?$') {
                    break
                }
                continue
            }
            break
        }
    }

    return [PSCustomObject]@{
        CheckerMode = $modeChoice
        SlotAModel  = $slotA
        SlotBModel  = $slotB
    }
}

function Load-PersistedCheckerConfig {
    param([Parameter(Mandatory = $true)][string]$TargetGeminiDir)
    $statePath = Join-Path $TargetGeminiDir 'config\agy-installer.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Warning "Legacy install detected (missing $statePath); using dual-checker defaults for verification."
        return [PSCustomObject]@{
            CheckerMode = 'dual'
            SlotAModel  = $DefaultSlotA
            SlotBModel  = $DefaultSlotB
        }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($statePath, $Utf8NoBom)
        $obj = $raw | ConvertFrom-Json
    } catch {
        [Console]::Error.WriteLine("Error: Failed to parse ${statePath}: $_")
        exit 1
    }
    if ($null -eq $obj -or -not ($obj -is [pscustomobject])) {
        [Console]::Error.WriteLine("Error: Invalid JSON root in ${statePath}: expected a JSON object.")
        exit 1
    }
    $allowedKeys = @('checkerMode', 'slotAModel', 'slotBModel')
    foreach ($prop in $obj.PSObject.Properties) {
        if ($prop.Name -notin $allowedKeys) {
            [Console]::Error.WriteLine("Error: Unknown key '$($prop.Name)' in ${statePath}.")
            exit 1
        }
        if ($null -eq $prop.Value -or -not ($prop.Value -is [string])) {
            [Console]::Error.WriteLine("Error: Invalid non-string value for '$($prop.Name)' in ${statePath}.")
            exit 1
        }
    }
    if ($null -eq $obj.PSObject.Properties['checkerMode'] -or $null -eq $obj.PSObject.Properties['slotAModel']) {
        [Console]::Error.WriteLine("Error: Missing required key(s) in ${statePath}.")
        exit 1
    }
    $m = [string]$obj.PSObject.Properties['checkerMode'].Value
    $a = [string]$obj.PSObject.Properties['slotAModel'].Value
    $b = if ($null -ne $obj.PSObject.Properties['slotBModel']) { [string]$obj.PSObject.Properties['slotBModel'].Value } else { '' }
    if ($m -notin @('single', 'dual')) {
        [Console]::Error.WriteLine("Error: Invalid checkerMode '$m' in $statePath.")
        exit 1
    }
    Assert-ValidModelId -ModelId $a -Label "${statePath}:slotAModel"
    if ($m -eq 'dual') {
        Assert-ValidModelId -ModelId $b -Label "${statePath}:slotBModel"
    } elseif (-not [string]::IsNullOrWhiteSpace($b)) {
        [Console]::Error.WriteLine("Error: Invalid state in ${statePath}: slotBModel must be empty when checkerMode is single.")
        exit 1
    }
    return [PSCustomObject]@{
        CheckerMode = $m
        SlotAModel  = $a
        SlotBModel  = $b
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
    [Console]::Error.WriteLine("Error: Malformed delegation markers in $FilePath (start_count=$($stats.StartCount), end_count=$($stats.EndCount), start_pos=$($stats.StartPos), end_pos=$($stats.EndPos)). Aborting without modifying GEMINI.md.")
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
        [System.IO.File]::WriteAllText($tmpPath, (Normalize-LF -Text $Content), $Utf8NoBom)
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
    if ($Url -match '^file://') {
        $uri = [System.Uri]::new($Url)
        return [System.IO.File]::ReadAllText($uri.LocalPath, $Utf8NoBom)
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing
    return [string]$resp.Content
}

function Render-Templates {
    param(
        [Parameter(Mandatory = $true)][string]$BlockTemplate,
        [Parameter(Mandatory = $true)][string]$SkillTemplate,
        [Parameter(Mandatory = $true)][string]$AuditText,
        [Parameter(Mandatory = $true)][pscustomobject]$CheckerConfig
    )
    $slotA = $CheckerConfig.SlotAModel
    $slotALow = Get-LowModelId -ModelId $slotA
    $slotB = $CheckerConfig.SlotBModel
    $slotBLow = if (-not [string]::IsNullOrWhiteSpace($slotB)) { Get-LowModelId -ModelId $slotB } else { '' }

    if ($CheckerConfig.CheckerMode -eq 'dual') {
        $quotaClause   = '1-of-2 checker quota/rate-limit -> SINGLE_CHECKER_DEGRADED (kill rate-limited slot, stay degraded for round, cite verbatim 429/quota); 2-of-2 checkers or builder/bulk/Manager quota -> Hard Stop'
        $partialClause = ' On partial wakeup (1/2 checkers done), do NOT analyze or dispatch `builder`; wait until both finish (or surviving slot in SINGLE_CHECKER_DEGRADED).'
        $roleLine      = "- ``checker``: Dual-Slot read-only QA (``workspace=""inherit""``, **NO nested ``checker -> scout``**, **NO ``read_board``**): Slot A ``checker-rN-a`` (``$slotA``, ``$slotALow`` on eligible R2/R3) + Slot B ``checker-rN-b`` (``$slotB``, ``$slotBLow`` on eligible R2/R3)."
        $meceClause    = 'fresh dual-slot `checker-rN-{a|b}` (R1 dual, R2/R3 selective row-owner; kill after verdicts; Manager never self-overrides `B/M`)'
        $slotMapLine   = "- **Dual-Checker Slot Mapping (SSOT):** Slot A = ``checker-rN-a`` (``$slotA`` / ``$slotALow``), Slot B = ``checker-rN-b`` (``$slotB`` / ``$slotBLow``)."
        $tierLines     = @(
            "  - **T1** (Fast-Path, no risk paths): Skip checker (optional 1x R1 Slot A ``$slotA`` for cross-family contrast with ``builder=hydrogen``)."
            "  - **T2** (Swarm-Path OR risk paths: ``auth``, ``deletion``, ``migrations``, ``install scripts``, ``hooks``, ``CI``, ``secrets``):"
            "    - **R1:** Always dual ``-medium`` (``checker-r1-a`` + ``checker-r1-b``) in parallel on full pack."
            "    - **R2 (Row-Owner Selective + Effort-Stepped):** Re-run each slot holding open ``B/M`` (``-medium`` if ``Sev=B``/``CONTEST``/``OVERFLOW``, ``-low`` if ``M``-only without ``CONTEST``); also re-run peer slot on delta if fix touches hunks outside failing anchors or T2 risk paths. If minting slot hits quota, dispatch surviving-slot ``-medium`` for those open rows on the same ``diff_sha256``."
            "    - **R3 (Binary Closure):** Only slot(s) with open ``B/M`` (``-low``, or ``-medium`` for ``Sev=B/CONTEST``; surviving-slot ``-medium`` if minting slot hit quota)."
            "- **F17 Plan Audit (Optional):** For ``>= 5`` files, policy changes, or destructive schema/config changes, run 1-round dual ``checker-plan-a`` + ``checker-plan-b`` (``[[AGY-ROLE:checker-plan round=1]]``) before ``builder``."
        ) -join "`n"
    } else {
        $quotaClause   = 'Quota/Rate-Limit = Hard Stop (kill workers, save resume note, no auto-downgrade or retry-storms)'
        $partialClause = ''
        $roleLine      = "- ``checker``: Read-only QA (``workspace=""inherit""``, **NO nested ``checker -> scout``**, **NO ``read_board``**): Slot A ``checker-rN-a`` (``$slotA``, ``$slotALow`` on eligible R2/R3)."
        $meceClause    = 'fresh `checker-rN-a` (kill after verdict; Manager never self-overrides `B/M`)'
        $slotMapLine   = "- **Checker Slot Mapping (SSOT):** Slot A = ``checker-rN-a`` (``$slotA`` / ``$slotALow``)."
        $tierLines     = @(
            "  - **T1** (Fast-Path, no risk paths): Skip checker (optional 1x R1 Slot A ``$slotA``)."
            "  - **T2** (Swarm-Path OR risk paths: ``auth``, ``deletion``, ``migrations``, ``install scripts``, ``hooks``, ``CI``, ``secrets``):"
            "    - **R1:** Single ``-medium`` (``checker-r1-a``) on full pack."
            "    - **R2 (Effort-Stepped):** Re-run ``checker-r2-a`` on open ``B/M`` + delta (``-medium`` if ``Sev=B``/``CONTEST``/``OVERFLOW``, ``-low`` if ``M``-only without ``CONTEST``)."
            "    - **R3 (Binary Closure):** Re-run ``checker-r3-a`` on open ``B/M`` (``-low``, or ``-medium`` for ``Sev=B/CONTEST``)."
            "- **F17 Plan Audit (Optional):** For ``>= 5`` files, policy changes, or destructive schema/config changes, run 1-round ``checker-plan-a`` (``[[AGY-ROLE:checker-plan round=1]]``) before ``builder``."
        ) -join "`n"
    }

    $renderedBlock = (Normalize-LF -Text $BlockTemplate).
        Replace('{{AGY_QUOTA_POLICY_CLAUSE}}', $quotaClause).
        Replace('{{AGY_PARTIAL_WAKEUP_CLAUSE}}', $partialClause).
        Replace('{{AGY_CHECKER_ROLE_LINE}}', $roleLine).
        Replace('{{AGY_CHECKER_MECE_CLAUSE}}', $meceClause)

    $renderedSkill = (Normalize-LF -Text $SkillTemplate).
        Replace('{{AGY_SLOT_MAPPING_LINE}}', $slotMapLine).
        Replace('{{AGY_TIER_R1_R3_LINES}}', $tierLines).
        Replace('{{AGY_QUOTA_POLICY_CLAUSE}}', $quotaClause).
        Replace('{{AGY_PARTIAL_WAKEUP_CLAUSE}}', $partialClause)

    $renderedAudit = Normalize-LF -Text $AuditText

    foreach ($item in @(
        @{ Name = 'rules/delegation-block.md'; Text = $renderedBlock; MaxLines = 36 },
        @{ Name = 'skills/swarm-delegation/SKILL.md'; Text = $renderedSkill; MaxLines = 115 },
        @{ Name = 'skills/swarm-audit/SKILL.md'; Text = $renderedAudit; MaxLines = 85 }
    )) {
        if ($item.Text -match '\{\{[^}]+\}\}') {
            [Console]::Error.WriteLine("Error: Unreplaced template token detected in rendered $($item.Name).")
            exit 1
        }
        $lc = Get-LineCountLF -Text $item.Text
        if ($lc -gt $item.MaxLines) {
            [Console]::Error.WriteLine("Error: Rendered $($item.Name) exceeds line cap ($lc > $($item.MaxLines)).")
            exit 1
        }
    }

    return [PSCustomObject]@{
        BlockText = $renderedBlock
        SkillText = $renderedSkill
        AuditText = $renderedAudit
    }
}

function Resolve-Payloads {
    param(
        [Parameter(Mandatory = $true)][string]$GitRef,
        [Parameter(Mandatory = $true)][pscustomobject]$CheckerConfig,
        [switch]$IncludeHooks
    )

    $blockText = $null
    $skillText = $null
    $auditText = $null
    $hookClassifierText = $null
    $hookDelegText = $null
    $hookStopText = $null
    $hookDoctorText = $null

    $localRoot = $PSScriptRoot
    $envRawBase = $env:AGY_RAW_BASE
    $useLocal = $false
    if ([string]::IsNullOrWhiteSpace($envRawBase) -and -not [string]::IsNullOrWhiteSpace($localRoot)) {
        $localBlockPath = Join-Path $localRoot 'rules\delegation-block.md'
        $localSkillPath = Join-Path $localRoot 'skills\swarm-delegation\SKILL.md'
        $localAuditPath = Join-Path $localRoot 'skills\swarm-audit\SKILL.md'
        if ((Test-Path -LiteralPath $localBlockPath -PathType Leaf) -and (Test-Path -LiteralPath $localSkillPath -PathType Leaf) -and (Test-Path -LiteralPath $localAuditPath -PathType Leaf)) {
            $blockText = [System.IO.File]::ReadAllText($localBlockPath, $Utf8NoBom)
            $skillText = [System.IO.File]::ReadAllText($localSkillPath, $Utf8NoBom)
            $auditText = [System.IO.File]::ReadAllText($localAuditPath, $Utf8NoBom)
            if ($IncludeHooks) {
                $hookClassifierText = [System.IO.File]::ReadAllText((Join-Path $localRoot 'extras\hooks\agy-role-classifier.js'), $Utf8NoBom)
                $hookDelegText      = [System.IO.File]::ReadAllText((Join-Path $localRoot 'extras\hooks\agy-delegation-gate.js'), $Utf8NoBom)
                $hookStopText       = [System.IO.File]::ReadAllText((Join-Path $localRoot 'extras\hooks\agy-stop-gate.js'), $Utf8NoBom)
                $hookDoctorText     = [System.IO.File]::ReadAllText((Join-Path $localRoot 'extras\hooks\agy-gate-doctor.mjs'), $Utf8NoBom)
            }
            $useLocal = $true
        }
    }

    if (-not $useLocal) {
        $baseUrl = if (-not [string]::IsNullOrWhiteSpace($envRawBase)) { $envRawBase.TrimEnd('/') } else { "https://raw.githubusercontent.com/$RepoSlug/$GitRef" }
        $blockText = Get-RemoteText -Url "$baseUrl/rules/delegation-block.md"
        $skillText = Get-RemoteText -Url "$baseUrl/skills/swarm-delegation/SKILL.md"
        $auditText = Get-RemoteText -Url "$baseUrl/skills/swarm-audit/SKILL.md"
        if ($IncludeHooks) {
            $hookClassifierText = Get-RemoteText -Url "$baseUrl/extras/hooks/agy-role-classifier.js"
            $hookDelegText      = Get-RemoteText -Url "$baseUrl/extras/hooks/agy-delegation-gate.js"
            $hookStopText       = Get-RemoteText -Url "$baseUrl/extras/hooks/agy-stop-gate.js"
            $hookDoctorText     = Get-RemoteText -Url "$baseUrl/extras/hooks/agy-gate-doctor.mjs"
        }
    }

    if ([string]::IsNullOrWhiteSpace($blockText)) {
        [Console]::Error.WriteLine('Error: Downloaded/local delegation-block.md is empty.')
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($skillText)) {
        [Console]::Error.WriteLine('Error: Downloaded/local swarm-delegation/SKILL.md is empty.')
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($auditText)) {
        [Console]::Error.WriteLine('Error: Downloaded/local swarm-audit/SKILL.md is empty.')
        exit 1
    }

    $bStats = Get-MarkerStats -Text $blockText
    if ($bStats.StartCount -ne 1 -or $bStats.EndCount -ne 1 -or $bStats.StartPos -ge $bStats.EndPos) {
        [Console]::Error.WriteLine('Error: Invalid delegation-block.md payload (markers missing or malformed).')
        exit 1
    }
    if ($skillText -notmatch 'name:\s*swarm-delegation') {
        [Console]::Error.WriteLine("Error: Invalid swarm-delegation/SKILL.md payload (missing 'name: swarm-delegation').")
        exit 1
    }
    if ($auditText -notmatch 'name:\s*swarm-audit') {
        [Console]::Error.WriteLine("Error: Invalid swarm-audit/SKILL.md payload (missing 'name: swarm-audit').")
        exit 1
    }

    $rendered = Render-Templates -BlockTemplate $blockText -SkillTemplate $skillText -AuditText $auditText -CheckerConfig $CheckerConfig

    return [PSCustomObject]@{
        BlockText          = $rendered.BlockText
        SkillText          = $rendered.SkillText
        AuditText          = $rendered.AuditText
        HookClassifierText = $hookClassifierText
        HookDelegText      = $hookDelegText
        HookStopText       = $hookStopText
        HookDoctorText     = $hookDoctorText
    }
}

function Verify-SkillFile {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$DstPath,
        [Parameter(Mandatory = $true)][string]$CanonicalText
    )
    $expectedHash = Get-Sha256HexLF -Text $CanonicalText
    if (-not (Test-Path -LiteralPath $DstPath -PathType Leaf)) {
        Write-Host "MISSING : $DstPath"
        return $false
    }
    $liveText = [System.IO.File]::ReadAllText($DstPath, $Utf8NoBom)
    $actualHash = Get-Sha256HexLF -Text $liveText
    if ($expectedHash -eq $actualHash) {
        Write-Host "MATCH   : $Label ($actualHash)"
        return $true
    } else {
        Write-Host "MISMATCH: $Label (expected=$expectedHash live=$actualHash)"
        return $false
    }
}

function Invoke-Verify {
    param(
        [Parameter(Mandatory = $true)][string]$GeminiMdPath,
        [Parameter(Mandatory = $true)][string]$SkillDstPath,
        [Parameter(Mandatory = $true)][string]$AuditDstPath,
        [Parameter(Mandatory = $true)][string]$CanonicalBlockText,
        [Parameter(Mandatory = $true)][string]$CanonicalSkillText,
        [Parameter(Mandatory = $true)][string]$CanonicalAuditText,
        [switch]$IncludeHooks,
        [pscustomobject]$Payloads = $null
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

    if (-not (Verify-SkillFile -Label 'skills/swarm-delegation/SKILL.md' -DstPath $SkillDstPath -CanonicalText $CanonicalSkillText)) {
        $allOk = $false
    }
    if (-not (Verify-SkillFile -Label 'skills/swarm-audit/SKILL.md' -DstPath $AuditDstPath -CanonicalText $CanonicalAuditText)) {
        $allOk = $false
    }

    if ($IncludeHooks -and $null -ne $Payloads) {
        $targetGeminiDir = Split-Path -Path $GeminiMdPath -Parent
        $hooksDir = Join-Path $targetGeminiDir 'hooks'
        if (-not (Verify-SkillFile -Label 'hooks/agy-role-classifier.js' -DstPath (Join-Path $hooksDir 'agy-role-classifier.js') -CanonicalText $Payloads.HookClassifierText)) { $allOk = $false }
        if (-not (Verify-SkillFile -Label 'hooks/agy-delegation-gate.js' -DstPath (Join-Path $hooksDir 'agy-delegation-gate.js') -CanonicalText $Payloads.HookDelegText)) { $allOk = $false }
        if (-not (Verify-SkillFile -Label 'hooks/agy-stop-gate.js' -DstPath (Join-Path $hooksDir 'agy-stop-gate.js') -CanonicalText $Payloads.HookStopText)) { $allOk = $false }
        if (-not (Verify-SkillFile -Label 'hooks/agy-gate-doctor.mjs' -DstPath (Join-Path $hooksDir 'agy-gate-doctor.mjs') -CanonicalText $Payloads.HookDoctorText)) { $allOk = $false }

        $hooksJsonPath = Join-Path $targetGeminiDir 'hooks.json'
        if (-not (Test-Path -LiteralPath $hooksJsonPath -PathType Leaf)) {
            Write-Host "MISSING : $hooksJsonPath"
            $allOk = $false
        } else {
            $hj = [System.IO.File]::ReadAllText($hooksJsonPath, $Utf8NoBom) | ConvertFrom-Json
            if (($null -ne $hj.PSObject.Properties['agy-delegation-gate']) -and ($null -ne $hj.PSObject.Properties['agy-stop-gate'])) {
                Write-Host "MATCH   : hooks.json (agy-delegation-gate, agy-stop-gate)"
            } else {
                Write-Host "MISMATCH: hooks.json missing agy-delegation-gate or agy-stop-gate"
                $allOk = $false
            }
        }
    }

    return $allOk
}

function Remove-SkillFile {
    param([Parameter(Mandatory = $true)][string]$DstPath)
    if (Test-Path -LiteralPath $DstPath -PathType Leaf) {
        Remove-Item -LiteralPath $DstPath -Force
        $skillDir = Split-Path -Path $DstPath -Parent
        if ((Test-Path -LiteralPath $skillDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $skillDir -Force).Count -eq 0)) {
            Remove-Item -LiteralPath $skillDir -Force
        }
        Write-Host "REMOVED : $DstPath"
    }
}

function Invoke-Uninstall {
    param([Parameter(Mandatory = $true)][string]$TargetGeminiDir)

    $geminiMdPath = Join-Path $TargetGeminiDir 'GEMINI.md'
    $backupDir    = Join-Path $TargetGeminiDir 'backups'
    $skillDstPath = Join-Path $TargetGeminiDir 'config\skills\swarm-delegation\SKILL.md'
    $auditDstPath = Join-Path $TargetGeminiDir 'config\skills\swarm-audit\SKILL.md'
    $statePath    = Join-Path $TargetGeminiDir 'config\agy-installer.json'

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

    Remove-SkillFile -DstPath $skillDstPath
    Remove-SkillFile -DstPath $auditDstPath
    Remove-SkillFile -DstPath $statePath

    $hooksDir     = Join-Path $TargetGeminiDir 'hooks'
    $hooksJson    = Join-Path $TargetGeminiDir 'hooks.json'
    $gateCacheDir = Join-Path $TargetGeminiDir 'agy-gate'

    if (Test-Path -LiteralPath $hooksJson -PathType Leaf) {
        try {
            $rawHooks = [System.IO.File]::ReadAllText($hooksJson, $Utf8NoBom)
            $hj = if ([string]::IsNullOrWhiteSpace($rawHooks)) { [PSCustomObject]@{} } else { $rawHooks | ConvertFrom-Json }
            $hasDeleg = $null -ne $hj.PSObject.Properties['agy-delegation-gate']
            $hasStop  = $null -ne $hj.PSObject.Properties['agy-stop-gate']
            if ($hasDeleg -or $hasStop) {
                if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
                    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                }
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $bakPath = Join-Path $backupDir "hooks.json.bak-$stamp"
                Copy-Item -LiteralPath $hooksJson -Destination $bakPath -Force
                Write-Host "BACKUP  : $bakPath"
                if ($hasDeleg) { $hj.PSObject.Properties.Remove('agy-delegation-gate') }
                if ($hasStop)  { $hj.PSObject.Properties.Remove('agy-stop-gate') }
                if (@($hj.PSObject.Properties).Count -eq 0) {
                    Remove-Item -LiteralPath $hooksJson -Force
                    Write-Host "REMOVED : $hooksJson (empty after removing agy hooks)"
                } else {
                    $updatedJson = ($hj | ConvertTo-Json -Depth 10) + "`n"
                    Write-FileAtomicUtf8 -TargetPath $hooksJson -Content $updatedJson
                    Write-Host "UPDATED : $hooksJson (removed agy-delegation-gate, agy-stop-gate)"
                }
            }
        } catch {
            Write-Warning "Failed to parse $hooksJson during uninstall: $_"
        }
    }

    foreach ($hf in @('agy-role-classifier.js', 'agy-delegation-gate.js', 'agy-stop-gate.js', 'agy-gate-doctor.mjs')) {
        Remove-SkillFile -DstPath (Join-Path $hooksDir $hf)
    }
    if (Test-Path -LiteralPath $gateCacheDir -PathType Container) {
        Remove-Item -LiteralPath $gateCacheDir -Recurse -Force
        Write-Host "REMOVED : $gateCacheDir"
    }
}

function Install-SkillFile {
    param(
        [Parameter(Mandatory = $true)][string]$DstPath,
        [Parameter(Mandatory = $true)][string]$CanonicalText
    )
    $normalized = Normalize-LF -Text $CanonicalText
    $needsWrite = $true
    if (Test-Path -LiteralPath $DstPath -PathType Leaf) {
        $live = [System.IO.File]::ReadAllText($DstPath, $Utf8NoBom)
        if ((Get-Sha256HexLF -Text $normalized) -eq (Get-Sha256HexLF -Text $live)) {
            $needsWrite = $false
        }
    }
    if ($needsWrite) {
        Write-FileAtomicUtf8 -TargetPath $DstPath -Content $normalized
    }
}

function Install-Hooks {
    param(
        [Parameter(Mandatory = $true)][string]$TargetGeminiDir,
        [Parameter(Mandatory = $true)][string]$BackupDir,
        [Parameter(Mandatory = $true)][pscustomobject]$Payloads
    )
    $nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $nodeCmd -or [string]::IsNullOrWhiteSpace($nodeCmd.Source)) {
        Write-Warning 'node not found in PATH; skipping hooks installation.'
        return $false
    }
    $nodeBin = $nodeCmd.Source
    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $TargetGeminiDir 'hooks'))
    $hooksJson = Join-Path $TargetGeminiDir 'hooks.json'

    Install-SkillFile -DstPath (Join-Path $hooksDir 'agy-role-classifier.js') -CanonicalText $Payloads.HookClassifierText
    Install-SkillFile -DstPath (Join-Path $hooksDir 'agy-delegation-gate.js') -CanonicalText $Payloads.HookDelegText
    Install-SkillFile -DstPath (Join-Path $hooksDir 'agy-stop-gate.js') -CanonicalText $Payloads.HookStopText
    Install-SkillFile -DstPath (Join-Path $hooksDir 'agy-gate-doctor.mjs') -CanonicalText $Payloads.HookDoctorText

    $data = [PSCustomObject]@{}
    if (Test-Path -LiteralPath $hooksJson -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bakPath = Join-Path $BackupDir "hooks.json.bak-$stamp"
        Copy-Item -LiteralPath $hooksJson -Destination $bakPath -Force
        Write-Host "BACKUP  : $bakPath"
        $rawHooks = [System.IO.File]::ReadAllText($hooksJson, $Utf8NoBom)
        if (-not [string]::IsNullOrWhiteSpace($rawHooks)) {
            $data = $rawHooks | ConvertFrom-Json
        }
    }

    $delegScript = Join-Path $hooksDir 'agy-delegation-gate.js'
    $stopScript  = Join-Path $hooksDir 'agy-stop-gate.js'

    $delegObj = [PSCustomObject]@{
        PreToolUse = @(
            [PSCustomObject]@{
                matcher = '*'
                hooks   = @(
                    [PSCustomObject]@{
                        type    = 'command'
                        command = "`"$nodeBin`" `"$delegScript`""
                        timeout = 5
                    }
                )
            }
        )
    }
    $stopObj = [PSCustomObject]@{
        Stop = @(
            [PSCustomObject]@{
                type    = 'command'
                command = "`"$nodeBin`" `"$stopScript`""
                timeout = 10
            }
        )
    }

    $data | Add-Member -MemberType NoteProperty -Name 'agy-delegation-gate' -Value $delegObj -Force
    $data | Add-Member -MemberType NoteProperty -Name 'agy-stop-gate' -Value $stopObj -Force

    $jsonOut = ($data | ConvertTo-Json -Depth 10) + "`n"
    Write-FileAtomicUtf8 -TargetPath $hooksJson -Content $jsonOut
    Write-Host "UPDATED : $hooksJson (merged agy-delegation-gate, agy-stop-gate)"
    return $true
}

function Invoke-Install {
    param(
        [Parameter(Mandatory = $true)][string]$TargetGeminiDir,
        [Parameter(Mandatory = $true)][string]$CanonicalBlockText,
        [Parameter(Mandatory = $true)][string]$CanonicalSkillText,
        [Parameter(Mandatory = $true)][string]$CanonicalAuditText,
        [Parameter(Mandatory = $true)][pscustomobject]$CheckerConfig,
        [switch]$IncludeHooks,
        [pscustomobject]$Payloads = $null
    )

    $geminiMdPath = Join-Path $TargetGeminiDir 'GEMINI.md'
    $backupDir    = Join-Path $TargetGeminiDir 'backups'
    $skillDstPath = Join-Path $TargetGeminiDir 'config\skills\swarm-delegation\SKILL.md'
    $auditDstPath = Join-Path $TargetGeminiDir 'config\skills\swarm-audit\SKILL.md'
    $statePath    = Join-Path $TargetGeminiDir 'config\agy-installer.json'

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

    Install-SkillFile -DstPath $skillDstPath -CanonicalText $CanonicalSkillText
    Install-SkillFile -DstPath $auditDstPath -CanonicalText $CanonicalAuditText

    $stateObj = [ordered]@{
        checkerMode = $CheckerConfig.CheckerMode
        slotAModel  = $CheckerConfig.SlotAModel
        slotBModel  = $CheckerConfig.SlotBModel
    }
    $stateJson = (Normalize-LF -Text ($stateObj | ConvertTo-Json -Depth 4)) + "`n"
    Write-FileAtomicUtf8 -TargetPath $statePath -Content $stateJson

    $verifyHooks = $false
    if ($IncludeHooks -and $null -ne $Payloads) {
        if (Install-Hooks -TargetGeminiDir $TargetGeminiDir -BackupDir $backupDir -Payloads $Payloads) {
            $verifyHooks = $true
        }
    }

    if (Invoke-Verify `
        -GeminiMdPath $geminiMdPath `
        -SkillDstPath $skillDstPath `
        -AuditDstPath $auditDstPath `
        -CanonicalBlockText $CanonicalBlockText `
        -CanonicalSkillText $CanonicalSkillText `
        -CanonicalAuditText $CanonicalAuditText `
        -IncludeHooks:$verifyHooks `
        -Payloads $Payloads) {
        exit 0
    } else {
        exit 1
    }
}

$activeModes = @($VerifyOnly.IsPresent, $Uninstall.IsPresent, $DryRun.IsPresent) | Where-Object { $_ }
if (@($activeModes).Count -gt 1) {
    [Console]::Error.WriteLine('Error: -VerifyOnly, -Uninstall, and -DryRun are mutually exclusive.')
    exit 1
}

if ($CheckerMode -eq 'single' -and -not [string]::IsNullOrWhiteSpace($SlotBModel)) {
    [Console]::Error.WriteLine('Error: -SlotBModel cannot be used with -CheckerMode single.')
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($SlotAModel)) {
    Assert-ValidModelId -ModelId $SlotAModel -Label '-SlotAModel'
}
if (-not [string]::IsNullOrWhiteSpace($SlotBModel)) {
    Assert-ValidModelId -ModelId $SlotBModel -Label '-SlotBModel'
}

if ($Uninstall) {
    Invoke-Uninstall -TargetGeminiDir $GeminiDir
    exit 0
}

$hasCheckerFlags = (-not [string]::IsNullOrWhiteSpace($CheckerMode)) -or (-not [string]::IsNullOrWhiteSpace($SlotAModel)) -or (-not [string]::IsNullOrWhiteSpace($SlotBModel))

if ($VerifyOnly) {
    if ($hasCheckerFlags) {
        $resolvedMode = if ([string]::IsNullOrWhiteSpace($CheckerMode)) { 'dual' } else { $CheckerMode }
        $resolvedA = if ([string]::IsNullOrWhiteSpace($SlotAModel)) { $DefaultSlotA } else { $SlotAModel }
        $resolvedB = if ($resolvedMode -eq 'dual') {
            if ([string]::IsNullOrWhiteSpace($SlotBModel)) { $DefaultSlotB } else { $SlotBModel }
        } else { '' }
        $checkerConfig = [PSCustomObject]@{
            CheckerMode = $resolvedMode
            SlotAModel  = $resolvedA
            SlotBModel  = $resolvedB
        }
    } else {
        $checkerConfig = Load-PersistedCheckerConfig -TargetGeminiDir $GeminiDir
    }
} else {
    $isInteractive = (-not $NonInteractive) -and (-not $env:CI) -and (-not $hasCheckerFlags) -and $(try {
        (-not [Console]::IsInputRedirected) -and [Environment]::UserInteractive -and -not (([Environment]::GetCommandLineArgs()) -match '^(?i)[-/]noni')
    } catch { $false })

    if ($isInteractive) {
        $checkerConfig = Resolve-CheckerConfigInteractive
    } else {
        $resolvedMode = if ([string]::IsNullOrWhiteSpace($CheckerMode)) { 'dual' } else { $CheckerMode }
        $resolvedA = if ([string]::IsNullOrWhiteSpace($SlotAModel)) { $DefaultSlotA } else { $SlotAModel }
        $resolvedB = if ($resolvedMode -eq 'dual') {
            if ([string]::IsNullOrWhiteSpace($SlotBModel)) { $DefaultSlotB } else { $SlotBModel }
        } else { '' }
        if ($resolvedMode -eq 'dual' -and $resolvedA -eq $resolvedB) {
            Write-Warning "Slot A and Slot B are both set to '$resolvedA'. Proceeding in non-interactive mode."
        }
        $checkerConfig = [PSCustomObject]@{
            CheckerMode = $resolvedMode
            SlotAModel  = $resolvedA
            SlotBModel  = $resolvedB
        }
    }
}

$payloads = Resolve-Payloads -GitRef $Ref -CheckerConfig $checkerConfig -IncludeHooks:$WithHooks

if ($DryRun) {
    $blockHash = Get-Sha256HexLF -Text (Extract-BlockLF -Text $payloads.BlockText)
    $skillHash = Get-Sha256HexLF -Text $payloads.SkillText
    $auditHash = Get-Sha256HexLF -Text $payloads.AuditText
    Write-Host "DRY-RUN : Target=$GeminiDir"
    Write-Host "MODE    : $($checkerConfig.CheckerMode) (SlotA=$($checkerConfig.SlotAModel), SlotB=$($checkerConfig.SlotBModel))"
    Write-Host "SHA256  : GEMINI.md block = $blockHash ($(Get-LineCountLF -Text $payloads.BlockText)L)"
    Write-Host "SHA256  : swarm-delegation/SKILL.md = $skillHash ($(Get-LineCountLF -Text $payloads.SkillText)L)"
    Write-Host "SHA256  : swarm-audit/SKILL.md = $auditHash ($(Get-LineCountLF -Text $payloads.AuditText)L)"
    exit 0
}

if ($VerifyOnly) {
    $ok = Invoke-Verify `
        -GeminiMdPath (Join-Path $GeminiDir 'GEMINI.md') `
        -SkillDstPath (Join-Path $GeminiDir 'config\skills\swarm-delegation\SKILL.md') `
        -AuditDstPath (Join-Path $GeminiDir 'config\skills\swarm-audit\SKILL.md') `
        -CanonicalBlockText $payloads.BlockText `
        -CanonicalSkillText $payloads.SkillText `
        -CanonicalAuditText $payloads.AuditText `
        -IncludeHooks:$WithHooks `
        -Payloads $payloads
    if ($ok) { exit 0 } else { exit 1 }
}

Invoke-Install `
    -TargetGeminiDir $GeminiDir `
    -CanonicalBlockText $payloads.BlockText `
    -CanonicalSkillText $payloads.SkillText `
    -CanonicalAuditText $payloads.AuditText `
    -CheckerConfig $checkerConfig `
    -IncludeHooks:$WithHooks `
    -Payloads $payloads
