#!/bin/bash
# Don't exit on errors - we want to report them and continue
set +e

echo ""
echo "========================================="
echo "INSTALLING BC TEST TOOLKIT"
echo "========================================="

# BC Server instance details
BC_SERVER_INSTANCE="BC"
BC_TENANT="default"
BC_USERNAME="${ADMIN_USERNAME:-admin}"
BC_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"

echo "Server Instance: $BC_SERVER_INSTANCE"
echo "Tenant: $BC_TENANT"
echo "Username: $BC_USERNAME"
echo ""

# Wait for BC Web Services to be fully ready
# The server might report "ready" but web services take additional time to initialize
echo "Waiting for BC Web Services to be ready..."
MAX_WAIT=60
WAIT_COUNT=0
WS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Try to connect to the API
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -u "${BC_USERNAME}:${BC_PASSWORD}" "http://localhost:7048/BC/api/v2.0/companies" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
        WS_READY=true
        echo "✓ BC Web Services are responding (HTTP $HTTP_CODE)"
        break
    fi
    
    echo "  Waiting... ($WAIT_COUNT/$MAX_WAIT) - HTTP: $HTTP_CODE"
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ "$WS_READY" = false ]; then
    echo "⚠️  WARNING: BC Web Services did not become ready within ${MAX_WAIT} attempts"
    echo "The API may not be accessible yet. This can happen when:"
    echo "  - Web services are still initializing"
    echo "  - There's a configuration issue"
    echo ""
    echo "Skipping test toolkit installation. BC Server will continue running."
    echo "You may need to install test toolkit apps manually later."
    exit 0
fi

echo ""

# Get company name (needed for query parameters) - retry until successful
echo "Getting company information..."
COMPANY_NAME=""
COMPANY_RETRY=0
MAX_COMPANY_RETRIES=60

while [ $COMPANY_RETRY -lt $MAX_COMPANY_RETRIES ] && [ -z "$COMPANY_NAME" ]; do
    COMPANY_RESPONSE=$(curl -s -m 10 -u "${BC_USERNAME}:${BC_PASSWORD}" "http://localhost:7048/BC/api/v2.0/companies" 2>&1)

    COMPANY_NAME=$(echo "$COMPANY_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'value' in data and len(data['value']) > 0:
        print(data['value'][0]['name'])
    else:
        sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null)

    if [ -z "$COMPANY_NAME" ]; then
        echo "  Retry $COMPANY_RETRY/$MAX_COMPANY_RETRIES - waiting for company data..."
        sleep 3
        COMPANY_RETRY=$((COMPANY_RETRY + 1))
    fi
done

if [ -z "$COMPANY_NAME" ]; then
    echo "⚠️  WARNING: Could not get company name from BC API after $MAX_COMPANY_RETRIES attempts"
    echo "Last API Response (first 500 chars):"
    echo "$COMPANY_RESPONSE" | head -c 500
    echo ""
    echo ""
    echo "The BC server may need more time to fully initialize."
    echo "Skipping test toolkit installation. BC Server will continue running."
    exit 0
fi

echo "✓ Found company: $COMPANY_NAME"
# URL-encode the company name for use in query parameters
COMPANY_NAME_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$COMPANY_NAME'))")
echo ""

# Define test toolkit apps in dependency order
declare -a TEST_APPS=(
    "/home/bcartifacts/applications/testframework/testlibraries/permissions mock/Microsoft_Permissions Mock.app"
    "/home/bcartifacts/applications/testframework/TestRunner/Microsoft_Test Runner.app"
    "/home/bcartifacts/applications/testframework/testlibraries/any/Microsoft_Any.app"
    "/home/bcartifacts/applications/testframework/testlibraries/assert/Microsoft_Library Assert.app"
    "/home/bcartifacts/applications/testframework/testlibraries/variable storage/Microsoft_Library Variable Storage.app"
    "/home/bcartifacts/applications/BaseApp/Test/Microsoft_System Application Test Library.app"
    "/home/bcartifacts/applications/BusinessFoundation/Test/Microsoft_Business Foundation Test Libraries.app"
    "/home/bcartifacts/applications/Application/Test/Microsoft_Tests-TestLibraries.app"
    "/home/bcartifacts/applications/testframework/aitesttoolkit/Microsoft_AI Test Toolkit.app"
    "/home/bcartifacts/applications/testframework/performancetoolkit/Microsoft_Performance Toolkit.app"
)

