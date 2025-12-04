#!/usr/bin/env pwsh
# PowerShell script to install BC Test Toolkit apps using Management Module
# This uses Microsoft.BusinessCentral.Apps.Management.dll

param(
    [string]$BCServicePath = "",
    [string]$ServerInstance = "BC",
    [string]$Tenant = "default"
)

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "INSTALLING BC TEST TOOLKIT VIA MANAGEMENT MODULE" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Function to find BC Service path
function Find-BCServicePath {
    $possiblePaths = @(
        "$env:WINEPREFIX/drive_c/Program Files/Microsoft Dynamics NAV/*/Service",
        "/home/bcartifacts/ServiceTier/program files/Microsoft Dynamics NAV/*/Service",
        "/home/bcartifacts/ServiceTier/PFiles64/Microsoft Dynamics NAV/*/Service"
    )

    foreach ($pathPattern in $possiblePaths) {
        $resolvedPaths = Get-ChildItem -Path $pathPattern -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            Sort-Object -Descending

        if ($resolvedPaths) {
            return $resolvedPaths[0].FullName
        }
    }

    return $null
}

# Find BC Service path if not provided
if ([string]::IsNullOrEmpty($BCServicePath)) {
    Write-Host "Searching for BC Service path..." -ForegroundColor Yellow
    $BCServicePath = Find-BCServicePath

    if ([string]::IsNullOrEmpty($BCServicePath)) {
        Write-Error "ERROR: Could not find BC Service path"
        Write-Host "Please specify the path using -BCServicePath parameter" -ForegroundColor Red
        exit 1
    }
}

Write-Host "BC Service Path: $BCServicePath" -ForegroundColor Green
Write-Host ""

# Find the Management DLL
$managementDllPath = Join-Path $BCServicePath "Microsoft.BusinessCentral.Apps.Management.dll"

if (-not (Test-Path $managementDllPath)) {
    # Try alternate locations
    $alternateLocations = @(
        "Management\Microsoft.BusinessCentral.Apps.Management.dll",
        "Apps\Management\Microsoft.BusinessCentral.Apps.Management.dll",
        "..\Management\Microsoft.BusinessCentral.Apps.Management.dll"
    )

    foreach ($altPath in $alternateLocations) {
        $testPath = Join-Path $BCServicePath $altPath
        if (Test-Path $testPath) {
            $managementDllPath = $testPath
            break
        }
    }
}

if (-not (Test-Path $managementDllPath)) {
    Write-Error "ERROR: Could not find Microsoft.BusinessCentral.Apps.Management.dll"
    Write-Host "Expected location: $managementDllPath" -ForegroundColor Red

    # Search for it
    Write-Host ""
    Write-Host "Searching for Management DLL in BC Service directory..." -ForegroundColor Yellow
    $foundDlls = Get-ChildItem -Path $BCServicePath -Recurse -Filter "*Management*.dll" -ErrorAction SilentlyContinue

    if ($foundDlls) {
        Write-Host "Found Management DLLs:" -ForegroundColor Yellow
        $foundDlls | ForEach-Object { Write-Host "  - $($_.FullName)" }
    } else {
        Write-Host "No Management DLLs found in $BCServicePath" -ForegroundColor Red
    }

    exit 1
}

Write-Host "Found Management DLL: $managementDllPath" -ForegroundColor Green
Write-Host ""

# Import the module
try {
    Write-Host "Importing BC Apps Management module..." -ForegroundColor Yellow
    Import-Module $managementDllPath -Force -ErrorAction Stop
    Write-Host "✓ Module imported successfully" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Error "ERROR: Failed to import Management module: $_"
    exit 1
}

# Get available cmdlets from the module
Write-Host "Available BC Management cmdlets:" -ForegroundColor Cyan
$moduleName = (Get-Module | Where-Object { $_.Path -eq $managementDllPath }).Name
if ($moduleName) {
    Get-Command -Module $moduleName | ForEach-Object { Write-Host "  - $($_.Name)" }
} else {
    Get-Command | Where-Object { $_.Source -like "*BusinessCentral*" -or $_.Source -like "*NAV*" } |
        ForEach-Object { Write-Host "  - $($_.Name)" }
}
Write-Host ""

