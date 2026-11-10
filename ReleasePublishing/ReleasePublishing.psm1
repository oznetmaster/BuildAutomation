# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ReleasePath {
    param([string]$Root, [string]$Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { throw 'Release paths must be repository relative.' }
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $Path))
    if (!$full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Release path escapes its repository.' }
    for ($current = $full; $current -and $current -ne $base; $current = [IO.Path]::GetDirectoryName($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.LinkType) { throw 'Release paths may not traverse symbolic links.' }
        }
    }
    return $full
}

function Assert-ReleaseVersion {
    param([string]$Version)
    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'A canonical three-part stable release version is required.' }
}

function Read-ReleaseConfiguration {
    param([string]$Root, [string]$Config = 'build/release.json', [string]$Version)
    Assert-ReleaseVersion $Version
    $path = Resolve-ReleasePath $Root $Config
    $plan = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($plan.schema -ne 1 -or $plan.name -cnotmatch '^[A-Za-z0-9_.-]+$' -or !$plan.packages -or !$plan.versionFile -or !$plan.versionXPath -or !$plan.notesFile) { throw 'Invalid release configuration.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $plan.packages) {
        if ($package.id -cnotmatch '^[A-Za-z0-9_.-]+$' -or !$ids.Add($package.id) -or !$package.project -or !$package.ContainsKey('frameworks')) { throw 'Invalid or duplicate release package.' }
        $null = Resolve-ReleasePath $Root $package.project
        foreach ($framework in $package.frameworks) { if ($framework -cnotmatch '^net[0-9.]+(?:-windows)?$') { throw 'Invalid package framework.' } }
    }
    $notes = Resolve-ReleasePath $Root ($plan.notesFile.Replace('{version}', $Version))
    if (!(Test-Path -LiteralPath $notes -PathType Leaf) -or [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $notes -Raw))) { throw 'Versioned release notes are required.' }
    if ((Get-Content -LiteralPath $notes -First 1) -cne "# $($plan.name) $Version") { throw 'Release note title differs from package identity/version.' }
    $noteParts = (Get-Content -LiteralPath $notes -Raw) -split '\r?\n', 2
    if ($noteParts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($noteParts[1])) { throw 'Release notes require a non-empty explanation.' }
    [xml]$xml = Get-Content -LiteralPath (Resolve-ReleasePath $Root $plan.versionFile) -Raw
    $nodes = $xml.SelectNodes($plan.versionXPath)
    if ($nodes.Count -ne 1 -or $nodes[0].InnerText -cne $Version) { throw 'Release version differs from maintained project metadata.' }
    $changelog = Get-Content -LiteralPath (Resolve-ReleasePath $Root 'CHANGELOG.md') -Raw
    if ($changelog -notmatch ('(?m)^## \[' + [regex]::Escape($Version) + '\]\(https://github\.com/[^\s)]+/releases/tag/v' + [regex]::Escape($Version) + '\)')) { throw 'A linked changelog entry is required.' }
    $plan['_notes'] = $notes
    $plan['_configHash'] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $plan
}

function Invoke-ReleaseNative {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Release operation failed: $Executable (exit $LASTEXITCODE)." }
}

function Get-ReleaseGitHubJson {
    param([string]$Route)
    $value = & gh api $Route
    if ($LASTEXITCODE -ne 0) { throw 'GitHub release API request failed.' }
    return ($value | ConvertFrom-Json -AsHashtable)
}

function Get-ReleaseHead {
    param([string]$Root)
    $sha = & git -C $Root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify the release source.' }
    if ($env:GITHUB_SHA -and $sha -cne $env:GITHUB_SHA) { throw 'Checked-out source differs from the workflow commit.' }
    return $sha
}

