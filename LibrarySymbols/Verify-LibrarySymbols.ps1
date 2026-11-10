# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory, [switch]$Publish)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/LibrarySymbols.psm1" -Force
$results = @(Test-LibrarySymbolDirectory $Directory)
foreach ($result in $results) { Write-Output "Verified $($result.Id) $($result.Version): $($result.Binaries) matching portable PDB(s)." }
if ($Publish) {
    if (!$env:RELEASE_NUGET_KEY) { throw 'Publishing symbols requires the caller short-lived NuGet credential.' }
    foreach ($symbol in Get-ChildItem -LiteralPath $Directory -Filter *.snupkg -File) {
        & dotnet nuget push $symbol.FullName --api-key $env:RELEASE_NUGET_KEY --source https://api.nuget.org/v3/index.json
        if ($LASTEXITCODE -ne 0) { throw 'Symbol publication failed; retain the exact build artifacts for recovery.' }
    }
}
