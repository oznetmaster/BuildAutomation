# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
# Local staging only: no network publication, credentials, tag creation or hardware.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version, [string]$Config = 'build/release.json')
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/ReleasePublishing.psm1" -Force
$Root = (Resolve-Path -LiteralPath $Root).Path
$plan = Read-ReleaseConfiguration $Root $Config $Version
$null = Get-ReleaseHead $Root
$output = Resolve-ReleasePath $Root 'artifacts/release'
if ((Test-Path -LiteralPath $output) -and @(Get-ChildItem -LiteralPath $output -Force).Count) { throw 'Release output is not empty; preserve previous artifacts before staging.' }
$null = New-Item -ItemType Directory -Path $output -Force
$stage = Resolve-ReleasePath $Root ('artifacts/release-staging/' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stage
Push-Location -LiteralPath $Root
try {
    foreach ($package in $plan.packages) {
        Invoke-ReleaseNative dotnet @('pack',$package.project,'-c','Release','-o',$output,'-p:ContinuousIntegrationBuild=true',"-p:Version=$Version",'-p:GenerateApiDocumentation=false','-p:GenerateDocfxDocumentation=false')
        Test-ReleasePackage (Join-Path $output "$($package.id).$Version.nupkg") $package $Version
        if ($plan.rawLibraries) {
            $assembly = if ($package.ContainsKey('assembly')) { $package.assembly } else { $package.id }
            $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $output "$($package.id).$Version.nupkg"))
            try {
                foreach ($framework in $package.frameworks) { foreach ($extension in 'dll','xml') {
                    $entry = $zip.GetEntry("lib/$framework/$assembly.$extension")
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $output "$($package.id).$framework.$extension"))
                } }
            } finally { $zip.Dispose() }
        }
    }
    foreach ($application in $plan.applications) {
        $null = Resolve-ReleasePath $Root $application.project
        if ($application.name -cnotmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid application artifact name.' }
        $destination = Join-Path $stage $application.name
        $arguments = @('publish',$application.project,'-c','Release','--self-contained','false','-o',$destination,"-p:Version=$Version",'-p:GenerateApiDocumentation=false','-p:GenerateDocfxDocumentation=false')
        if ($application.framework) { $arguments += @('-f',$application.framework) }
        Invoke-ReleaseNative dotnet $arguments
        foreach ($document in $plan.documents) { Copy-Item -LiteralPath (Resolve-ReleasePath $Root $document) -Destination $destination -Recurse }
        $private = @(Get-ChildItem -LiteralPath $destination -Recurse -Force -File | Where-Object { $_.Extension -in '.pfx','.key','.trx' -or $_.Name -match '(?i)(\.local\.|LiveTestSettings|pairing.*\.json|credentials.*\.json)' })
        if ($private.Count) { throw 'Private/development data found in application output.' }
        [IO.Compression.ZipFile]::CreateFromDirectory($destination, (Join-Path $output "$($plan.name)-$Version-$($application.name).zip"))
    }
    if ($plan.ContainsKey('libraryArchive') -and $plan.libraryArchive) {
        $library = Join-Path $stage 'library'
        $null = New-Item -ItemType Directory -Path $library
        foreach ($package in $plan.packages) {
            $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $output "$($package.id).$Version.nupkg"))
            try {
                foreach ($entry in $zip.Entries | Where-Object { $_.Name -and $_.FullName.StartsWith('lib/', [StringComparison]::Ordinal) }) {
                    $relative = $entry.FullName.Substring(4)
                    $destination = Resolve-ReleasePath $library $relative
                    $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination))
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination)
                }
            } finally { $zip.Dispose() }
        }
        foreach ($document in $plan.documents) { Copy-Item -LiteralPath (Resolve-ReleasePath $Root $document) -Destination $library -Recurse }
        [IO.Compression.ZipFile]::CreateFromDirectory($library, (Join-Path $output "$($plan.name)-$Version-library.zip"))
    }
    if ($plan.ContainsKey('documentationArchive') -and $plan.documentationArchive) {
        $documentation = Resolve-ReleasePath $Root $plan.documentationArchive
        if (!(Test-Path -LiteralPath (Join-Path $documentation 'index.html'))) { throw 'Build documentation before staging its archive.' }
        [IO.Compression.ZipFile]::CreateFromDirectory($documentation, (Join-Path $output "$($plan.name)-$Version-documentation.zip"))
    }
    foreach ($document in $plan.documents) {
        $path = Resolve-ReleasePath $Root $document
        if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination $output }
    }
    Copy-Item -LiteralPath $plan._notes -Destination (Join-Path $output 'RELEASE-NOTES.md') -Force
    Write-Output "Staged release assets locally: $($plan.name) $Version. Nothing published."
} finally { Pop-Location }
