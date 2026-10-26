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


function Get-CodexSessionFileIdentity {
    param([System.IO.FileInfo]$File)

    $candidateId = Get-CodexSessionFileStem -File $File
    $candidateId = $candidateId -replace '^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-', ''
    $uuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $compositePattern = '^(?<logical>' + $uuidPattern + ')_(?<physical>' + $uuidPattern + ')
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


    if ($candidateId -match $compositePattern) {
        $logicalId = [string]$Matches['logical']
        $physicalId = [string]$Matches['physical']
        return [pscustomobject]@{
            CandidateId = $candidateId
            IsRecognized = $true
            IsComposite = $true
            IsRoot = $false
            LogicalSessionId = $logicalId
            PhysicalSegmentId = $physicalId
        }
    }
    if ($candidateId -match ('^' + $uuidPattern + '
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
)) {
        return [pscustomobject]@{
            CandidateId = $candidateId
            IsRecognized = $true
            IsComposite = $false
            IsRoot = $true
            LogicalSessionId = $candidateId
            PhysicalSegmentId = $candidateId
        }
    }
    return [pscustomobject]@{
        CandidateId = $candidateId
        IsRecognized = $false
        IsComposite = $false
        IsRoot = $false
        LogicalSessionId = ''
        PhysicalSegmentId = ''
    }
}

function Normalize-CodexPaginationQuestionText {
    param([AllowNull()][string]$Text)

    $normalized = [string]$Text
    $newline = [string][char]10
    $carriageReturn = [string][char]13
    $normalized = $normalized -replace ($carriageReturn + $newline), $newline
    $normalized = $normalized -replace $carriageReturn, $newline
    $normalized = $normalized.Trim()
    return ($normalized -replace '\s+', ' ')
}

function Get-CodexPaginationTextElements {
    param([AllowNull()][string]$Text)

    $elements = [System.Collections.Generic.List[string]]::new()
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator([string]$Text)
    while ($enumerator.MoveNext()) {
        $elements.Add([string]$enumerator.GetTextElement())
    }
    return $elements.ToArray()
}

function Test-CodexPaginationQuestionTextMatch {
    param(
        [AllowNull()][string]$LeftText,
        [AllowNull()][string]$RightText
    )

    $leftNormalized = Normalize-CodexPaginationQuestionText -Text $LeftText
    $rightNormalized = Normalize-CodexPaginationQuestionText -Text $RightText
    $leftElements = @(Get-CodexPaginationTextElements -Text $leftNormalized)
    $rightElements = @(Get-CodexPaginationTextElements -Text $rightNormalized)

    if ($leftElements.Count -lt 12 -or $rightElements.Count -lt 12) { return $false }
    if ([string]::Equals($leftNormalized, $rightNormalized, [System.StringComparison]::Ordinal)) { return $true }
    if ([Math]::Abs($leftElements.Count - $rightElements.Count) -gt 1) { return $false }

    $leftIndex = 0
    $rightIndex = 0
    $edits = 0
    while ($leftIndex -lt $leftElements.Count -and $rightIndex -lt $rightElements.Count) {
        if ([string]::Equals([string]$leftElements[$leftIndex], [string]$rightElements[$rightIndex], [System.StringComparison]::Ordinal)) {
            $leftIndex++
            $rightIndex++
            continue
        }
        $edits++
        if ($edits -gt 1) { return $false }
        if ($leftElements.Count -eq $rightElements.Count) {
            $leftIndex++
            $rightIndex++
        } elseif ($leftElements.Count -gt $rightElements.Count) {
            $leftIndex++
        } else {
            $rightIndex++
        }
    }
    if ($leftIndex -lt $leftElements.Count -or $rightIndex -lt $rightElements.Count) { $edits++ }
    return ($edits -eq 1)
}

function Get-CodexPaginationBoundaryDecision {
    param(
        [object[]]$PreviousEvents,
        [object[]]$NextEvents
    )

    $previousDialogue = @($PreviousEvents | Where-Object {
        -not ([string]$_.kind -eq 'system' -and [string]$_.summary -in @('task_started', 'task_complete'))
    })
    $nextDialogue = @($NextEvents | Where-Object {
        -not ([string]$_.kind -eq 'system' -and [string]$_.summary -in @('task_started', 'task_complete'))
    })
    if ($previousDialogue.Count -eq 0 -or $nextDialogue.Count -eq 0) { return $null }

    $previousQuestion = $previousDialogue[$previousDialogue.Count - 1]
    $nextQuestion = $nextDialogue[0]
    if ([string]$previousQuestion.kind -ne 'user' -or [string]$nextQuestion.kind -ne 'user') { return $null }

    $decision = [ordered]@{
        Candidate = $true
        ShouldMerge = $false
        Reason = ''
        CanonicalEvent = $previousQuestion
        DuplicateEvent = $nextQuestion
        TimeDeltaSeconds = $null
    }
    $previousStableId = ([string]$previousQuestion.stableItemId).Trim()
    $nextStableId = ([string]$nextQuestion.stableItemId).Trim()
    if ([string]::IsNullOrWhiteSpace($previousStableId) -or
        [string]::IsNullOrWhiteSpace($nextStableId) -or
        [string]::Equals($previousStableId, $nextStableId, [System.StringComparison]::Ordinal)) {
        $decision.Reason = 'stable-event-id-not-distinct'
        return [pscustomobject]$decision
    }

    $previousText = Normalize-CodexPaginationQuestionText -Text ([string]$previousQuestion.rawText)
    $nextText = Normalize-CodexPaginationQuestionText -Text ([string]$nextQuestion.rawText)
    $previousLength = @((Get-CodexPaginationTextElements -Text $previousText)).Count
    $nextLength = @((Get-CodexPaginationTextElements -Text $nextText)).Count
    if ($previousLength -lt 12 -or $nextLength -lt 12) {
        $decision.Reason = 'short-text'
        return [pscustomobject]$decision
    }
    if (-not (Test-CodexPaginationQuestionTextMatch -LeftText $previousText -RightText $nextText)) {
        $decision.Reason = 'text-mismatch'
        return [pscustomobject]$decision
    }

    $previousTime = $null
    $nextTime = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$previousQuestion.timestamp)) {
            $previousTime = [DateTimeOffset]::Parse([string]$previousQuestion.timestamp, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$nextQuestion.timestamp)) {
            $nextTime = [DateTimeOffset]::Parse([string]$nextQuestion.timestamp, [System.Globalization.CultureInfo]::InvariantCulture)
        }
    } catch {
        $decision.Reason = 'invalid-timestamp'
        return [pscustomobject]$decision
    }
    if ($null -eq $previousTime -or $null -eq $nextTime) {
        $decision.Reason = 'missing-timestamp'
        return [pscustomobject]$decision
    }
    $delta = [Math]::Abs(($nextTime - $previousTime).TotalSeconds)
    $decision.TimeDeltaSeconds = $delta
    if ($delta -gt 60) {
        $decision.Reason = 'time-window-exceeded'
        return [pscustomobject]$decision
    }

    $decision.ShouldMerge = $true
    $decision.Reason = 'high-confidence-boundary-duplicate'
    return [pscustomobject]$decision
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
