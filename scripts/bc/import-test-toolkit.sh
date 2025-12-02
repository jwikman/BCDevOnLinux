#!/bin/bash
set -e

echo ""
echo "========================================="
echo "INSTALLING BC TEST TOOLKIT"
echo "========================================="

# BC Server connection details
BC_SERVER="localhost"
BC_PORT="7049"
BC_INSTANCE="BC"
BC_TENANT="default"
# Use environment variables or defaults
BC_USERNAME="${ADMIN_USERNAME:-admin}"
BC_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"
BC_BASE_URL="http://${BC_SERVER}:${BC_PORT}/${BC_INSTANCE}"

echo "Using BC server: $BC_BASE_URL"
echo "Tenant: $BC_TENANT"
echo "Username: $BC_USERNAME"
echo ""

# NOTE: Credentials are passed via curl -u flag. This is acceptable for local
# container environments but would expose credentials in process lists in production.
# For production, consider using .netrc or other secure credential storage.

# Function to get published apps using OData API
# Requires Python 3.6+ for f-string support
get_published_test_apps() {
    local api_url="${BC_BASE_URL}/api/microsoft/automation/v2.0/companies(00000000-0000-0000-0000-000000000000)/extensions?\$filter=publisher eq 'Microsoft' and (contains(displayName,'Test') or contains(displayName,'Performance Toolkit'))"
    
    curl -s -u "${BC_USERNAME}:${BC_PASSWORD}" "$api_url" | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'value' in data:
        for ext in data['value']:
            print(f\"{ext['displayName']}|{ext['versionMajor']}.{ext['versionMinor']}.{ext['versionBuild']}.{ext['versionRevision']}\")
except Exception as e:
    print(f'Error parsing API response: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# Function to install an extension using Automation API
install_extension() {
    local app_name="$1"
    local app_version="$2"
    
    echo "  Installing: $app_name $app_version"
    
    # Use the extensionDeploymentStatus API to install
    local api_url="${BC_BASE_URL}/api/microsoft/automation/v2.0/companies(00000000-0000-0000-0000-000000000000)/extensionDeploymentStatus"
    local payload=$(cat <<EOF
{
    "name": "$app_name",
    "publisher": "Microsoft",
    "version": "$app_version",
    "deploy": true
}
EOF
)
    
    local response=$(curl -s -w "\n%{http_code}" -u "${BC_USERNAME}:${BC_PASSWORD}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$payload" \
        "$api_url" 2>&1)
    
    local http_code=$(echo "$response" | tail -n 1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        echo "    ✓ Installation initiated successfully"
        return 0
    else
        echo "    ✗ Failed (HTTP $http_code)"
        echo "    Response: $body"
        return 1
    fi
}

echo "Discovering published test toolkit apps..."
published_apps=$(get_published_test_apps)
get_apps_exit_code=$?

if [ $get_apps_exit_code -ne 0 ]; then
    echo "ERROR: Failed to get published test toolkit apps from BC server"
    echo "This could be due to:"
    echo "  - BC Server not ready"
    echo "  - Authentication failure (check ADMIN_USERNAME/ADMIN_PASSWORD)"
    echo "  - API not accessible"
    echo "Exit code: $get_apps_exit_code"
    exit 1
fi

if [ -z "$published_apps" ]; then
    echo "ERROR: No test toolkit apps found published on the server"
    echo "Test toolkit apps must be published before they can be installed"
    exit 1
fi

echo "Found published test toolkit apps:"
while IFS='|' read -r name version; do
    echo "  - $name ($version)"
done < <(echo "$published_apps")
echo ""

# Define installation order based on dependencies
installation_order=(
    "Permissions Mock"
    "Test Runner"
    "Any"
    "Library Assert"
    "Library Variable Storage"
    "System Application Test Library"
    "Business Foundation Test Libraries"
    "Application Test Library"
    "Tests-TestLibraries"
    "AI Test Toolkit"
    "Performance Toolkit"
)

installed_count=0
failed_count=0
skipped_count=0

echo "Installing test toolkit apps in dependency order..."
echo ""

for pattern in "${installation_order[@]}"; do
    # Find matching apps
    matching_apps=$(echo "$published_apps" | grep -i "$pattern" || true)
    
    if [ -z "$matching_apps" ]; then
        continue
    fi
    
    while IFS='|' read -r name version; do
        # Skip SINGLESERVER tests
        if echo "$name" | grep -qi "SINGLESERVER"; then
            echo "  Skipping: $name (SINGLESERVER test)"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        if install_extension "$name" "$version"; then
            installed_count=$((installed_count + 1))
            # Wait a bit for installation to process
            sleep 2
        else
            failed_count=$((failed_count + 1))
        fi
    done < <(echo "$matching_apps")
done

echo ""
echo "========================================="
echo "TEST TOOLKIT INSTALLATION SUMMARY"
echo "========================================="
echo "Attempted installations: $installed_count"
echo "Failed: $failed_count"
echo "Skipped: $skipped_count"
echo ""

if [ $installed_count -eq 0 ]; then
    echo "ERROR: No test toolkit apps were installed successfully"
    exit 1
fi

echo "✓ Test toolkit installation completed!"
exit 0
