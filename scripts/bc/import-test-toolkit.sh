#!/bin/bash
set -e

echo ""
echo "========================================="
echo "IMPORTING BC TEST TOOLKIT"
echo "========================================="

export WINEPREFIX="$HOME/.local/share/wineprefixes/bc1"

# Dynamically detect BC version from artifacts
BC_VERSION=$(/home/scripts/bc/detect-bc-version.sh 2>/dev/null || echo "260")
echo "Detected BC version: $BC_VERSION"

# Find test framework apps in platform artifacts
# BC artifacts directory structure:
# BC26 and earlier: platform/Applications/testframework
# BC27 and later:   platform/Applications/testframework
PLATFORM_BASE="/home/bcartifacts/platform"
TEST_FRAMEWORK_DIR=""

# Try different possible paths
for path in \
    "$PLATFORM_BASE/Applications/testframework" \
    "$PLATFORM_BASE/applications/testframework" \
    "$PLATFORM_BASE/Applications/TestFramework" \
    "$PLATFORM_BASE/PFiles64/Microsoft Dynamics NAV/$BC_VERSION/platform/Applications/testframework" \
    "$PLATFORM_BASE/program files/Microsoft Dynamics NAV/$BC_VERSION/platform/Applications/testframework"; do
    if [ -d "$path" ]; then
        TEST_FRAMEWORK_DIR="$path"
        echo "✓ Found test framework directory: $TEST_FRAMEWORK_DIR"
        break
    fi
done

if [ -z "$TEST_FRAMEWORK_DIR" ]; then
    echo "ERROR: Test framework directory not found in platform artifacts"
    echo "Searched paths:"
    echo "  $PLATFORM_BASE/Applications/testframework"
    echo "  $PLATFORM_BASE/applications/testframework"
    echo "  $PLATFORM_BASE/Applications/TestFramework"
    exit 1
fi

# Count available test framework apps
APP_COUNT=$(find "$TEST_FRAMEWORK_DIR" -name "*.app" -type f 2>/dev/null | wc -l)
if [ "$APP_COUNT" -eq 0 ]; then
    echo "ERROR: No .app files found in $TEST_FRAMEWORK_DIR"
    exit 1
fi

echo "Found $APP_COUNT test framework app(s)"

# BC Server Management Shell commands
# We'll use the New-NavEnvironment cmdlets through PowerShell under Wine
BCSERVER_DIR="$WINEPREFIX/drive_c/Program Files/Microsoft Dynamics NAV/$BC_VERSION/Service"
MANAGEMENT_DLL="$BCSERVER_DIR/Microsoft.Dynamics.Nav.Management.dll"

if [ ! -f "$MANAGEMENT_DLL" ]; then
    echo "ERROR: BC Management DLL not found at $MANAGEMENT_DLL"
    exit 1
fi

echo "Using BC Management DLL: $MANAGEMENT_DLL"

# Create temporary PowerShell script to import test toolkit
TEMP_PS1="/tmp/import-test-toolkit-$$.ps1"
cat > "$TEMP_PS1" << 'PSEOF'
# Import BC Management module
Import-Module 'C:\Program Files\Microsoft Dynamics NAV\{BC_VERSION}\Service\Microsoft.Dynamics.Nav.Management.dll' -ErrorAction Stop

$serverInstance = 'BC'
$testFrameworkDir = '{TEST_FRAMEWORK_DIR}'

Write-Host "Searching for test toolkit apps in: $testFrameworkDir"

# Get all app files from test framework directory
$appFiles = Get-ChildItem -Path $testFrameworkDir -Filter "*.app" -File -Recurse | Sort-Object Name

if ($appFiles.Count -eq 0) {
    Write-Error "No test framework apps found"
    exit 1
}

Write-Host "Found $($appFiles.Count) test framework app(s)"

