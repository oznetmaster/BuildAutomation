# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Task,
    [string]$Recipe = 'build/recipe.json'
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath $Root).Path
# Resolve the build tool SDK from its own global.json, never from the product's.
Push-Location -LiteralPath $PSScriptRoot
try {
    dotnet restore src/BuildAutomation.csproj --locked-mode --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'Shared build-tool restore failed.' }
    dotnet run --project src/BuildAutomation.csproj -c Release --no-restore -- --target=Run "--root=$repositoryRoot" "--recipe=$Recipe" "--task=$Task"
    if ($LASTEXITCODE -ne 0) { throw "Cake task failed: $Task" }
} finally { Pop-Location }
