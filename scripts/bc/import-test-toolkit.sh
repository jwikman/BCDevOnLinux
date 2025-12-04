#!/bin/bash
# Wrapper script to install BC Test Toolkit apps
# This delegates to the PowerShell script that uses the BC Management module

# Don't exit on errors - we want to report them and continue
set +e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use environment variables for configuration
BC_INSTANCE="${BC_INSTANCE:-BC}"
BC_TENANT="${BC_TENANT:-default}"

echo ""
echo "========================================="
echo "INSTALLING BC TEST TOOLKIT"
echo "========================================="
echo "Using PowerShell Management Module approach..."
echo ""

# Check if PowerShell is available
if ! command -v pwsh &> /dev/null; then
    echo "⚠️  WARNING: PowerShell (pwsh) not found"
    echo "PowerShell is required to use the BC Management module"
    echo "Skipping test toolkit installation. BC Server will continue running."
    exit 0
fi

# Run the PowerShell script
pwsh -File "$SCRIPT_DIR/import-test-toolkit.ps1" \
    -ServerInstance "$BC_INSTANCE" \
    -Tenant "$BC_TENANT"

exit_code=$?

if [ $exit_code -ne 0 ]; then
    echo ""
    echo "⚠️  WARNING: PowerShell script exited with code $exit_code"
    echo "BC Server will continue running."
fi

exit 0