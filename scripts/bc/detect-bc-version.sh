#!/bin/bash
# Dynamically detect BC version from artifacts directory structure
# Returns the BC version number (e.g., "260" for BC 26.0)

set -e

BC_ARTIFACTS_PATH="/home/bcartifacts/ServiceTier/program files/Microsoft Dynamics NAV"

# Check if artifacts exist
if [ ! -d "$BC_ARTIFACTS_PATH" ]; then
    echo "ERROR: BC artifacts not found at $BC_ARTIFACTS_PATH" >&2
    exit 1
fi

# Find the version directory (should be a numeric folder like "260", "250", etc.)
BC_VERSION_DIR=$(find "$BC_ARTIFACTS_PATH" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)

if [ -z "$BC_VERSION_DIR" ]; then
    echo "ERROR: No BC version directory found in $BC_ARTIFACTS_PATH" >&2
    exit 1
fi

# Extract just the version number from the path
BC_VERSION=$(basename "$BC_VERSION_DIR")

# Validate that it looks like a version number (should be numeric)
if ! [[ "$BC_VERSION" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid BC version detected: $BC_VERSION" >&2
    exit 1
fi

# Output the version number
echo "$BC_VERSION"
