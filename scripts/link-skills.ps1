#requires -Version 5.1
# Expose .agents/skills to Claude Code as .claude/skills without copying.
# OMP and Codex read .agents/skills directly. The link is local and gitignored.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root '.agents\skills'
$link = Join-Path $root '.claude\skills'

if (-not (Test-Path $target)) { throw "Missing $target" }

$existing = Get-Item $link -Force -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.LinkType -eq 'Junction' -and $existing.Target -contains $target) {
        Write-Output "OK: $link already points to $target"
        exit 0
    }
    throw "$link exists and is not a junction to $target; move it aside first."
}

New-Item -ItemType Directory -Force (Split-Path $link) | Out-Null
New-Item -ItemType Junction -Path $link -Target $target | Out-Null
Write-Output "Created junction $link -> $target"
