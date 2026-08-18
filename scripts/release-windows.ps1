param(
    [switch]$AllowUnsignedDevelopment,
    [string]$Dotnet = "dotnet"
)

$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$outputDirectory = Join-Path $repoRoot "dist\windows"
$publishDirectory = Join-Path $outputDirectory "publish"
$testProject = Join-Path $repoRoot "windows\Ech0Windows.Tests\Ech0Windows.Tests.csproj"
$appProject = Join-Path $repoRoot "windows\Ech0Windows\Ech0Windows.csproj"
$nugetSource = "https://api.nuget.org/v3/index.json"

& $Dotnet restore $testProject --source $nugetSource
if ($LASTEXITCODE -ne 0) { throw "Windows dependency restore failed." }
& $Dotnet test $testProject -c Release --no-restore
if ($LASTEXITCODE -ne 0) { throw "Windows tests failed." }

Remove-Item -LiteralPath $outputDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
& $Dotnet publish $appProject -c Release -r win-x64 --self-contained true --no-restore -o $publishDirectory
if ($LASTEXITCODE -ne 0) { throw "Windows publish failed." }

$executable = Join-Path $publishDirectory "Ech0Windows.exe"
$installZip = Join-Path $outputDirectory "Ech0Windows-win-x64.zip"
$updateZip = Join-Path $outputDirectory "Ech0Windows-update.zip"
$hashFile = Join-Path $outputDirectory "Ech0Windows.exe.sha256"
$updateScript = Join-Path $outputDirectory "Update-Ech0.ps1"
$updateLauncher = Join-Path $outputDirectory "Update-Ech0.cmd"
$licenseFile = Join-Path $outputDirectory "LICENSE"
$noticeFile = Join-Path $outputDirectory "NOTICE"
$thirdPartyNoticesFile = Join-Path $outputDirectory "THIRD_PARTY_NOTICES.md"

Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination $licenseFile
Copy-Item -LiteralPath (Join-Path $repoRoot "NOTICE") -Destination $noticeFile
Copy-Item -LiteralPath (Join-Path $repoRoot "THIRD_PARTY_NOTICES.md") -Destination $thirdPartyNoticesFile

if ($AllowUnsignedDevelopment) {
    Compress-Archive `
        -LiteralPath $executable, $licenseFile, $noticeFile, $thirdPartyNoticesFile `
        -DestinationPath $installZip `
        -Force
    (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath $hashFile -NoNewline
    & (Join-Path $repoRoot "windows\Update-Ech0.ps1") `
        -SourceExecutable $executable `
        -ExpectedHashFile $hashFile `
        -VerifyOnly `
        -AllowUnsignedDevelopment
    if ($LASTEXITCODE -ne 0) { throw "Unsigned community artifact verification failed." }
    Write-Warning "Unsigned community build: no automatic update package was created."
} else {
    $thumbprint = $env:ECH0_WINDOWS_CERT_THUMBPRINT
    $timestampUrl = $env:ECH0_TIMESTAMP_URL
    if ([string]::IsNullOrWhiteSpace($thumbprint) -or [string]::IsNullOrWhiteSpace($timestampUrl)) {
        throw "Signed release requires ECH0_WINDOWS_CERT_THUMBPRINT and ECH0_TIMESTAMP_URL."
    }
    $certificate = Get-ChildItem -Path "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
    $signtool = (Get-Command "signtool.exe" -ErrorAction Stop).Source
    & $signtool sign /sha1 $thumbprint /fd SHA256 /tr $timestampUrl /td SHA256 $executable
    if ($LASTEXITCODE -ne 0) { throw "Authenticode executable signing failed." }

    $exeSignature = Get-AuthenticodeSignature -LiteralPath $executable
    $exeSignatureIsValid = $exeSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid
    $exeSignerMatches = $exeSignature.SignerCertificate.Thumbprint -ieq $thumbprint
    if (-not ($exeSignatureIsValid -and $exeSignerMatches)) {
        throw "Signed executable verification failed."
    }

    $template = Get-Content -LiteralPath (Join-Path $repoRoot "windows\Update-Ech0.ps1") -Raw
    $template.Replace("__ECH0_PUBLISHER_THUMBPRINT__", $thumbprint.ToUpperInvariant()) |
        Set-Content -LiteralPath $updateScript -NoNewline
    $scriptSignature = Set-AuthenticodeSignature `
        -LiteralPath $updateScript `
        -Certificate $certificate `
        -TimestampServer $timestampUrl `
        -HashAlgorithm SHA256
    if ($scriptSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Signed updater verification failed."
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot "windows\Update-Ech0.cmd") -Destination $updateLauncher

    (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath $hashFile -NoNewline
    & $updateScript -SourceExecutable $executable -ExpectedHashFile $hashFile -VerifyOnly
    if ($LASTEXITCODE -ne 0) { throw "Signed update artifact verification failed." }

    Compress-Archive `
        -LiteralPath $executable, $licenseFile, $noticeFile, $thirdPartyNoticesFile `
        -DestinationPath $installZip `
        -Force
    Compress-Archive `
        -LiteralPath $executable, $hashFile, $updateScript, $updateLauncher `
        -DestinationPath $updateZip `
        -Force
}

$artifacts = @($executable, $installZip)
if (Test-Path -LiteralPath $updateZip) { $artifacts += $updateZip }
$artifacts | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($_))"
} | Set-Content -LiteralPath (Join-Path $outputDirectory "SHA256SUMS")

Write-Output $installZip