# Get published test apps
Write-Host "Getting published test toolkit apps..." -ForegroundColor Yellow
try {
    $publishedApps = Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -ErrorAction Stop |
        Where-Object {
            $_.Publisher -eq "Microsoft" -and
            ($_.Name -like "*Test*" -or $_.Name -like "*Performance Toolkit*")
        }

    if (-not $publishedApps) {
        Write-Warning "No test toolkit apps found published on the server"
        Write-Host "Test toolkit apps must be published before they can be installed."
        Write-Host ""
        exit 0
    }

    Write-Host "Found $($publishedApps.Count) published test toolkit apps:" -ForegroundColor Green
    $publishedApps | ForEach-Object {
        Write-Host "  - $($_.Name) ($($_.Version))"
    }
    Write-Host ""

} catch {
    Write-Error "ERROR: Failed to get published apps: $_"
    Write-Host "Make sure BC Server is running and accessible" -ForegroundColor Red
    exit 1
}

# Define installation order based on dependencies
$installationOrder = @(
    "Permissions Mock",
    "Test Runner",
    "Any",
    "Library Assert",
    "Library Variable Storage",
    "System Application Test Library",
    "Business Foundation Test Libraries",
    "Application Test Library",
    "Tests-TestLibraries",
    "AI Test Toolkit",
    "Performance Toolkit"
)

$installedCount = 0
$failedCount = 0
$skippedCount = 0

Write-Host "Installing test toolkit apps in dependency order..." -ForegroundColor Cyan
Write-Host ""

foreach ($pattern in $installationOrder) {
    $matchingApps = $publishedApps | Where-Object { $_.Name -like "*$pattern*" }

    foreach ($app in $matchingApps) {
        # Skip SINGLESERVER tests
        if ($app.Name -like "*SINGLESERVER*") {
            Write-Host "  Skipping: $($app.Name) (SINGLESERVER test)" -ForegroundColor Gray
            $skippedCount++
            continue
        }

        # Check if already installed
        try {
            $installedApp = Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -ErrorAction SilentlyContinue
            if ($installedApp -and $installedApp.IsInstalled) {
                Write-Host "  Already installed: $($app.Name) ($($app.Version))" -ForegroundColor Gray
                $skippedCount++
                continue
            }
        } catch {
            # Ignore errors checking installation status
        }

        Write-Host "  Installing: $($app.Name) $($app.Version)" -ForegroundColor Yellow

        try {
            Install-NAVApp -ServerInstance $ServerInstance -Name $app.Name -Version $app.Version -ErrorAction Stop
            Write-Host "    ✓ Installed successfully" -ForegroundColor Green
            $installedCount++

            # Wait a bit for installation to process
            Start-Sleep -Seconds 2

        } catch {
            Write-Host "    ✗ Failed: $_" -ForegroundColor Red
            $failedCount++
        }
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "TEST TOOLKIT INSTALLATION SUMMARY" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Installed: $installedCount" -ForegroundColor Green
Write-Host "Failed: $failedCount" -ForegroundColor Red
Write-Host "Skipped: $skippedCount" -ForegroundColor Yellow
Write-Host ""

if ($installedCount -eq 0 -and $failedCount -gt 0) {
    Write-Warning "No test toolkit apps were installed successfully"
    Write-Host "Some installations failed. Check the logs above for details."
    exit 0
} elseif ($installedCount -eq 0) {
    Write-Host "No test toolkit apps were installed" -ForegroundColor Yellow
    exit 0
}

Write-Host "✓ Test toolkit installation completed!" -ForegroundColor Green
Write-Host "$installedCount app(s) installed successfully" -ForegroundColor Green
if ($failedCount -gt 0) {
    Write-Warning "$failedCount app(s) failed to install"
}

exit 0
