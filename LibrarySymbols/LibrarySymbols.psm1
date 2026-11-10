# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-LibrarySymbolArchive {
    param([IO.Compression.ZipArchive]$Archive)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Archive.Entries) {
        if (!$entry.Name -or !$names.Add($entry.FullName) -or $entry.FullName -match '(^/|^[A-Za-z]:|\\|(^|/)\.\.(/|$))') { throw 'Unsafe or duplicate library archive entry.' }
    }
    $specs = @($Archive.Entries | Where-Object FullName -CMatch '^[^/]+\.nuspec$')
    if ($specs.Count -ne 1) { throw 'Exactly one root nuspec is required.' }
    $reader = [IO.StreamReader]::new($specs[0].Open())
    try { [xml]$spec = $reader.ReadToEnd() } finally { $reader.Dispose() }
    return $spec
}

function Copy-LibrarySymbolEntry {
    param([IO.Compression.ZipArchiveEntry]$Entry)
    $memory = [IO.MemoryStream]::new()
    $inputStream = $Entry.Open()
    try { $inputStream.CopyTo($memory); $memory.Position = 0; return ,$memory }
    catch { $memory.Dispose(); throw }
    finally { $inputStream.Dispose() }
}

function Test-LibrarySymbolPair {
    param([Parameter(Mandatory)][string]$PackagePath, [Parameter(Mandatory)][string]$SymbolPath)
    $package = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $spec = Read-LibrarySymbolArchive $package
        $binaries = @($package.Entries | Where-Object FullName -CMatch '^lib/[^/]+/[^/]+\.dll$')
        if (!$binaries.Count) {
            if (Test-Path -LiteralPath $SymbolPath) { throw 'A dependency-only metapackage must not have an empty symbol package.' }
            return @{ Id = [string]$spec.package.metadata.id; Version = [string]$spec.package.metadata.version; Binaries = 0; Metapackage = $true }
        }
        if (!(Test-Path -LiteralPath $SymbolPath -PathType Leaf)) { throw 'A separate symbol package is required for every binary library package.' }
        $symbols = [IO.Compression.ZipFile]::OpenRead($SymbolPath)
        try {
            $symbolSpec = Read-LibrarySymbolArchive $symbols
            if ($symbolSpec.package.metadata.id -cne $spec.package.metadata.id -or $symbolSpec.package.metadata.version -cne $spec.package.metadata.version -or $symbolSpec.package.metadata.packageTypes.packageType.name -cne 'SymbolsPackage') { throw 'Symbol package identity, version or type differs from its library.' }
            if (@($symbols.Entries | Where-Object { [IO.Path]::GetExtension($_.FullName) -cnotin '.pdb','.nuspec','.xml','.psmdcp','.rels','.p7s' }).Count) { throw 'Unexpected symbol package payload.' }
            $pdbs = @($symbols.Entries | Where-Object FullName -CLike '*.pdb')
            if ($pdbs.Count -ne $binaries.Count) { throw 'Symbol package must contain exactly one PDB per library DLL and framework.' }
            foreach ($binary in $binaries) {
                $pdbName = [IO.Path]::ChangeExtension($binary.FullName, '.pdb').Replace('\','/')
                $pdb = @($pdbs | Where-Object FullName -CEQ $pdbName)
                if ($pdb.Count -ne 1) { throw 'Missing matching framework PDB.' }
                $dllStream = Copy-LibrarySymbolEntry $binary
                $pdbStream = Copy-LibrarySymbolEntry $pdb[0]
                try {
                    $pe = [System.Reflection.PortableExecutable.PEReader]::new($dllStream)
                    try {
                        $debug = @($pe.ReadDebugDirectory() | Where-Object Type -EQ CodeView)
                        if ($debug.Count -ne 1 -or !$debug[0].IsPortableCodeView) { throw 'Library must reference one portable PDB.' }
                        $codeView = $pe.ReadCodeViewDebugDirectoryData($debug[0])
                        $provider = [System.Reflection.Metadata.MetadataReaderProvider]::FromPortablePdbStream($pdbStream)
                        try {
                            $metadata = $provider.GetMetadataReader()
                            $identity = [System.Reflection.Metadata.BlobContentId]::new($metadata.DebugMetadataHeader.Id)
                            if ($identity.Guid -ne $codeView.Guid -or $identity.Stamp -ne $debug[0].Stamp -or $codeView.Age -ne 1) { throw 'Portable PDB does not belong to this exact library build.' }
                        } finally { $provider.Dispose() }
                    } finally { $pe.Dispose() }
                } finally { $dllStream.Dispose(); $pdbStream.Dispose() }
            }
            return @{ Id = [string]$spec.package.metadata.id; Version = [string]$spec.package.metadata.version; Binaries = $binaries.Count; Metapackage = $false }
        } finally { $symbols.Dispose() }
    } finally { $package.Dispose() }
}

function Test-LibrarySymbolDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    $packages = @(Get-ChildItem -LiteralPath $Directory -Filter *.nupkg -File)
    if (!$packages.Count) { throw 'No library packages found for symbol verification.' }
    $expected = @($packages | ForEach-Object { $_.BaseName + '.snupkg' })
    if (@(Get-ChildItem -LiteralPath $Directory -Filter *.snupkg -File | Where-Object Name -CNotIn $expected).Count) { throw 'Orphan symbol package.' }
    foreach ($package in $packages) { Test-LibrarySymbolPair $package.FullName (Join-Path $Directory ($package.BaseName + '.snupkg')) }
}

Export-ModuleMember -Function Test-LibrarySymbolPair, Test-LibrarySymbolDirectory
