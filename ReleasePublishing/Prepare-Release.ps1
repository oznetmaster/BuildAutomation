# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version, [string]$Config = 'build/release.json')
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/ReleasePublishing.psm1" -Force
$plan = Read-ReleaseConfiguration $Root $Config $Version
Assert-ReleaseExecutionRef $Version
$commit = Get-ReleaseHead $Root
Assert-ReleaseSourceUnchanged $Root $plan
Assert-ReleaseTag $Root $Version $commit
if (!$env:GITHUB_REPOSITORY) { throw 'Publication preflight requires a GitHub repository identity.' }
$releases = @(Get-ReleaseGitHubJson "repos/$env:GITHUB_REPOSITORY/releases?per_page=100")
if (@($releases | Where-Object { $_.tag_name -ceq "v$Version" }).Count) { throw 'A release/draft already exists. Rerun its failed publication job to reuse frozen bytes; do not rebuild.' }
foreach ($package in $plan.packages) {
    if (Get-NuGetVersionPresent $package.id $Version) { throw 'A NuGet version already exists. Recover with the original frozen publication artifact.' }
}
Write-Output "Prepared $($plan.name) $Version at $commit. No tags, packages or releases created."
