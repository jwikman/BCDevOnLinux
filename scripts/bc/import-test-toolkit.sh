#!/bin/bash
set -e

echo ""
echo "========================================="
echo "INSTALLING BC TEST TOOLKIT"
echo "========================================="

export WINEPREFIX="$HOME/.local/share/wineprefixes/bc1"

# Dynamically detect BC version
BC_VERSION=$(/home/scripts/bc/detect-bc-version.sh 2>/dev/null || echo "260")
echo "Detected BC version: $BC_VERSION"

# Create temporary PowerShell script to sync and install test toolkit apps
TEMP_PS1="/tmp/import-test-toolkit-$$.ps1"
cat > "$TEMP_PS1" << 'PSEOF'
# Import BC Management module
Import-Module 'C:\Program Files\Microsoft Dynamics NAV\{BC_VERSION}\Service\Microsoft.Dynamics.Nav.Management.dll' -ErrorAction Stop

$serverInstance = 'BC'
$tenant = 'default'

Write-Host "Getting published test toolkit apps from server..."

# Get all published apps from the server
$publishedApps = Get-NAVAppInfo -ServerInstance $serverInstance | Where-Object {
    $_.Publisher -eq 'Microsoft' -and
    ($_.Name -like '*Test*' -or $_.Name -like '*Performance Toolkit*')
}

if ($publishedApps.Count -eq 0) {
    Write-Error "No published test toolkit apps found"
    exit 1
}

Write-Host "Found $($publishedApps.Count) published test toolkit app(s)"

# Get tenant-specific app info to see what's installed
$tenantApps = Get-NAVAppInfo -ServerInstance $serverInstance -Tenant $tenant -TenantSpecificProperties

# Define the installation order based on dependencies
$orderedPatterns = @(
    'Permissions Mock',
    'Test Runner',
    'Any',
    'Library Assert',
    'Library Variable Storage',
    'System Application Test Library',
    'Business Foundation Test Libraries',
    'Application Test Library',
    'Tests-TestLibraries',
    'AI Test Toolkit',
    # 'System Application Test',
    # 'Business Foundation Tests',
    # 'Tests-',
    'Performance Toolkit'
)

$installedCount = 0
$skippedCount = 0
$alreadyInstalledCount = 0

foreach ($pattern in $orderedPatterns) {
    $matchingApps = $publishedApps | Where-Object { $_.Name -like "*$pattern*" } | Sort-Object Name

    foreach ($app in $matchingApps) {
        # Skip SINGLESERVER tests
        if ($app.Name -like "*SINGLESERVER*") {
            Write-Host "Skipping SINGLESERVER test: $($app.Name)" -ForegroundColor Yellow
            $skippedCount++
            continue
        }

        # Check if already installed
        $tenantApp = $tenantApps | Where-Object {
            $_.AppId -eq $app.AppId -and $_.Version -eq $app.Version
        }

        if ($tenantApp -and $tenantApp.IsInstalled) {
            Write-Host "Already installed: $($app.Name) $($app.Version)" -ForegroundColor Gray
            $alreadyInstalledCount++
            continue
        }

        try {
            Write-Host "Syncing and installing: $($app.Name) $($app.Version)" -ForegroundColor Cyan

            # Sync the app if needed
            if (-not $tenantApp -or $tenantApp.SyncState -ne 'Synced') {
                Sync-NavApp -ServerInstance $serverInstance `
                           -Name $app.Name `
                           -Publisher $app.Publisher `
                           -Version $app.Version `
                           -Tenant $tenant `
                           -ErrorAction Stop
            }

            # Install the app
            Install-NavApp -ServerInstance $serverInstance `
                          -Name $app.Name `
                          -Publisher $app.Publisher `
                          -Version $app.Version `
                          -Tenant $tenant `
                          -ErrorAction Stop

            Write-Host "✓ Successfully installed: $($app.Name)" -ForegroundColor Green
            $installedCount++
        }
        catch {
            Write-Host "✗ Failed to install $($app.Name): $_" -ForegroundColor Red
            Write-Host "Continuing with next app..." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================="
Write-Host "TEST TOOLKIT IMPORT SUMMARY"
Write-Host "========================================="
Write-Host "Newly installed: $installedCount app(s)" -ForegroundColor Green
Write-Host "Already installed: $alreadyInstalledCount app(s)" -ForegroundColor Gray
Write-Host "Skipped: $skippedCount app(s)" -ForegroundColor Yellow
Write-Host ""

if ($installedCount -eq 0 -and $alreadyInstalledCount -eq 0) {
    Write-Error "No test toolkit apps were installed successfully"
    exit 1
}

PSEOF

# Replace placeholders in the PowerShell script
sed -i "s|{BC_VERSION}|$BC_VERSION|g" "$TEMP_PS1"

echo "Executing PowerShell script to import test toolkit apps..."
echo "This may take several minutes depending on the number of apps..."

# Execute the PowerShell script through Wine
if wine powershell -ExecutionPolicy Bypass -File "Z:$(echo $TEMP_PS1 | sed 's|/|\\|g')" 2>&1 | tee /tmp/import-test-toolkit.log; then
    echo ""
    echo "✓ Test toolkit import completed successfully!"
    if [ "$VERBOSE_LOGGING" = "true" ] || [ "$VERBOSE_LOGGING" = "1" ]; then
        echo ""
        echo "========================================="
        echo "FULL IMPORT LOG:"
        echo "========================================="
        cat /tmp/import-test-toolkit.log
        echo "========================================="
    fi
    rm -f "$TEMP_PS1"
    exit 0
else
    echo ""
    echo "✗ Test toolkit import failed"
    echo ""
    echo "========================================="
    echo "FULL IMPORT LOG:"
    echo "========================================="
    cat /tmp/import-test-toolkit.log
    echo "========================================="
    rm -f "$TEMP_PS1"
    exit 1
fi
