[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Start", "Observe", "Stop")]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$StatePath,

    [string]$CandidateExecutable,
    [string]$ExpectedProductVersion,
    [string]$StableExecutable,
    [switch]$RestoreStable
)

$ErrorActionPreference = "Stop"
$logPath = Join-Path $env:LOCALAPPDATA "Ech0\logs\ech0.log"
$settingsPath = Join-Path $env:LOCALAPPDATA "Ech0\settings.json"

function Get-Ech0Processes {
    @(Get-CimInstance Win32_Process | Where-Object Name -eq "Ech0Windows.exe")
}

function Get-RegistryTreeHash {
    param([string[]]$Paths)

    $items = [Collections.Generic.List[string]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $keys = @((Get-Item -LiteralPath $path)) +
            @(Get-ChildItem -LiteralPath $path -Recurse -ErrorAction SilentlyContinue)
        foreach ($key in $keys) {
            $items.Add($key.Name)
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            foreach ($property in @($properties.PSObject.Properties | Where-Object Name -NotMatch "^PS" | Sort-Object Name)) {
                $value = if ($property.Value -is [byte[]]) {
                    [Convert]::ToBase64String($property.Value)
                } else {
                    [string]$property.Value
                }
                $items.Add("$($property.Name)=$value")
            }
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((@($items | Sort-Object) -join "`n"))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-Invariants {
    $audioPaths = @(
        "HKCU:\Software\Microsoft\Multimedia\Sound Mapper",
        "HKCU:\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig"
    )
    [ordered]@{
        SettingsSHA256 = if (Test-Path -LiteralPath $settingsPath) {
            (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
        } else { $null }
        RoutingSHA256 = Get-RegistryTreeHash -Paths $audioPaths
        ParsecPids = @(
            Get-Process -ErrorAction SilentlyContinue |
                Where-Object ProcessName -Like "*parsec*" |
                Sort-Object Id |
                ForEach-Object { $_.Id }
        )
    }
}

function Send-ControlCommand {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutMilliseconds = 2_000
    )

    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        ".",
        "Ech0WindowsAutomation-$Token",
        [IO.Pipes.PipeDirection]::Out,
        [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect($TimeoutMilliseconds)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 128, $true)
        try {
            $writer.WriteLine($Command)
            $writer.Flush()
        } finally {
            $writer.Dispose()
        }
    } finally {
        $pipe.Dispose()
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "Gate state does not exist: $StatePath"
    }
    Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}

function Assert-CandidateIdentity {
    param($State)

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($State.Pid)"
    if ($null -eq $process -or $process.Name -ne "Ech0Windows.exe") {
        throw "Candidate PID $($State.Pid) is not running."
    }
    if (-not $process.ExecutablePath.Equals($State.CandidatePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate path changed; refusing control request."
    }
    $file = Get-Item -LiteralPath $State.CandidatePath
    if ($file.VersionInfo.ProductVersion -ne $State.ProductVersion) {
        throw "Candidate ProductVersion changed; refusing control request."
    }
    if ((Get-FileHash -LiteralPath $State.CandidatePath -Algorithm SHA256).Hash -ne $State.CandidateSHA256) {
        throw "Candidate hash changed; refusing control request."
    }
    $process
}

switch ($Action) {
    "Start" {
        if ([string]::IsNullOrWhiteSpace($CandidateExecutable) -or
            [string]::IsNullOrWhiteSpace($ExpectedProductVersion)) {
            throw "Start requires CandidateExecutable and ExpectedProductVersion."
        }
        if (Test-Path -LiteralPath $StatePath) {
            throw "Gate state already exists; stop or inspect the previous candidate first."
        }
        if ((Get-Ech0Processes).Count -ne 0) {
            throw "An Ech0Windows process is already running."
        }

        $candidate = [IO.Path]::GetFullPath($CandidateExecutable)
        $candidateFile = Get-Item -LiteralPath $candidate
        if ($candidateFile.VersionInfo.ProductVersion -ne $ExpectedProductVersion) {
            throw "Candidate ProductVersion does not match the expected value."
        }
        $stable = $null
        if (-not [string]::IsNullOrWhiteSpace($StableExecutable)) {
            $stablePath = [IO.Path]::GetFullPath($StableExecutable)
            $stableFile = Get-Item -LiteralPath $stablePath
            $stable = [ordered]@{
                Path = $stablePath
                ProductVersion = $stableFile.VersionInfo.ProductVersion
                SHA256 = (Get-FileHash -LiteralPath $stablePath -Algorithm SHA256).Hash
            }
        }

        $token = [Guid]::NewGuid().ToString("N")
        $baseline = Get-Invariants
        $logOffset = if (Test-Path -LiteralPath $logPath) { (Get-Item -LiteralPath $logPath).Length } else { 0 }
        $started = Start-Process -FilePath $candidate -ArgumentList "--automation-control", $token -PassThru
        $state = [ordered]@{
            SchemaVersion = 1
            Pid = $started.Id
            Token = $token
            CandidatePath = $candidate
            ProductVersion = $candidateFile.VersionInfo.ProductVersion
            CandidateSHA256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            StartedAt = (Get-Date).ToString("o")
            LogOffset = $logOffset
            Baseline = $baseline
            Stable = $stable
        }
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($StatePath))
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM

        $deadline = (Get-Date).AddSeconds(10)
        do {
            try {
                Send-ControlCommand -Token $token -Command "probe" -TimeoutMilliseconds 250
                $controlReady = $true
            } catch [TimeoutException] {
                $controlReady = $false
            } catch [IO.IOException] {
                $controlReady = $false
            }
            if (-not $controlReady) { Start-Sleep -Milliseconds 100 }
        } while (-not $controlReady -and -not $started.HasExited -and (Get-Date) -lt $deadline)
        if (-not $controlReady -or $started.HasExited) {
            throw "Candidate automation control did not become ready; gate state was preserved for recovery."
        }

        Assert-CandidateIdentity -State ([pscustomobject]$state) | Out-Null
        [pscustomobject]@{ Result = "started"; Pid = $started.Id; StatePath = $StatePath }
    }

    "Observe" {
        $state = Read-State
        Assert-CandidateIdentity -State $state | Out-Null
        $currentLength = if (Test-Path -LiteralPath $logPath) { (Get-Item -LiteralPath $logPath).Length } else { 0 }
        $events = @()
        if ($currentLength -gt $state.LogOffset) {
            $stream = [IO.File]::Open($logPath, "Open", "Read", "ReadWrite")
            try {
                $stream.Seek($state.LogOffset, "Begin") | Out-Null
                $buffer = [byte[]]::new($currentLength - $state.LogOffset)
                $read = $stream.Read($buffer, 0, $buffer.Length)
            } finally {
                $stream.Dispose()
            }
            $events = @([Text.Encoding]::UTF8.GetString($buffer, 0, $read) -split "`r?`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $state.LogOffset = $currentLength
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM
        [pscustomobject]@{ Result = "observed"; Pid = $state.Pid; LogOffset = $currentLength; Events = $events }
    }

    "Stop" {
        $state = Read-State
        $candidateFile = Get-Item -LiteralPath $state.CandidatePath
        if ($candidateFile.VersionInfo.ProductVersion -ne $state.ProductVersion -or
            (Get-FileHash -LiteralPath $state.CandidatePath -Algorithm SHA256).Hash -ne $state.CandidateSHA256) {
            throw "Candidate artifact identity changed; refusing recovery."
        }
        if (Get-Process -Id $state.Pid -ErrorAction SilentlyContinue) {
            Assert-CandidateIdentity -State $state | Out-Null
            Send-ControlCommand -Token $state.Token -Command "shutdown"
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Process -Id $state.Pid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            if (Get-Process -Id $state.Pid -ErrorAction SilentlyContinue) {
                throw "Candidate did not complete graceful shutdown."
            }
        }

        $final = Get-Invariants
        if ($final.SettingsSHA256 -ne $state.Baseline.SettingsSHA256 -or
            $final.RoutingSHA256 -ne $state.Baseline.RoutingSHA256 -or
            (@($final.ParsecPids) -join ",") -ne (@($state.Baseline.ParsecPids) -join ",")) {
            throw "Settings, routing, or Parsec changed during the gate."
        }

        $stablePid = $null
        if ($RestoreStable) {
            if ($null -eq $state.Stable) {
                throw "Stable restoration was not authorized when the gate started."
            }
            $stableFile = Get-Item -LiteralPath $state.Stable.Path
            if ($stableFile.VersionInfo.ProductVersion -ne $state.Stable.ProductVersion -or
                (Get-FileHash -LiteralPath $state.Stable.Path -Algorithm SHA256).Hash -ne $state.Stable.SHA256) {
                throw "Stable executable identity changed; refusing restoration."
            }
            if ((Get-Ech0Processes).Count -ne 0) {
                throw "An Ech0Windows process appeared before stable restoration."
            }
            $stablePid = (Start-Process -FilePath $state.Stable.Path -ArgumentList "--background" -PassThru).Id
        }

        Remove-Item -LiteralPath $StatePath
        [pscustomobject]@{ Result = "stopped"; CandidatePid = $state.Pid; StablePid = $stablePid }
    }
}
