# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version, [string]$Config = 'build/release.json')
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/ReleasePublishing.psm1" -Force
$plan = Read-ReleaseConfiguration $Root $Config $Version
$directory = Resolve-ReleasePath $Root 'artifacts/release'
$null = Write-ReleaseManifest $directory $plan $Version (Get-ReleaseHead $Root)
$null = Test-ReleaseManifest $directory $plan $Version (Get-ReleaseHead $Root)
Write-Output "Frozen and verified $($plan.name) $Version release assets."
