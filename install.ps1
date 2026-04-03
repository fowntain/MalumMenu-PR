[CmdletBinding()]
param(
    [string]$AmongUsPath,
    [string]$PackageType,
    [switch]$Force,
    [switch]$LaunchGame,
    [string]$RepoOwner = "scp222thj",
    [string]$RepoName = "MalumMenu"
)

$ErrorActionPreference = "Stop"

# Logging helpers
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrLine {
    param([string]$Message)
    Write-Host "[ERR ] $Message" -ForegroundColor Red
}

function Resolve-InstallRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        return $null
    }

    $full = $resolved.Path

    if (Test-Path -LiteralPath (Join-Path $full "Among Us.exe")) {
        return $full
    }

    if (Split-Path -Leaf $full -eq "Content" -and (Test-Path -LiteralPath (Join-Path $full "Among Us.exe"))) {
        return $full
    }

    return $null
}

# Map install path to platform package
function Get-PackageTypeForPath {
    param([string]$Path)

    $p = $Path.ToLowerInvariant()

    if ($p -like "*\steamapps\common\among us*" -or $p -like "*\itch\apps\*") {
        return "Steam-Itch"
    }

    if ($p -like "*\epic games\*" -or $p -like "*\xboxgames\among us\content*" -or $p -like "*\windowsapps*") {
        return "MicrosoftStore-EpicGames-XboxApp"
    }

    return $null
}

# Build normalized install target object
function New-InstallTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$PackageType
    )

    [PSCustomObject]@{
        Path = $Path
        Source = $Source
        PackageType = $PackageType
    }
}

# Process-based path detection
function Get-RunningGamePath {
    $processCandidates = @("Among Us.exe", "AmongUs.exe")

    foreach ($exeName in $processCandidates) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.Path -and (Test-Path -LiteralPath $proc.Path)) {
            return Split-Path -Parent $proc.Path
        }
    }

    $wmi = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in $processCandidates -and $_.ExecutablePath
        } |
        Select-Object -First 1

    if ($wmi -and (Test-Path -LiteralPath $wmi.ExecutablePath)) {
        return Split-Path -Parent $wmi.ExecutablePath
    }

    return $null
}

function Get-RunningGameTarget {
    $running = Get-RunningGamePath
    if (-not $running) {
        return $null
    }

    $pkg = Get-PackageTypeForPath -Path $running
    if (-not $pkg) {
        # Safe fallback package for unknown paths
        $pkg = "Steam-Itch"
        Write-WarnLine "Could not infer install type from running process path. Defaulting to Steam-Itch package."
    }

    return (New-InstallTarget -Path $running -Source "Running process" -PackageType $pkg)
}

function Get-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $defaultSteam = "C:\Program Files (x86)\Steam"
    if (Test-Path -LiteralPath $defaultSteam) {
        [void]$roots.Add($defaultSteam)
    }

    foreach ($regPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        try {
            $steamPath = (Get-ItemProperty -Path $regPath -ErrorAction Stop).SteamPath
            if ($steamPath -and (Test-Path -LiteralPath $steamPath)) {
                [void]$roots.Add($steamPath)
            }
        }
        catch {
        }
    }

    $roots | Select-Object -Unique
}

# Steam detection (default + libraryfolders)
function Get-SteamGamePaths {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($steamRoot in Get-SteamLibraryRoots) {
        $defaultGamePath = Join-Path $steamRoot "steamapps\common\Among Us"
        if (Test-Path -LiteralPath (Join-Path $defaultGamePath "Among Us.exe")) {
            [void]$candidates.Add($defaultGamePath)
        }

        $libraryFile = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $libraryFile)) {
            continue
        }

        try {
            $content = Get-Content -LiteralPath $libraryFile -Raw
            $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
            foreach ($m in $matches) {
                $libraryPath = $m.Groups[1].Value -replace "\\\\", "\\"
                $candidate = Join-Path $libraryPath "steamapps\common\Among Us"
                if (Test-Path -LiteralPath (Join-Path $candidate "Among Us.exe")) {
                    [void]$candidates.Add($candidate)
                }
            }
        }
        catch {
            Write-WarnLine "Failed to parse Steam libraries from: $libraryFile"
        }
    }

    $candidates | Select-Object -Unique
}

# Epic detection (manifests + common paths)
function Get-EpicGamePaths {
    $candidates = New-Object System.Collections.Generic.List[string]

    $manifestDir = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path -LiteralPath $manifestDir) {
        Get-ChildItem -LiteralPath $manifestDir -Filter "*.item" -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $json = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                if (($json.DisplayName -like "*Among Us*") -and $json.InstallLocation) {
                    $location = $json.InstallLocation
                    if (Test-Path -LiteralPath (Join-Path $location "Among Us.exe")) {
                        [void]$candidates.Add($location)
                    }
                }
            }
            catch {
            }
        }
    }

    foreach ($path in @(
        "C:\Program Files\Epic Games\AmongUs",
        "C:\Program Files\Epic Games\Among Us"
    )) {
        if (Test-Path -LiteralPath (Join-Path $path "Among Us.exe")) {
            [void]$candidates.Add($path)
        }
    }

    $candidates | Select-Object -Unique
}

