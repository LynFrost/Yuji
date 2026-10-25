function Test-IsCompressedCodexSessionFile {
    param([System.IO.FileInfo]$File)
    return ($null -ne $File -and $File.Name.EndsWith('.jsonl.zst', [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-CodexSessionFileStem {
    param([System.IO.FileInfo]$File)
    if ($null -eq $File) { return '' }
    if (Test-IsCompressedCodexSessionFile -File $File) {
        return $File.Name.Substring(0, $File.Name.Length - '.jsonl.zst'.Length)
    }
    if ($File.Name.EndsWith('.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $File.Name.Substring(0, $File.Name.Length - '.jsonl'.Length)
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
}

function Test-CodexSessionFileReadable {
    param([System.IO.FileInfo]$File)
    if ($null -eq $File) { return $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        return $true
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-CodexSessionFiles {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }

    $normalFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    $compressedFiles = @(
        Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.jsonl.zst' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-.+\.jsonl\.zst$' }
    )
    $excludedNormalPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $selectedFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($compressedFile in $compressedFiles) {
        $normalPath = $compressedFile.FullName.Substring(0, $compressedFile.FullName.Length - '.zst'.Length)
        if (Test-Path -LiteralPath $normalPath -PathType Leaf) {
            $normalFile = $null
            try {
                $normalFile = Get-Item -LiteralPath $normalPath -ErrorAction Stop
            } catch {
                [void]$excludedNormalPaths.Add([System.IO.Path]::GetFullPath($normalPath))
            }
            if ($null -ne $normalFile) {
                if (Test-CodexSessionFileReadable -File $normalFile) {
                    continue
                }
                [void]$excludedNormalPaths.Add([System.IO.Path]::GetFullPath($normalPath))
            }
        }
        [void]$selectedFiles.Add($compressedFile)
    }

    foreach ($normalFile in $normalFiles) {
        $normalPath = [System.IO.Path]::GetFullPath($normalFile.FullName)
        if ($excludedNormalPaths.Contains($normalPath)) { continue }
        [void]$selectedFiles.Add($normalFile)
    }

    return @($selectedFiles | Sort-Object FullName -Unique)
}

function Get-ZstdSharpAssemblyPath {
    $version = '0.8.8'
    $loadedType = 'ZstdSharp.DecompressionStream' -as [type]
    if ($null -ne $loadedType) {
        return $loadedType.Assembly.Location
    }

    $cacheBase = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA
    } elseif (-not [string]::IsNullOrWhiteSpace($env:XDG_CACHE_HOME)) {
        $env:XDG_CACHE_HOME
    } else {
        Join-Path $HOME '.cache'
    }
    $cacheDirectory = Join-Path (Join-Path (Join-Path (Join-Path $cacheBase 'Yuji') 'dependencies') 'ZstdSharp.Port') $version
    $assemblyPath = Join-Path $cacheDirectory 'ZstdSharp.dll'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $assemblyPath -PathType Leaf) {
        try {
            $assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($assemblyPath)
            if ($assemblyName.Name -eq 'ZstdSharp') {
                Add-Type -Path $assemblyPath -ErrorAction Stop | Out-Null
                return $assemblyPath
            }
        } catch {
            Remove-Item -LiteralPath $assemblyPath -Force -ErrorAction SilentlyContinue
        }
    }

    $packageUri = 'https://api.nuget.org/v3-flatcontainer/zstdsharp.port/0.8.8/zstdsharp.port.0.8.8.nupkg'
    $downloadDirectory = Join-Path $cacheDirectory ('.download-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
    $packageStream = $null
    $archive = $null
    $entryStream = $null
    $outputStream = $null
    try {
        $packagePath = Join-Path $downloadDirectory 'zstdsharp.port.0.8.8.nupkg'
        $candidatePath = Join-Path $downloadDirectory 'ZstdSharp.dll'
        Invoke-WebRequest -Uri $packageUri -OutFile $packagePath -TimeoutSec 60 -ErrorAction Stop
        if ((Get-Item -LiteralPath $packagePath).Length -lt 1024) {
            throw 'The downloaded NuGet package is unexpectedly small.'
        }

        Add-Type -AssemblyName System.IO.Compression
        $packageStream = [System.IO.File]::OpenRead($packagePath)
        $archive = [System.IO.Compression.ZipArchive]::new($packageStream, [System.IO.Compression.ZipArchiveMode]::Read)
        $entry = $archive.Entries | Where-Object { $_.FullName -eq 'lib/net5.0/ZstdSharp.dll' } | Select-Object -First 1
        if ($null -eq $entry) {
            $entry = $archive.Entries | Where-Object { $_.FullName -eq 'lib/netstandard2.0/ZstdSharp.dll' } | Select-Object -First 1
        }
        if ($null -eq $entry) {
            throw 'The pinned NuGet package does not contain a supported ZstdSharp assembly.'
        }

        $entryStream = $entry.Open()
        $outputStream = [System.IO.File]::Create($candidatePath)
        $entryStream.CopyTo($outputStream)
        $outputStream.Dispose()
        $outputStream = $null
        $entryStream.Dispose()
        $entryStream = $null

        $assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($candidatePath)
        if ($assemblyName.Name -ne 'ZstdSharp') {
            throw 'The downloaded assembly identity did not match ZstdSharp.'
        }
        Move-Item -LiteralPath $candidatePath -Destination $assemblyPath -Force
        Add-Type -Path $assemblyPath -ErrorAction Stop | Out-Null
        return $assemblyPath
    } catch {
        throw ("Unable to prepare the pinned ZstdSharp.Port {0} decoder. Check network access to NuGet and retry. Details: {1}" -f $version, $_.Exception.Message)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($entryStream) { $entryStream.Dispose() }
        if ($archive) { $archive.Dispose() }
        if ($packageStream) { $packageStream.Dispose() }
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