function Assert-ReleaseSourceUnchanged {
    param([string]$Root, [hashtable]$Plan)
    # Some older projects write their generated API XML beside the csproj. Only
    # those exact documentation output names may change during package staging.
    $generated = @($Plan.packages | ForEach-Object {
        $assembly = if ($_.ContainsKey('assembly')) { $_.assembly } else { $_.id }
        (([IO.Path]::GetDirectoryName($_.project) + '/' + $assembly + '.xml') -replace '\\','/')
    })
    $changed = @(& git -C $Root diff HEAD --name-only)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect release source changes.' }
    $untracked = @(& git -C $Root ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect untracked release inputs.' }
    if ($untracked.Count -or @($changed | Where-Object { $_ -cnotin $generated }).Count) { throw 'Release source differs from its recorded commit.' }
}

function Get-NuGetVersionPresent {
    param([string]$Id, [string]$Version)
    try { $index = Invoke-RestMethod ("https://api.nuget.org/v3-flatcontainer/$($Id.ToLowerInvariant())/index.json") }
    catch { if ([int]$_.Exception.Response.StatusCode -eq 404) { return $false }; throw }
    return $index.versions -ccontains $Version
}

function Assert-ReleaseTag {
    param([string]$Root, [string]$Version, [string]$Commit)
    $exists = & git -C $Root tag --list "v$Version"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect release tags.' }
    if ($exists) {
        $tagCommit = & git -C $Root rev-parse "v${Version}^{commit}"
        if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $Commit) { throw 'The existing release tag identifies different source; it will not be moved.' }
    }
}

function Test-ReleasePackage {
    param([string]$Path, [hashtable]$Package, [string]$Version, [switch]$Symbols)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $specs = @($zip.Entries | Where-Object FullName -Match '^[^/]+\.nuspec$')
        if ($specs.Count -ne 1) { throw 'A release package must contain one root nuspec.' }
        $reader = [IO.StreamReader]::new($specs[0].Open())
        try { [xml]$spec = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($spec.package.metadata.id -cne $Package.id -or $spec.package.metadata.version -cne $Version) { throw 'NuGet package identity/version does not match the release configuration.' }
        $names = @($zip.Entries | ForEach-Object FullName)
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            if (!$seen.Add($entry.FullName)) { throw 'Duplicate package entry.' }
            if ($entry.FullName -match '(^/|^[A-Za-z]:|\\|(^|/)\.\.(/|$))') { throw 'Unsafe package entry.' }
        }
        if (!$Symbols) {
            $assembly = if ($Package.ContainsKey('assembly')) { $Package.assembly } else { $Package.id }
            foreach ($framework in $Package.frameworks) {
                foreach ($extension in 'dll','xml') {
                    if ($names -cnotcontains "lib/$framework/$assembly.$extension") { throw "Missing package $framework $extension asset." }
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$spec.package.metadata.releaseNotes)) { throw 'Missing package release notes.' }
            if (![string]::IsNullOrWhiteSpace([string]$spec.package.metadata.readme) -and $names -cnotcontains [string]$spec.package.metadata.readme) { throw 'Package README is missing.' }
        }
    } finally { $zip.Dispose() }
}

function Get-NuGetPayloadHash {
    param([string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $hashes = foreach ($entry in $zip.Entries | Where-Object { $_.Name -and $_.FullName -cne '.signature.p7s' } | Sort-Object FullName -CaseSensitive) {
            $stream = $entry.Open(); $algorithm = [Security.Cryptography.SHA256]::Create()
            try { $digest = [Convert]::ToHexString($algorithm.ComputeHash($stream)).ToLowerInvariant() } finally { $stream.Dispose(); $algorithm.Dispose() }
            $entry.FullName + ' ' + $digest
        }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($hashes -join "`n")))).ToLowerInvariant()
    } finally { $zip.Dispose() }
}

function Get-ReleaseAssetFiles {
    param([string]$Directory)
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Release assets are missing.' }
    $items = @(Get-ChildItem -LiteralPath $Directory -Force)
    if (!$items.Count -or @($items | Where-Object { $_.PSIsContainer -or $_.LinkType }).Count) { throw 'Release assets must be a non-empty flat directory of regular files.' }
    foreach ($item in $items) {
        if ($item.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $item.Length -eq 0) { throw 'Unsafe or empty release asset.' }
    }
    return $items
}