# Itch detection (common app paths)
function Get-ItchGamePaths {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($path in @(
        "$env:APPDATA\itch\apps\among-us",
        "$env:APPDATA\itch\apps\Among Us",
        "$env:LOCALAPPDATA\itch\apps\among-us",
        "$env:LOCALAPPDATA\itch\apps\Among Us"
    )) {
        if (Test-Path -LiteralPath (Join-Path $path "Among Us.exe")) {
            [void]$candidates.Add($path)
        }
    }

    $candidates | Select-Object -Unique
}

# Xbox/Microsoft Store detection
function Get-XboxOrMicrosoftStorePaths {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($path in @(
        "C:\XboxGames\Among Us\Content",
        "D:\XboxGames\Among Us\Content",
        "C:\Program Files\WindowsApps"
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        if ($path -eq "C:\Program Files\WindowsApps") {
            # WindowsApps lookup (best-effort)
            Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*AmongUs*" -or $_.Name -like "*Among Us*" } |
                ForEach-Object {
                    $possibleExe = Join-Path $_.FullName "Among Us.exe"
                    if (Test-Path -LiteralPath $possibleExe) {
                        [void]$candidates.Add($_.FullName)
                    }
                }
        }
        else {
            if (Test-Path -LiteralPath (Join-Path $path "Among Us.exe")) {
                [void]$candidates.Add($path)
            }
        }
    }

    $candidates | Select-Object -Unique
}

# Merge detections into unique targets
function Get-DetectedInstallPaths {
    $targetsByPath = @{}

    $runningTarget = Get-RunningGameTarget
    if ($runningTarget) {
        $targetsByPath[$runningTarget.Path.ToLowerInvariant()] = $runningTarget
    }

    foreach ($path in Get-SteamGamePaths) {
        $target = New-InstallTarget -Path $path -Source "Steam" -PackageType "Steam-Itch"
        $targetsByPath[$path.ToLowerInvariant()] = $target
    }

    foreach ($path in Get-EpicGamePaths) {
        $target = New-InstallTarget -Path $path -Source "Epic" -PackageType "MicrosoftStore-EpicGames-XboxApp"
        $targetsByPath[$path.ToLowerInvariant()] = $target
    }

    foreach ($path in Get-ItchGamePaths) {
        $target = New-InstallTarget -Path $path -Source "Itch.io" -PackageType "Steam-Itch"
        $targetsByPath[$path.ToLowerInvariant()] = $target
    }

    foreach ($path in Get-XboxOrMicrosoftStorePaths) {
        $source = if ($path.ToLowerInvariant().Contains("windowsapps")) { "Microsoft Store" } else { "Xbox App" }
        $target = New-InstallTarget -Path $path -Source $source -PackageType "MicrosoftStore-EpicGames-XboxApp"
        $targetsByPath[$path.ToLowerInvariant()] = $target
    }

    return @($targetsByPath.Values)
}

# Fetch latest release and select matching asset
function Get-LatestReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$TargetPackageType
    )

    $apiUrl = "https://api.github.com/repos/$Owner/$Repository/releases/latest"
    Write-Info "Fetching latest release metadata..."

    $headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "MalumMenu-Installer"
    }

    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
    if (-not $release -or -not $release.assets) {
        throw "GitHub latest release metadata did not contain assets."
    }

    $pattern = if ($TargetPackageType -eq "Steam-Itch") {
        "*-Steam-Itch.zip"
    }
    else {
        "*-MicrosoftStore-EpicGames-XboxApp.zip"
    }

    $asset = @($release.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1)
    if (-not $asset -or $asset.Count -eq 0) {
        throw "Could not find release asset matching pattern '$pattern' in latest release."
    }

    return $asset[0]
}

# Download and extract release asset
function Download-And-ExtractPackage {
    param(
        [Parameter(Mandatory = $true)]$Asset,
        [Parameter(Mandatory = $true)][string]$TempRoot
    )

    $zipPath = Join-Path $TempRoot $Asset.name
    $extractDir = Join-Path $TempRoot "extracted"

    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    Write-Info "Downloading $($Asset.name)..."
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $zipPath

    Write-Info "Extracting package..."
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    return $extractDir
}

# Resolve payload root in extracted zip
function Get-PayloadRoot {
    param([Parameter(Mandatory = $true)][string]$ExtractDir)

    $children = @(Get-ChildItem -LiteralPath $ExtractDir -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        return $children[0].FullName
    }

    return $ExtractDir
}

function Confirm-Selection {
    param([string]$Message)

    $inputValue = Read-Host "$Message [y/N]"
    return $inputValue -match '^(y|yes)$'
}