# Define the installation order based on dependencies
# From navcontainerhelper GetTestToolkitApps function:
# 1. Permissions Mock (v19+)
# 2. Test Runner
# 3. Test Framework: Any, Library Assert, Library Variable Storage
# 4. Test Libraries: System Application Test Library, Business Foundation Test Libraries, Application Test Library, Tests-TestLibraries, AI Test Toolkit
# 5. Tests: System Application Test, Business Foundation Tests, Tests-*
# 6. Performance Toolkit (if included)

$orderedPatterns = @(
    # Permissions Mock
    'Microsoft_Permissions Mock*.app',
    # Test Runner (must come first)
    'Microsoft_Test Runner*.app',
    # Test Framework components
    'Microsoft_Any*.app',
    'Microsoft_Library Assert*.app',
    'Microsoft_Library Variable Storage*.app',
    # Test Libraries
    'Microsoft_System Application Test Library*.app',
    'Microsoft_Business Foundation Test Libraries*.app',
    'Microsoft_Application Test Library*.app',
    'Microsoft_Tests-TestLibraries*.app',
    'Microsoft_AI Test Toolkit*.app',
    # System tests
    'Microsoft_System Application Test*.app',
    'Microsoft_Business Foundation Tests*.app',
    # Other tests (excluding SINGLESERVER and specific marketing tests in older versions)
    'Microsoft_Tests-*.app',
    # Performance Toolkit
    'Microsoft_Performance Toolkit*.app'
)

$installedApps = @()
$skippedApps = @()

foreach ($pattern in $orderedPatterns) {
    $matchingApps = $appFiles | Where-Object { $_.Name -like $pattern }

    foreach ($appFile in $matchingApps) {
        # Skip if already processed
        if ($installedApps -contains $appFile.FullName) {
            continue
        }

        # Skip SINGLESERVER tests
        if ($appFile.Name -like "*SINGLESERVER*.app") {
            Write-Host "Skipping SINGLESERVER test: $($appFile.Name)" -ForegroundColor Yellow
            $skippedApps += $appFile.FullName
            continue
        }

        try {
            Write-Host "Publishing and installing: $($appFile.Name)" -ForegroundColor Cyan

            # Publish the app
            Publish-NavApp -ServerInstance $serverInstance `
                           -Path $appFile.FullName `
                           -SkipVerification `
                           -ErrorAction Stop

            # Get app info to retrieve the exact name, publisher, and version
            $appInfo = Get-NavAppInfo -Path $appFile.FullName

            # Sync the app
            Sync-NavApp -ServerInstance $serverInstance `
                       -Name $appInfo.Name `
                       -Publisher $appInfo.Publisher `
                       -Version $appInfo.Version `
                       -ErrorAction Stop

            # Install the app
            Install-NavApp -ServerInstance $serverInstance `
                          -Name $appInfo.Name `
                          -Publisher $appInfo.Publisher `
                          -Version $appInfo.Version `
                          -ErrorAction Stop

            Write-Host "✓ Successfully installed: $($appInfo.Name)" -ForegroundColor Green
            $installedApps += $appFile.FullName
        }
        catch {
            Write-Host "✗ Failed to install $($appFile.Name): $_" -ForegroundColor Red
            Write-Host "Continuing with next app..." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================="
Write-Host "TEST TOOLKIT IMPORT SUMMARY"
Write-Host "========================================="
Write-Host "Successfully installed: $($installedApps.Count) app(s)" -ForegroundColor Green
Write-Host "Skipped: $($skippedApps.Count) app(s)" -ForegroundColor Yellow
Write-Host ""

if ($installedApps.Count -eq 0) {
    Write-Error "No test toolkit apps were installed successfully"
    exit 1
}

PSEOF

# Replace placeholders in the PowerShell script
sed -i "s|{BC_VERSION}|$BC_VERSION|g" "$TEMP_PS1"
# Convert Linux path to Windows path for PowerShell
WIN_TEST_DIR=$(echo "$TEST_FRAMEWORK_DIR" | sed 's|/home/|Z:\\home\\|g' | sed 's|/|\\|g')
sed -i "s|{TEST_FRAMEWORK_DIR}|$WIN_TEST_DIR|g" "$TEMP_PS1"

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