# Function to publish app using Automation API
publish_app() {
    local app_file="$1"
    local app_name=$(basename "$app_file" .app)
    
    echo "Publishing: $app_name"
    
    if [ ! -f "$app_file" ]; then
        echo "  ⚠️  App file not found"
        return 1
    fi
    
    # Step 1: Create extensionUpload entity
    local create_response=$(curl -s -m 30 -w "\n%{http_code}" -u "${BC_USERNAME}:${BC_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"schedule":"Current Version"}' \
        "http://localhost:7048/BC/api/microsoft/automation/v2.0/extensionUpload?company=${COMPANY_NAME_ENCODED}" 2>&1)
    
    local create_http_code=$(echo "$create_response" | tail -n 1)
    local create_body=$(echo "$create_response" | sed '$d')
    
    if [ "$create_http_code" != "201" ]; then
        echo "  ✗ Failed to create upload entity (HTTP $create_http_code)"
        if [ -n "$create_body" ]; then
            echo "  Response: $create_body" | head -c 200
            echo ""
        fi
        return 1
    fi
    
    # Extract systemId and mediaEditLink from response
    local system_id=$(echo "$create_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('systemId', ''))
except:
    sys.exit(1)
" 2>/dev/null)
    
    if [ -z "$system_id" ]; then
        echo "  ✗ Failed to extract systemId from response"
        return 1
    fi
    
    # Step 2: Upload the binary content
    local upload_url="http://localhost:7048/BC/api/microsoft/automation/v2.0/extensionUpload(${system_id})/extensionContent?company=${COMPANY_NAME_ENCODED}"
    
    local upload_response=$(curl -s -m 120 -w "\n%{http_code}" -u "${BC_USERNAME}:${BC_PASSWORD}" \
        -X PUT \
        -H "Content-Type: application/octet-stream" \
        -H "If-Match: *" \
        --data-binary "@${app_file}" \
        "${upload_url}" 2>&1)
    
    local upload_http_code=$(echo "$upload_response" | tail -n 1)
    local upload_body=$(echo "$upload_response" | sed '$d')
    
    if [ "$upload_http_code" = "204" ] || [ "$upload_http_code" = "200" ]; then
        echo "  ✓ Published successfully"
        return 0
    else
        echo "  ✗ Upload failed (HTTP $upload_http_code)"
        if [ -n "$upload_body" ]; then
            echo "  Response: $upload_body" | head -c 200
            echo ""
        fi
        return 1
    fi
}

# Publish apps
published_count=0
failed_count=0
skipped_count=0

echo "Publishing test toolkit apps..."
echo ""

for app_file in "${TEST_APPS[@]}"; do
    if publish_app "$app_file"; then
        published_count=$((published_count + 1))
        # Wait between apps to let BC process them
        sleep 3
    else
        if [ -f "$app_file" ]; then
            failed_count=$((failed_count + 1))
        else
            skipped_count=$((skipped_count + 1))
        fi
    fi
    echo ""
done

echo "========================================="
echo "TEST TOOLKIT INSTALLATION SUMMARY"
echo "========================================="
echo "Published: $published_count"
echo "Failed: $failed_count"
echo "Skipped (not found): $skipped_count"
echo ""

if [ $published_count -eq 0 ] && [ $failed_count -gt 0 ]; then
    echo "⚠️  WARNING: No test toolkit apps were published successfully"
    echo "Some publications failed. Check the logs above for details."
    echo "BC Server will continue running."
    exit 0
elif [ $published_count -eq 0 ]; then
    echo "⚠️  INFO: No test toolkit apps were published"
    echo "BC Server will continue running."
    exit 0
fi

echo "✓ Test toolkit publication completed!"
echo "$published_count app(s) published successfully"
if [ $failed_count -gt 0 ]; then
    echo "⚠️  $failed_count app(s) failed to publish"
fi
if [ $skipped_count -gt 0 ]; then
    echo "ℹ️  $skipped_count app(s) skipped (files not found)"
fi

echo ""
echo "Note: Apps are published and automatically installed on the tenant."
exit 0