function Copy-ModFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $excluded = @("Install-MalumMenu.ps1", "README.md", "LICENSE", "FEATURES.md")

    $items = Get-ChildItem -LiteralPath $Source -Force
    foreach ($item in $items) {
        if ($excluded -contains $item.Name) {
            continue
        }

        if ($item.Name -like "*.csproj" -or $item.Name -like "*.user" -or $item.Name -like "*.suo") {
            continue
        }

        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

try {
    Write-Info "MalumMenu Windows installer"

    $validPackageTypes = @("Steam-Itch", "MicrosoftStore-EpicGames-XboxApp")
    if ($PSBoundParameters.ContainsKey("PackageType") -and -not [string]::IsNullOrWhiteSpace($PackageType) -and ($PackageType -notin $validPackageTypes)) {
        throw "Invalid PackageType '$PackageType'. Valid values: $($validPackageTypes -join ', ')"
    }

    $selectedPackageType = $PackageType
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MalumMenuInstall-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $selectedSource = "Manual"

    # Step 1: resolve path and package type
    if ($AmongUsPath) {
        $resolvedManual = Resolve-InstallRoot -Path $AmongUsPath
        if (-not $resolvedManual) {
            throw "The provided Among Us path is invalid: $AmongUsPath"
        }

        $selectedPath = $resolvedManual
        if (-not $selectedPackageType) {
            $selectedPackageType = Get-PackageTypeForPath -Path $selectedPath
            if (-not $selectedPackageType) {
                $selectedPackageType = "Steam-Itch"
                Write-WarnLine "Could not infer install type from the provided path. Defaulting to Steam-Itch package."
            }
        }
        Write-Info "Using user-provided path: $selectedPath"
    }
    else {
        Write-Info "Detecting Among Us installation..."
        $detected = @(Get-DetectedInstallPaths)

        if ($detected.Count -eq 0) {
            Write-ErrLine "Could not detect Among Us automatically."
            Write-Host ""
            Write-Host "Please run this script with the game folder path, for example:" -ForegroundColor Yellow
            Write-Host ".\Install-MalumMenu.ps1 -AmongUsPath \"C:\Program Files (x86)\Steam\steamapps\common\Among Us\"" -ForegroundColor Yellow
            exit 1
        }

        if ($detected.Count -eq 1) {
            $selectedPath = $detected[0].Path
            $selectedPackageType = if ($selectedPackageType) { $selectedPackageType } else { $detected[0].PackageType }
            $selectedSource = $detected[0].Source
            Write-Info "Detected Among Us at: $selectedPath ($selectedSource)"
        }
        else {
            Write-Info "Multiple Among Us installations were found:"
            for ($i = 0; $i -lt $detected.Count; $i++) {
                Write-Host ("[{0}] {1} | Source: {2} | Package: {3}" -f ($i + 1), $detected[$i].Path, $detected[$i].Source, $detected[$i].PackageType)
            }

            $choice = Read-Host "Enter the number of the installation to use"
            $parsedChoice = 0
            if (-not [int]::TryParse($choice, [ref]$parsedChoice)) {
                throw "Invalid selection."
            }

            $idx = $parsedChoice - 1
            if ($idx -lt 0 -or $idx -ge $detected.Count) {
                throw "Selection out of range."
            }

            $selectedPath = $detected[$idx].Path
            $selectedPackageType = if ($selectedPackageType) { $selectedPackageType } else { $detected[$idx].PackageType }
            $selectedSource = $detected[$idx].Source
        }
    }

    if (-not $selectedPackageType) {
        $selectedPackageType = "Steam-Itch"
        Write-WarnLine "Could not determine install type. Defaulting to Steam-Itch package."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $selectedPath "Among Us.exe"))) {
        throw "Target path does not contain Among Us.exe: $selectedPath"
    }

    Write-Info "Selected install type: $selectedPackageType"
    Write-Info "Installing files to: $selectedPath"

    # Step 2: confirm before file changes
    if (-not $Force) {
        $proceed = Confirm-Selection -Message "Continue with installation"
        if (-not $proceed) {
            Write-WarnLine "Installation canceled by user."
            exit 0
        }
    }

    # Step 3: download latest package and install
    $asset = Get-LatestReleaseAsset -Owner $RepoOwner -Repository $RepoName -TargetPackageType $selectedPackageType
    $extractDir = Download-And-ExtractPackage -Asset $asset -TempRoot $tempRoot
    $payloadRoot = Get-PayloadRoot -ExtractDir $extractDir

    Copy-ModFiles -Source $payloadRoot -Destination $selectedPath
    Write-Ok "MalumMenu files copied successfully."

    # Optional: launch game after install
    if ($LaunchGame) {
        $exePath = Join-Path $selectedPath "Among Us.exe"
        Write-Info "Launching Among Us..."
        Start-Process -FilePath $exePath | Out-Null
    }

    Write-Host ""
    Write-Ok "Installation finished."
    Write-Host "Start Among Us normally. The first launch can take longer while BepInEx initializes."
}
catch {
    Write-ErrLine $_.Exception.Message
    exit 1
}
finally {
    # Cleanup temporary files
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
