# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
# Real compiler-generated DLL/PDB pairs; synthetic archives, no publication or credentials.
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/LibrarySymbols.psm1" -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('LibrarySymbols-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$checks = 0
$succeeded = $false
function Check([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Operation) { $failed = $false; try { & $Operation | Out-Null } catch { $failed = $true }; Check $failed 'Invalid symbols were accepted.' }
function Write-Archive([string]$Path, [hashtable]$Entries) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in $Entries.GetEnumerator()) {
            $stream = $zip.CreateEntry($item.Key).Open()
            try { $bytes = if ($item.Value -is [byte[]]) { $item.Value } else { [Text.Encoding]::UTF8.GetBytes([string]$item.Value) }; $stream.Write($bytes, 0, $bytes.Length) }
            finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
try {
    foreach ($name in 'First','Second') {
        $directory = Join-Path $fixture $name
        $null = New-Item -ItemType Directory -Path $directory
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><AssemblyName>Example</AssemblyName><DebugType>portable</DebugType><DebugSymbols>true</DebugSymbols><Optimize>true</Optimize></PropertyGroup></Project>' | Set-Content (Join-Path $directory 'Example.csproj')
        "// Copyright (c) 2026 Neil Colvin. MIT License.`npublic static class Example { public static string Value => `"$name`"; }" | Set-Content (Join-Path $directory 'Example.cs')
        & dotnet build (Join-Path $directory 'Example.csproj') -c Release -p:RestoreIgnoreFailedSources=true *> (Join-Path $directory 'build.log')
        if ($LASTEXITCODE -ne 0) { throw "Fixture compilation failed; see $directory/build.log." }
    }
    $dll = [IO.File]::ReadAllBytes((Join-Path $fixture 'First/bin/Release/net10.0/Example.dll'))
    $pdb = [IO.File]::ReadAllBytes((Join-Path $fixture 'First/bin/Release/net10.0/Example.pdb'))
    $otherPdb = [IO.File]::ReadAllBytes((Join-Path $fixture 'Second/bin/Release/net10.0/Example.pdb'))
    $spec = '<package><metadata><id>Example</id><version>1.0.1</version></metadata></package>'
    $symbolSpec = '<package><metadata><id>Example</id><version>1.0.1</version><packageTypes><packageType name="SymbolsPackage" /></packageTypes></metadata></package>'
    $package = Join-Path $fixture 'Example.1.0.1.nupkg'
    Write-Archive $package @{ 'Example.nuspec' = $spec; 'lib/net10.0/Example.dll' = $dll }
    $symbols = Join-Path $fixture 'Example.1.0.1.snupkg'
    Write-Archive $symbols @{ 'Example.nuspec' = $symbolSpec; 'lib/net10.0/Example.pdb' = $pdb }
    $result = Test-LibrarySymbolPair $package $symbols
    Check ($result.Binaries -eq 1 -and !$result.Metapackage) 'Matching portable PDB rejected.'
    Reject { Test-LibrarySymbolPair $package (Join-Path $fixture 'missing.snupkg') }
    $variants = @{
        Mismatch = @{ 'Example.nuspec' = $symbolSpec; 'lib/net10.0/Example.pdb' = $otherPdb }
        Invalid = @{ 'Example.nuspec' = $symbolSpec; 'lib/net10.0/Example.pdb' = [byte[]](1,2,3,4) }
        Framework = @{ 'Example.nuspec' = $symbolSpec; 'lib/net472/Example.pdb' = $pdb }
        Identity = @{ 'Example.nuspec' = $symbolSpec.Replace('<id>Example</id>','<id>Other</id>'); 'lib/net10.0/Example.pdb' = $pdb }
        Version = @{ 'Example.nuspec' = $symbolSpec.Replace('1.0.1','1.0.2'); 'lib/net10.0/Example.pdb' = $pdb }
        Type = @{ 'Example.nuspec' = $symbolSpec.Replace('SymbolsPackage','Dependency'); 'lib/net10.0/Example.pdb' = $pdb }
        ExtraBinary = @{ 'Example.nuspec' = $symbolSpec; 'lib/net10.0/Example.pdb' = $pdb; 'lib/net10.0/Example.dll' = $dll }
        ExtraPdb = @{ 'Example.nuspec' = $symbolSpec; 'lib/net10.0/Example.pdb' = $pdb; 'lib/net10.0/Other.pdb' = $pdb }
        Unsafe = @{ 'Example.nuspec' = $symbolSpec; 'lib/net10.0/Example.pdb' = $pdb; '../outside.xml' = '<invalid />' }
    }
    foreach ($variant in $variants.GetEnumerator()) {
        $path = Join-Path $fixture ($variant.Key + '.snupkg')
        Write-Archive $path $variant.Value
        Reject { Test-LibrarySymbolPair $package $path }
    }
    $meta = Join-Path $fixture 'Meta.nupkg'
    Write-Archive $meta @{ 'Meta.nuspec' = $spec }
    $result = Test-LibrarySymbolPair $meta (Join-Path $fixture 'Meta.snupkg')
    Check ($result.Metapackage -and $result.Binaries -eq 0) 'Dependency-only package required an empty PDB.'
    Reject { Test-LibrarySymbolPair $meta $symbols }
    $directory = Join-Path $fixture 'Directory'
    $null = New-Item -ItemType Directory -Path $directory
    Copy-Item -LiteralPath $package,$symbols -Destination $directory
    $result = @(Test-LibrarySymbolDirectory $directory)
    Check ($result.Count -eq 1 -and $result[0].Binaries -eq 1) 'Directory verification failed.'
    Copy-Item -LiteralPath $symbols -Destination (Join-Path $directory 'Orphan.snupkg')
    Reject { Test-LibrarySymbolDirectory $directory }
    $succeeded = $true
    Write-Output "Passed $checks library symbol checks using real compiled DLL/PDB pairs."
} finally {
    if ($succeeded) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or [IO.Path]::GetFileName($resolved) -notlike 'LibrarySymbols-*') { throw 'Unexpected symbol fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { Write-Output "Retained failed symbol fixture: $fixture" }
}
