#!/bin/bash

set -e

echo "Starting Business Central Container using BC4Ubuntu approach..."

# Debug: Output environment variables for troubleshooting
echo ""
echo "=== Environment Variables (for troubleshooting) ==="
echo "  SA_PASSWORD: $(if [ -n "$SA_PASSWORD" ]; then echo '***set***'; else echo '(not set)'; fi)"
echo "  SQL_SERVER: ${SQL_SERVER:-(not set)}"
echo "  SQL_SERVER_PORT: ${SQL_SERVER_PORT:-(not set)}"
echo "  BC_AUTOSTART: ${BC_AUTOSTART:-(not set)}"
echo "  BC_ARTIFACT_URL: ${BC_ARTIFACT_URL:-(not set)}"
echo "  BC_VERSION: ${BC_VERSION:-(not set)}"
echo "  BC_COUNTRY: ${BC_COUNTRY:-(not set)}"
echo "  BC_TYPE: ${BC_TYPE:-(not set)}"
echo "  ADMIN_USERNAME: ${ADMIN_USERNAME:-(not set)}"
echo "  ADMIN_PASSWORD: $(if [ -n "$ADMIN_PASSWORD" ]; then echo '***set***'; else echo '(not set)'; fi)"
echo "  DATABASE_NAME: ${DATABASE_NAME:-(not set)}"
echo "  IMPORT_TEST_TOOLKIT: ${IMPORT_TEST_TOOLKIT:-(not set)}"
echo "  VERBOSE_LOGGING: ${VERBOSE_LOGGING:-(not set)}"
echo "  WINEDEBUG: ${WINEDEBUG:-(not set)}"
echo "=================================================="
echo ""

# Source Wine environment (base image has Wine paths already configured)
if [ -f /home/scripts/wine/wine-env.sh ]; then
    source /home/scripts/wine/wine-env.sh
fi

# Set default environment variables if not provided
export SA_PASSWORD=${SA_PASSWORD:-"P@ssw0rd123!"}

# Skip template generation - use the provided CustomSettings.config
echo "Using provided CustomSettings.config (template generation skipped)"

# Make sure all scripts are executable
find /home/scripts -name "*.sh" -exec chmod +x {} \;

# Wine and .NET are already initialized in the base image (build-time)
# No runtime initialization needed - containers start immediately!
echo "✓ Wine and .NET pre-initialized in base image"
test -f "/home/.wine-initialized" && echo "✓ Initialization marker found" || echo "⚠ Warning: initialization marker missing"

# Check and cache BC artifacts
# Priority: 1) Pre-mounted artifacts, 2) Cached in volume, 3) Download fresh
echo "Checking BC artifacts..."
pwsh /home/scripts/bc/cache-artifacts.ps1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to prepare BC artifacts"
    exit 1
fi

# Restore database if needed
export PATH="$PATH:/opt/mssql-tools18/bin"
if command -v sqlcmd >/dev/null 2>&1; then
    echo "Checking database..."
    /home/scripts/bc/restore-database.sh
else
    echo "sqlcmd not found, skipping database restore"
    echo "Database must be restored manually"
fi

# BCPasswordHasher binaries are pre-built and included in the image
# No runtime compilation needed

# Create default admin user on first run
if [ ! -f "/home/.admin-user-created" ] && command -v sqlcmd >/dev/null 2>&1; then
    echo "Creating default admin user..."
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"

    # Wait for SQL Server to be ready
    for i in {1..30}; do
        if sqlcmd -S "${SQL_SERVER:-sql}" -U sa -P "${SA_PASSWORD}" -Q "SELECT 1" -C -N > /dev/null 2>&1; then
            echo "SQL Server is ready"
            break
        fi
        echo "Waiting for SQL Server... ($i/30)"
        sleep 2
    done

    # Create admin user using our SQL script
    if /home/scripts/bc/create-bc-user.sh "${ADMIN_USERNAME}" "${ADMIN_PASSWORD}" SUPER 2>&1; then
        echo "✅ Default admin user created successfully"
        echo "   Username: ${ADMIN_USERNAME}"
        echo "   Password: ***masked***"
        echo "   Permission Set: SUPER"
        touch /home/.admin-user-created
    else
        echo "⚠️  Failed to create admin user (will retry on next start)"
    fi
fi

# Check if BC_AUTOSTART is set to false
if [ "${BC_AUTOSTART}" = "false" ]; then
    echo "BC_AUTOSTART is set to false. Container will stay running without starting BC Server."
    echo "To start BC Server manually, run:"
    echo "  /home/scripts/docker/start-bcserver.sh"
    echo ""
    echo "To create additional BC users, run:"
    echo "  /home/scripts/bc/create-bc-user.sh <username> <password> [permission_set]"
    echo "  Example: /home/scripts/bc/create-bc-user.sh john 'Pass123!' SUPER"
    echo ""
    echo "Container is ready for debugging..."
    # Keep container running
    tail -f /dev/null
else
    # Start the BC server
    echo "Starting BC Server..."
    # Note: The custom Wine build includes locale fixes, eliminating the need for
    # the previous workaround scripts (now archived in legacy/culture-workarounds/)

    # Start BC Server in background to allow post-startup tasks
    /home/scripts/docker/start-bcserver.sh &
    BC_SERVER_PID=$!

    # Wait for BC Server to be fully ready (check for the readiness message in logs)
    echo "Waiting for BC Server to be ready..."
    timeout=600
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if [ -f /var/log/bc-server.log ] && grep -q "Press Enter to stop the console server" /var/log/bc-server.log; then
            echo "✓ BC Server is ready"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ $elapsed -ge $timeout ]; then
        echo "⚠ Timeout waiting for BC Server readiness"
    fi

    # Import test toolkit if requested (after BC Server is ready)
    if [ "$IMPORT_TEST_TOOLKIT" = "true" ] || [ "$IMPORT_TEST_TOOLKIT" = "1" ]; then
        echo ""
        echo "IMPORT_TEST_TOOLKIT is enabled, importing test framework apps..."
        if [ -f "/home/scripts/bc/import-test-toolkit.sh" ]; then
            # Run the import script and capture the exit code
            # Note: The script is designed to handle errors gracefully and not crash
            bash /home/scripts/bc/import-test-toolkit.sh || true
            IMPORT_EXIT_CODE=$?

            if [ $IMPORT_EXIT_CODE -eq 0 ]; then
                echo "✓ Test toolkit import process completed"
            else
                echo "⚠️  Test toolkit import completed with warnings (exit code: $IMPORT_EXIT_CODE)"
                echo "Check the logs above for details. BC Server will continue running."
            fi
        else
            echo "⚠️  import-test-toolkit.sh script not found, skipping test toolkit import"
        fi
    else
        echo ""
        echo "Test toolkit import skipped (IMPORT_TEST_TOOLKIT not enabled)"
    fi

    # Wait for BC Server process to complete
    wait $BC_SERVER_PID
fi