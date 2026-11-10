# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
# Read-only audit: never creates environments or changes protection rules.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository, [string]$Environment = '')
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/ReleasePublishing.psm1" -Force
Test-ReleaseRepositoryPolicy $Repository $Environment | ConvertTo-Json -Depth 5
