# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
# Synthetic packages and mocked GitHub/NuGet only. Never publishes or uses credentials.
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/ReleasePublishing.psm1" -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('SharedRelease-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$checks = 0
function Check([bool]$Value, [string]$Reason) { if (!$Value) { throw $Reason }; $script:checks++ }
function Reject([scriptblock]$Action) { $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Check $rejected 'Invalid release operation was accepted.' }
function New-Package([string]$Path, [string]$Payload = 'product payload', [string]$Id = 'Example', [string]$Version = '1.0.1', [switch]$Signature, [switch]$MissingXml, [switch]$Duplicate, [switch]$Unsafe) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = @{ 'Example.nuspec' = "<package><metadata><id>$Id</id><version>$Version</version><readme>README.md</readme><releaseNotes>Concurrency fixes</releaseNotes></metadata></package>"; 'lib/net472/Example.dll' = $Payload; 'README.md' = 'Usage'; 'lib/net472/Example.xml' = '<doc />' }
        if ($MissingXml) { $entries.Remove('lib/net472/Example.xml') }
        if ($Signature) { $entries['.signature.p7s'] = 'synthetic repository signature' }
        if ($Unsafe) { $entries['../outside'] = 'invalid' }
        foreach ($entry in $entries.GetEnumerator()) { $writer = [IO.StreamWriter]::new($zip.CreateEntry($entry.Key).Open()); try { $writer.Write($entry.Value) } finally { $writer.Dispose() } }
        if ($Duplicate) { $writer = [IO.StreamWriter]::new($zip.CreateEntry('LIB/net472/Example.dll').Open()); try { $writer.Write('duplicate') } finally { $writer.Dispose() } }
    } finally { $zip.Dispose() }
}
$variables = @('GITHUB_SHA','GITHUB_REPOSITORY','GITHUB_REF','GITHUB_WORKFLOW_REF','RELEASE_SOURCE_COMMIT','RELEASE_SOURCE_RUN_ID','GH_TOKEN','RELEASE_NUGET_KEY')
$saved = @{}; foreach ($variable in $variables) { $saved[$variable] = [Environment]::GetEnvironmentVariable($variable) }
try {
    foreach ($version in @('1.0.1','0.0.1','20.123.456')) { Assert-ReleaseVersion $version; $checks++ }
    foreach ($version in @('', 'v1.0.1','01.0.1','1.0.1.0','1.0','1.0.1-beta',"1.0.1`ninvalid",'1.0.1+metadata')) { Reject { Assert-ReleaseVersion $version } }
    foreach ($path in @('../outside','nested/../../outside',[IO.Path]::GetFullPath($fixture))) { Reject { Resolve-ReleasePath $fixture $path } }
    Check ((Resolve-ReleasePath $fixture 'build/config.json').StartsWith($fixture)) 'Valid nested path rejected.'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'build'),(Join-Path $fixture 'artifacts/release')
    '<Project><PropertyGroup><Version>1.0.1</Version></PropertyGroup></Project>' | Set-Content (Join-Path $fixture 'Example.csproj')
    "# Example 1.0.1`n`nFix concurrency." | Set-Content (Join-Path $fixture 'notes.md')
    '## [1.0.1](https://github.com/example/library/releases/tag/v1.0.1)' | Set-Content (Join-Path $fixture 'CHANGELOG.md')
    $configuration = @{ schema = 1; name = 'Example'; versionFile = 'Example.csproj'; versionXPath = '/Project/PropertyGroup/Version'; notesFile = 'notes.md'; packages = @(@{ id = 'Example'; project = 'Example.csproj'; frameworks = @('net472') }); applications = @(); documents = @(); rawLibraries = $false }
    $configPath = Join-Path $fixture 'build/release.json'
    $configuration | ConvertTo-Json -Depth 7 | Set-Content $configPath
    $plan = Read-ReleaseConfiguration $fixture 'build/release.json' '1.0.1'; $checks++
    Reject { Read-ReleaseConfiguration $fixture 'build/release.json' '1.0.2' }
    $configuration.packages += $configuration.packages[0]
    $configuration | ConvertTo-Json -Depth 7 | Set-Content $configPath
    Reject { Read-ReleaseConfiguration $fixture 'build/release.json' '1.0.1' }
    $configuration.packages = @($configuration.packages[0])
    $configuration | ConvertTo-Json -Depth 7 | Set-Content $configPath
    '# Example 1.0.1' | Set-Content (Join-Path $fixture 'notes.md')
    Reject { Read-ReleaseConfiguration $fixture 'build/release.json' '1.0.1' }
    "# Example 1.0.1`n`nFix concurrency." | Set-Content (Join-Path $fixture 'notes.md')
    $plan = Read-ReleaseConfiguration $fixture 'build/release.json' '1.0.1'
    $directory = Join-Path $fixture 'artifacts/release'
    $package = Join-Path $directory 'Example.1.0.1.nupkg'
    New-Package $package
    Test-ReleasePackage $package $plan.packages[0] '1.0.1'; $checks++
    $requiredSymbols = @{ packages = @(@{ id = 'Example'; symbols = $true }) }
    Reject { Test-ReleaseSymbols $directory $requiredSymbols '1.0.1' }
    Reject { Test-ReleasePackage $package $plan.packages[0] '1.0.2' }
    foreach ($variant in @('MissingXml','Duplicate','Unsafe')) {
        $path = Join-Path $fixture ($variant + '.nupkg'); $options = @{ $variant = $true }; New-Package $path @options
        Reject { Test-ReleasePackage $path $plan.packages[0] '1.0.1' }
    }
    $signed = Join-Path $fixture 'signed.nupkg'; New-Package $signed -Signature
    Check ((Get-NuGetPayloadHash $signed) -ceq (Get-NuGetPayloadHash $package)) 'Repository signing changed the logical payload comparison.'
    $different = Join-Path $fixture 'different.nupkg'; New-Package $different -Payload 'different product payload'
    Check ((Get-NuGetPayloadHash $different) -cne (Get-NuGetPayloadHash $package)) 'Different product content was accepted.'
    Copy-Item -LiteralPath (Join-Path $fixture 'notes.md') -Destination (Join-Path $directory 'RELEASE-NOTES.md')
    $commit = 'a' * 40
    $manifest = Write-ReleaseManifest $directory $plan '1.0.1' $commit; $checks++
    $null = Test-ReleaseManifest $directory $plan '1.0.1' $commit; $checks++
    Reject { Write-ReleaseManifest $directory $plan '1.0.1' $commit }
    Reject { Test-ReleaseManifest $directory $plan '1.0.1' ('b' * 40) }
    $plan._configHash = '0' * 64; Reject { Test-ReleaseManifest $directory $plan '1.0.1' $commit }; $plan = Read-ReleaseConfiguration $fixture 'build/release.json' '1.0.1'
    'extra' | Set-Content (Join-Path $directory 'extra.txt'); Reject { Test-ReleaseManifest $directory $plan '1.0.1' $commit }; Remove-Item (Join-Path $directory 'extra.txt')
    $notesBytes = [IO.File]::ReadAllBytes((Join-Path $directory 'RELEASE-NOTES.md'))
    'changed' | Set-Content (Join-Path $directory 'RELEASE-NOTES.md'); Reject { Test-ReleaseManifest $directory $plan '1.0.1' $commit }; [IO.File]::WriteAllBytes((Join-Path $directory 'RELEASE-NOTES.md'), $notesBytes)
    $checksums = [IO.File]::ReadAllBytes((Join-Path $directory 'SHA256SUMS.txt'))
    'wrong' | Set-Content (Join-Path $directory 'SHA256SUMS.txt'); Reject { Test-ReleaseManifest $directory $plan '1.0.1' $commit }; [IO.File]::WriteAllBytes((Join-Path $directory 'SHA256SUMS.txt'), $checksums)
    $env:GITHUB_SHA = $commit; $env:GITHUB_REPOSITORY = 'example/library'; $env:GH_TOKEN = 'fake-gh'; $env:RELEASE_NUGET_KEY = 'fake-short-lived-key'
    $global:ReleaseFixture = @{ Commit = $commit; Package = $package; Signed = $signed; Existing = $false; Pushes = 0; Uploads = 0; Release = $null; FailUpload = $true; Mismatch = $false; Root = $fixture }
    function global:git { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments); $global:LASTEXITCODE = 0; if ($Arguments -contains 'rev-parse') { return $global:ReleaseFixture.Commit }; if ($Arguments -contains '--name-only') { if ($global:ReleaseFixture.ContainsKey('DirtySource')) { return $global:ReleaseFixture.DirtySource }; return }; if ($Arguments -contains '--list' -or $Arguments -contains 'ls-files') { return }; throw 'Unexpected git request.' }
    function global:Invoke-RestMethod { param([string]$Uri); if ($Uri -notmatch '^https://api.nuget.org/v3-flatcontainer/example/index.json$') { throw 'Unexpected HTTP request.' }; return @{ versions = $(if ($global:ReleaseFixture.Existing) { @('1.0.1') } else { @() }) } }
    function global:Invoke-WebRequest { param([string]$Uri,[string]$OutFile); if ($Uri -notmatch '^https://api.nuget.org/v3-flatcontainer/example/1.0.1/example.1.0.1.nupkg$') { throw 'Unexpected package download.' }; Copy-Item -LiteralPath $(if ($global:ReleaseFixture.Mismatch) { Join-Path $global:ReleaseFixture.Root 'different.nupkg' } else { $global:ReleaseFixture.Signed }) -Destination $OutFile }
    function global:dotnet { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments); if ($Arguments[0] -cne 'nuget' -or $Arguments[1] -cne 'push') { throw 'Unexpected native dotnet operation.' }; $global:ReleaseFixture.Pushes++; $global:ReleaseFixture.Existing = $true; $global:LASTEXITCODE = 0 }
    function global:gh {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        $state = $global:ReleaseFixture; $global:LASTEXITCODE = 0
        if ($Arguments[0] -ceq 'api') {
            $route = $Arguments[1]
            if ($route -ceq 'repos/example/library') { return '{"default_branch":"main"}' }
            if ($route -ceq 'repos/example/library/environments/release') { return (@{deployment_branch_policy=$state.EnvironmentPolicy}|ConvertTo-Json -Depth 5 -Compress) }
            if ($route -ceq 'repos/example/library/environments/release/deployment-branch-policies') { return (@{branch_policies=$state.EnvironmentRules}|ConvertTo-Json -Depth 5 -Compress) }
            if ($route -ceq 'repos/example/library/releases?per_page=100') { if ($state.Release) { return (ConvertTo-Json -InputObject @($state.Release) -Depth 8 -Compress) }; return '[]' }
            if ($route -ceq 'repos/example/library/releases/50') { return ($state.Release | ConvertTo-Json -Depth 8 -Compress) }
            if ($route -ceq 'repos/example/library/releases/tags/v1.0.1') { throw 'Draft releases must be resolved by ID, never by an uncreated tag.' }
            if ($route -ceq 'repos/example/library/git/ref/tags/v1.0.1') {
                if ($state.Release.draft) { $global:LASTEXITCODE = 1; return '{"message":"Not Found","status":"404"}' }
                return (@{ object = @{ type = 'commit'; sha = $state.Commit } } | ConvertTo-Json -Depth 5 -Compress)
            }
            if ($route -ceq 'repos/example/library/actions/runs/123') { return ($state.OriginalRun | ConvertTo-Json -Depth 6 -Compress) }
            if ($route -ceq 'repos/example/library/actions/runs/123/jobs?filter=all&per_page=100') { return (@{jobs=@(@{name='build';conclusion=$state.BuildConclusion})}|ConvertTo-Json -Depth 6 -Compress) }
            throw 'Unexpected GitHub API route.'
        }
        if ($Arguments[0] -cne 'release') { throw 'Unexpected GitHub command.' }
        switch ($Arguments[1]) {
            'create' { if ($state.ContainsKey('FailCreate') -and $state.FailCreate) { $state.FailCreate=$false; $global:LASTEXITCODE=1; return }; $state.Release = @{ id=50;target_commitish=$state.Commit;name = 'Example 1.0.1'; tag_name = 'v1.0.1'; body = Get-Content -LiteralPath (Join-Path $state.Root 'artifacts/release/RELEASE-NOTES.md') -Raw; draft = $true; prerelease = $false; html_url = 'https://github.com/example/library/releases/tag/v1.0.1'; assets = @() } }
            'upload' {
                if ($state.FailUpload) { $state.FailUpload = $false; $global:LASTEXITCODE = 1; return }
                $file = Get-Item -LiteralPath $Arguments[3]
                $state.Uploads++; $state.Release.assets += @{ name = $file.Name; size = $file.Length; digest = 'sha256:' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            'edit' { $state.Release.draft = $false }
            default { throw 'Unexpected GitHub release mutation.' }
        }
    }
    Assert-ReleaseSourceUnchanged $fixture $plan; $checks++
    $global:ReleaseFixture.DirtySource = 'Runtime.cs'
    Reject { Assert-ReleaseSourceUnchanged $fixture $plan }
    $global:ReleaseFixture.Remove('DirtySource')
    $env:GITHUB_REF='refs/heads/main';Assert-ReleaseExecutionRef '1.0.1';$checks++
    $env:GITHUB_REF='refs/tags/v1.0.1';Assert-ReleaseExecutionRef '1.0.1';$checks++
    foreach($executionRef in @('refs/heads/feature','refs/tags/v1.0.2','refs/tags/v-publication-test')){$env:GITHUB_REF=$executionRef;Reject { Assert-ReleaseExecutionRef '1.0.1' }}
    $env:GITHUB_REF='refs/heads/main'
    $global:ReleaseFixture.EnvironmentRules=@(@{type='branch';name='main'},@{type='tag';name='v*'})
    $policy=Test-ReleaseRepositoryPolicy 'example/library';Check ($policy.State -ceq 'NoEnvironment' -and $policy.ReadOnly) 'An environment was required unnecessarily.'
    $global:ReleaseFixture.EnvironmentPolicy=$null
    $policy=Test-ReleaseRepositoryPolicy 'example/library' 'release';Check ($policy.State -ceq 'Unrestricted') 'Unrestricted environment rejected.'
    $global:ReleaseFixture.EnvironmentPolicy=@{custom_branch_policies=$true;protected_branches=$false}
    $policy=Test-ReleaseRepositoryPolicy 'example/library' 'release';Check ($policy.State -ceq 'SelectedRefs' -and $policy.Rules.Count -eq 2) 'Existing environment rules were not inspected.'
    $global:ReleaseFixture.EnvironmentRules=@()
    $policy=Test-ReleaseRepositoryPolicy 'example/library' 'release';Check ($policy.State -ceq 'SelectedRefs' -and $policy.Rules.Count -eq 0) 'Empty selected-ref policy was mistaken for unrestricted.'
    $global:ReleaseFixture.EnvironmentPolicy=@{custom_branch_policies=$false;protected_branches=$true}
    $policy=Test-ReleaseRepositoryPolicy 'example/library' 'release';Check ($policy.State -ceq 'ProtectedBranches') 'Protected-branch mode was not inspected.'
    $env:GITHUB_WORKFLOW_REF = 'example/library/.github/workflows/publish.yml@refs/heads/main'
    $global:ReleaseFixture.OriginalRun = @{repository=@{full_name='example/library'};head_sha=$commit;status='completed';event='workflow_dispatch';path='.github/workflows/publish.yml'}
    $global:ReleaseFixture.BuildConclusion = 'success'
    Assert-ReleaseArtifactRun '123' $commit; $checks++
    foreach($case in @(@{Key='head_sha';Bad=('b'*40)},@{Key='path';Bad='.github/workflows/other.yml'},@{Key='status';Bad='in_progress'},@{Key='event';Bad='pull_request'})) {
        $previous=$global:ReleaseFixture.OriginalRun[$case.Key];$global:ReleaseFixture.OriginalRun[$case.Key]=$case.Bad
        Reject { Assert-ReleaseArtifactRun '123' $commit }
        $global:ReleaseFixture.OriginalRun[$case.Key]=$previous
    }
    $global:ReleaseFixture.OriginalRun.repository.full_name='other/library';Reject { Assert-ReleaseArtifactRun '123' $commit };$global:ReleaseFixture.OriginalRun.repository.full_name='example/library'
    $global:ReleaseFixture.BuildConclusion='failure';Reject { Assert-ReleaseArtifactRun '123' $commit };$global:ReleaseFixture.BuildConclusion='success'
    $env:RELEASE_SOURCE_COMMIT=$commit;$env:RELEASE_SOURCE_RUN_ID='123';$env:GITHUB_SHA='b'*40
    Check ((Get-ReleaseHead $fixture) -ceq $commit) 'Explicit frozen source recovery rejected.'
    $env:RELEASE_SOURCE_RUN_ID='';Reject { Get-ReleaseHead $fixture };$env:RELEASE_SOURCE_RUN_ID='123'
    $global:ReleaseFixture.FailCreate=$true
    Reject { & "$PSScriptRoot/Publish-Release.ps1" -Root $fixture -Version '1.0.1' }
    Check ($global:ReleaseFixture.Pushes -eq 0 -and !$global:ReleaseFixture.Release) 'GitHub draft access failure occurred after an irreversible NuGet push.'
    Reject { & "$PSScriptRoot/Publish-Release.ps1" -Root $fixture -Version '1.0.1' }
    Check ($global:ReleaseFixture.Pushes -eq 1 -and $global:ReleaseFixture.Release.draft) 'Publication interruption did not retain the frozen draft.'
    & "$PSScriptRoot/Publish-Release.ps1" -Root $fixture -Version '1.0.1'; $checks++
    Check ($global:ReleaseFixture.Pushes -eq 1) 'Recovery repeated an already verified NuGet push.'
    Check (!$global:ReleaseFixture.Release.draft -and $global:ReleaseFixture.Uploads -eq 4) 'Draft was not published with the exact frozen set.'
    & "$PSScriptRoot/Publish-Release.ps1" -Root $fixture -Version '1.0.1'; $checks++
    Check ($global:ReleaseFixture.Pushes -eq 1 -and $global:ReleaseFixture.Uploads -eq 4) 'Idempotent recovery changed publication.'
    $global:ReleaseFixture.Mismatch = $true
    Reject { & "$PSScriptRoot/Publish-Release.ps1" -Root $fixture -Version '1.0.1' }
    $global:ReleaseFixture.Mismatch = $false
    $global:ReleaseFixture.Release.assets[0].digest = 'sha256:' + ('0' * 64)
    Reject { & "$PSScriptRoot/Publish-Release.ps1" -Root $fixture -Version '1.0.1' }
    Check (!(Get-Content -LiteralPath (Join-Path $fixture 'artifacts/publication/publication-receipt.json') -Raw).Contains('fake-short-lived-key')) 'Publishing credential appeared in the receipt.'
    Write-Output "Passed $checks shared release checks; synthetic packages, fake credentials and no network publication."
} finally {
    foreach ($name in 'git','gh','dotnet','Invoke-RestMethod','Invoke-WebRequest') { Remove-Item -LiteralPath "Function:$name" -ErrorAction SilentlyContinue }
    Remove-Variable ReleaseFixture -Scope Global -ErrorAction SilentlyContinue
    foreach ($variable in $variables) { [Environment]::SetEnvironmentVariable($variable, $saved[$variable]) }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or [IO.Path]::GetFileName($resolved) -notlike 'SharedRelease-*') { throw 'Unexpected fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
