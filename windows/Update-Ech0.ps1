param(
    [string]$SourceExecutable = (Join-Path $PSScriptRoot "Ech0Windows.exe"),
    [string]$ExpectedHashFile = (Join-Path $PSScriptRoot "Ech0Windows.exe.sha256"),
    [switch]$VerifyOnly,
    [switch]$AllowUnsignedDevelopment
)

$ErrorActionPreference = "Stop"
$ExpectedPublisherThumbprint = "__ECH0_PUBLISHER_THUMBPRINT__"

function Assert-UpdateArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$HashFile
    )

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "Ech0Windows.exe was not found."
    }
    if (-not (Test-Path -LiteralPath $HashFile -PathType Leaf)) {
        throw "Ech0Windows.exe.sha256 was not found."
    }

    $hashLine = (Get-Content -LiteralPath $HashFile -Raw).Trim()
    if ($hashLine -notmatch '^(?<hash>[A-Fa-f0-9]{64})(?:\s+.*)?$') {
        throw "The update hash file is invalid."
    }
    $expectedHash = $Matches.hash.ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $expectedHash) {
        throw "The update executable does not match its SHA-256 manifest."
    }

    if ($AllowUnsignedDevelopment) {
        return
    }
    if ($ExpectedPublisherThumbprint -eq "__ECH0_PUBLISHER_THUMBPRINT__") {
        throw "This updater was not prepared by the signed Windows release pipeline."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Executable
    $actualThumbprint = $signature.SignerCertificate.Thumbprint
    $signatureIsValid = $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid
    $thumbprintIsPresent = -not [string]::IsNullOrWhiteSpace($actualThumbprint)
    $thumbprintMatches = $actualThumbprint -ieq $ExpectedPublisherThumbprint
    if (-not ($signatureIsValid -and $thumbprintIsPresent -and $thumbprintMatches)) {
        throw "The update executable does not have the expected Ech0 Authenticode signature."
    }
}

try {
    Assert-UpdateArtifact -Executable $SourceExecutable -HashFile $ExpectedHashFile
    if ($VerifyOnly) {
        Write-Output "Ech0 update artifact verified."
        exit 0
    }

    $installDirectory = Join-Path $env:LOCALAPPDATA "Ech0"
    $target = [IO.Path]::GetFullPath((Join-Path $installDirectory "Ech0Windows.exe"))
    $source = [IO.Path]::GetFullPath($SourceExecutable)
    if ($source -ieq $target) {
        throw "Run the updater from an extracted update package, not the install directory."
    }

    $targetProcesses = @(Get-Process -Name "Ech0Windows" -ErrorAction SilentlyContinue | Where-Object {
        $processPath = $null
        try { $processPath = $_.Path } catch { }
        -not [string]::IsNullOrWhiteSpace($processPath) -and
            [IO.Path]::GetFullPath($processPath) -ieq $target
    })
    foreach ($process in $targetProcesses) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
    }
    foreach ($process in $targetProcesses) {
        if (-not $process.WaitForExit(10000)) {
            throw "The installed Ech0 process did not stop within ten seconds."
        }
    }

    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    $temporary = "$target.$PID.new"
    $backup = "$target.$PID.bak"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary -Force
        Assert-UpdateArtifact -Executable $temporary -HashFile $ExpectedHashFile
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            [IO.File]::Replace($temporary, $target, $backup, $true)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $target)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }

    Start-Process -FilePath $target
} catch {
    Write-Error $_
    exit 1
}