function Write-ReleaseManifest {
    param([string]$Directory, [hashtable]$Plan, [string]$Version, [string]$Commit)
    $files = @(Get-ReleaseAssetFiles $Directory)
    if (@($files | Where-Object Name -in 'release-manifest.json','SHA256SUMS.txt').Count) { throw 'Release staging is not fresh.' }
    $packageFiles = @($files | Where-Object Extension -eq '.nupkg')
    if ($packageFiles.Count -ne $Plan.packages.Count) { throw 'Unexpected release package count.' }
    $packages = @(foreach ($package in $Plan.packages) {
        $path = Join-Path $Directory "$($package.id).$Version.nupkg"
        Test-ReleasePackage $path $package $Version
        $symbols = Join-Path $Directory "$($package.id).$Version.snupkg"
        if (Test-Path -LiteralPath $symbols) { Test-ReleasePackage $symbols $package $Version -Symbols }
        @{ Id = $package.id; File = [IO.Path]::GetFileName($path); PayloadSha256 = Get-NuGetPayloadHash $path }
    })
    foreach ($file in $files | Where-Object Extension -eq '.snupkg') {
        if ($file.Name -cnotin @($Plan.packages | ForEach-Object { "$($_.id).$Version.snupkg" })) { throw 'Unexpected symbol package.' }
    }
    if (@($files | Where-Object Name -CEQ 'RELEASE-NOTES.md').Count -ne 1) { throw 'Frozen release notes are missing.' }
    $assets = @($files | Sort-Object Name | ForEach-Object { @{ File = $_.Name; Bytes = $_.Length; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
    $manifest = [ordered]@{ Schema = 1; Name = $Plan.name; Version = $Version; SourceCommit = $Commit; ConfigurationSha256 = $Plan._configHash; Packages = $packages; Assets = $assets }
    $manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $Directory 'release-manifest.json') -Encoding utf8NoBOM
    $lines = @(Get-ChildItem -LiteralPath $Directory -File | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name })
    [IO.File]::WriteAllLines((Join-Path $Directory 'SHA256SUMS.txt'), $lines, [Text.UTF8Encoding]::new($false))
    return $manifest
}

function Test-ReleaseManifest {
    param([string]$Directory, [hashtable]$Plan, [string]$Version, [string]$Commit)
    $manifest = Get-Content -LiteralPath (Join-Path $Directory 'release-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.Schema -ne 1 -or $manifest.Name -cne $Plan.name -or $manifest.Version -cne $Version -or $manifest.SourceCommit -cne $Commit -or $manifest.ConfigurationSha256 -cne $Plan._configHash) { throw 'Frozen release provenance does not match this workflow.' }
    $files = @(Get-ReleaseAssetFiles $Directory)
    $expected = @($manifest.Assets.File) + @('release-manifest.json','SHA256SUMS.txt')
    if ($files.Count -ne $expected.Count -or @($files | Where-Object { $_.Name -cnotin $expected }).Count) { throw 'Frozen release asset set changed.' }
    foreach ($asset in $manifest.Assets) {
        $path = Join-Path $Directory $asset.File
        if ($asset.File -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or (Get-Item -LiteralPath $path).Length -ne $asset.Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.Sha256) { throw 'Frozen release bytes changed.' }
    }
    $checksums = @(Get-Content -LiteralPath (Join-Path $Directory 'SHA256SUMS.txt'))
    $actual = @($files | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name })
    if (Compare-Object $checksums $actual -CaseSensitive) { throw 'Release checksum set changed.' }
    $ids = @($Plan.packages.id | Sort-Object)
    if (Compare-Object $ids @($manifest.Packages.Id | Sort-Object) -CaseSensitive) { throw 'Frozen package identities changed.' }
    foreach ($package in $Plan.packages) {
        $path = Join-Path $Directory "$($package.id).$Version.nupkg"
        Test-ReleasePackage $path $package $Version
        $entry = @($manifest.Packages | Where-Object Id -CEQ $package.id)
        if ($entry.Count -ne 1 -or (Get-NuGetPayloadHash $path) -cne $entry[0].PayloadSha256) { throw 'Frozen NuGet content changed.' }
    }
    return $manifest
}

Export-ModuleMember -Function *-Release*, Get-NuGetPayloadHash, Get-NuGetVersionPresent
