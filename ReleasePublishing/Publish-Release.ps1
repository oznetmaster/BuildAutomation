# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
# Runs only in the caller's publication job, after frozen artifact download and OIDC login.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version, [string]$Config = 'build/release.json')
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/ReleasePublishing.psm1" -Force
if ($env:RELEASE_SOURCE_COMMIT) { Assert-ReleaseArtifactRun $env:RELEASE_SOURCE_RUN_ID $env:RELEASE_SOURCE_COMMIT }
$plan = Read-ReleaseConfiguration $Root $Config $Version
Assert-ReleaseExecutionRef $Version
$commit = Get-ReleaseHead $Root
Assert-ReleaseSourceUnchanged $Root $plan
$directory = Resolve-ReleasePath $Root 'artifacts/release'
$manifest = Test-ReleaseManifest $directory $plan $Version $commit
Assert-ReleaseTag $Root $Version $commit
if (!$env:GITHUB_REPOSITORY -or !$env:GH_TOKEN -or !$env:RELEASE_NUGET_KEY) { throw 'Publication requires the caller repository identity and short-lived credentials.' }
$receiptDirectory = Resolve-ReleasePath $Root 'artifacts/publication'
$null = New-Item -ItemType Directory -Force -Path $receiptDirectory
$receipt = [ordered]@{ Version = $Version; SourceCommit = $commit; ManifestSha256 = (Get-FileHash -LiteralPath (Join-Path $directory 'release-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant(); Packages = @(); Completed = $false }
$receiptPath = Join-Path $receiptDirectory 'publication-receipt.json'
$receipt | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
$tag = "v$Version"
$releases = @(Get-ReleaseGitHubJson "repos/$env:GITHUB_REPOSITORY/releases?per_page=100")
$matches = @($releases | Where-Object { $_.tag_name -ceq $tag })
if ($matches.Count -gt 1) { throw 'Ambiguous GitHub release identity.' }
$title = "$($plan.name) $Version"
$notes = Get-Content -LiteralPath (Join-Path $directory 'RELEASE-NOTES.md') -Raw
if (!$matches.Count) {
    # Confirm GitHub draft access before any irreversible NuGet push. Recovery at
    # an older workflow revision may require an operator-created matching draft.
    Invoke-ReleaseNative gh @('release','create',$tag,'--repo',$env:GITHUB_REPOSITORY,'--target',$commit,'--draft','--title',$title,'--notes-file',(Join-Path $directory 'RELEASE-NOTES.md'))
}
$release = Get-ReleaseRecord $Version
if ($release.name -cne $title -or $release.body.TrimEnd() -cne $notes.TrimEnd()) { throw 'Existing GitHub release metadata differs; it will not be edited.' }
if ($release.draft -and $release.target_commitish -cne $commit) { throw 'Draft release targets different source.' }
Assert-ReleaseRemoteTag $Version $commit -AllowMissing:$release.draft
foreach ($package in $manifest.Packages) {
    $path = Join-Path $directory $package.File
    if (Get-NuGetVersionPresent $package.Id $Version) {
        $download = Join-Path $receiptDirectory ($package.Id + '.existing.nupkg')
        Invoke-WebRequest ("https://api.nuget.org/v3-flatcontainer/$($package.Id.ToLowerInvariant())/$Version/$($package.Id.ToLowerInvariant()).$Version.nupkg") -OutFile $download
        if ((Get-NuGetPayloadHash $download) -cne $package.PayloadSha256) { throw 'Existing NuGet payload differs; publication stopped without overwriting it.' }
        Remove-Item -LiteralPath $download
        $action = 'VerifiedExistingPayload'
    } else {
        Invoke-ReleaseNative dotnet @('nuget','push',$path,'--api-key',$env:RELEASE_NUGET_KEY,'--source','https://api.nuget.org/v3/index.json','--no-symbols')
        $action = 'Pushed'
    }
    $symbols = Join-Path $directory "$($package.Id).$Version.snupkg"
    if (Test-Path -LiteralPath $symbols) {
        Invoke-ReleaseNative dotnet @('nuget','push',$symbols,'--api-key',$env:RELEASE_NUGET_KEY,'--source','https://api.nuget.org/v3/index.json','--skip-duplicate')
    }
    $receipt.Packages += @{ Id = $package.Id; Version = $Version; Action = $action; PayloadSha256 = $package.PayloadSha256 }
    $receipt | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
}
$files = @(Get-ReleaseAssetFiles $directory)
$expected = @($files.Name)
if (@($release.assets | Where-Object { $_.name -cnotin $expected }).Count) { throw 'Unexpected existing GitHub release assets; none will be removed.' }
foreach ($file in $files | Sort-Object { if ($_.Name -eq 'release-manifest.json') { 0 } else { 1 } },Name) {
    $existing = @($release.assets | Where-Object { $_.name -ceq $file.Name })
    if ($existing.Count -gt 1) { throw 'Duplicate GitHub release asset.' }
    if (!$existing.Count) {
        if (!$release.draft) { throw 'Published release is incomplete; no published assets will be replaced.' }
        Invoke-ReleaseNative gh @('release','upload',$tag,$file.FullName,'--repo',$env:GITHUB_REPOSITORY)
    }
}
$release = Get-ReleaseRecord $Version
if (@($release.assets).Count -ne $files.Count) { throw 'GitHub release asset count differs from the frozen set.' }
foreach ($file in $files) {
    $asset = @($release.assets | Where-Object { $_.name -ceq $file.Name })
    $expectedHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($asset.Count -ne 1 -or $asset[0].size -ne $file.Length) { throw 'GitHub release asset size differs.' }
    if ($asset[0].ContainsKey('digest') -and $asset[0].digest) {
        if ($asset[0].digest -cne "sha256:$expectedHash") { throw 'GitHub release asset hash differs.' }
    } else {
        $verification = Join-Path $receiptDirectory 'asset-readback'
        $null = New-Item -ItemType Directory -Force -Path $verification
        Invoke-ReleaseNative gh @('release','download',$tag,'--repo',$env:GITHUB_REPOSITORY,'--pattern',$file.Name,'--dir',$verification)
        if ((Get-FileHash -LiteralPath (Join-Path $verification $file.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHash) { throw 'Downloaded GitHub release asset differs.' }
    }
}
if ($release.draft) { Invoke-ReleaseNative gh @('release','edit',$tag,'--repo',$env:GITHUB_REPOSITORY,'--draft=false','--latest') }
$release = Get-ReleaseRecord $Version
if ($release.draft -or $release.prerelease) { throw 'Stable GitHub publication was not confirmed.' }
Assert-ReleaseRemoteTag $Version $commit
$receipt.GitHubRelease = $release.html_url
$receipt.Completed = $true
$receipt.CompletedUtc = [DateTimeOffset]::UtcNow
$receipt | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
Write-Output "Published and verified $($plan.name) $Version from frozen artifacts."
