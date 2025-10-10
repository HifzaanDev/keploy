#!/bin/bash

# Keploy Test Automation Script v2
# Improved version with proper timing to ensure 100+ test cases

set -e  # Exit on any error
set -u  # Exit on undefined variables

# Configuration
KEPLOY_BINARY="/mnt/c/Keploy_local/keploy/keploy"
PROJECT_DIR="/mnt/c/Keploy_local/samples-python/flask-secret"
PYTHON_CMD="/mnt/c/Keploy_local/samples-python/flask-secret/venv/bin/python main.py"
API_ENDPOINT="http://localhost:8000/secret1"
KEPLOY_DATA_DIR="${PROJECT_DIR}/keploy"
RECORD_TIMEOUT="60s"  # Increased timeout for more test cases
TARGET_CALLS=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if required files and directories exist
check_prerequisites() {
    log "Checking prerequisites..."
    
    if [[ ! -f "$KEPLOY_BINARY" ]]; then
        error "Keploy binary not found at: $KEPLOY_BINARY"
        exit 1
    fi
    
    if [[ ! -d "$PROJECT_DIR" ]]; then
        error "Project directory not found at: $PROJECT_DIR"
        exit 1
    fi
    
    if [[ ! -f "${PROJECT_DIR}/main.py" ]]; then
        error "main.py not found in project directory: $PROJECT_DIR"
        exit 1
    fi
    
    if [[ ! -f "${PROJECT_DIR}/venv/bin/python" ]]; then
        error "Python virtual environment not found at: ${PROJECT_DIR}/venv/bin/python"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Step 1: Clean up old test data
cleanup_old_data() {
    log "Step 1: Cleaning up old test data..."
    
    if [[ -d "$KEPLOY_DATA_DIR" ]]; then
        log "Removing existing keploy directory: $KEPLOY_DATA_DIR"
        
        # Check for secret.yaml file that would prevent re-sanitization
        local secret_files=$(find "$KEPLOY_DATA_DIR" -name "secret.yaml" 2>/dev/null)
        if [[ -n "$secret_files" ]]; then
            log "Found existing secret.yaml files - removing for fresh sanitization"
        fi
        
        rm -rf "$KEPLOY_DATA_DIR"
        success "Old test data and secret files cleaned up"
    else
        log "No existing keploy directory found, skipping cleanup"
    fi
}

# Wait for Flask app to be ready
wait_for_flask() {
    local max_attempts=30
    local attempt=1
    
    log "Waiting for Flask application to be ready..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s --connect-timeout 2 "$API_ENDPOINT" > /dev/null 2>&1; then
            success "Flask application is ready!"
            return 0
        fi
        
        log "Attempt $attempt/$max_attempts: Flask not ready yet, waiting..."
        sleep 2
        ((attempt++))
    done
    
    error "Flask application failed to start within expected time"
    return 1
}

# Generate test traffic with proper timing
generate_test_traffic() {
    log "Generating $TARGET_CALLS API calls to: $API_ENDPOINT"
    
    local successful_calls=0
    local failed_calls=0
    
    for i in $(seq 1 $TARGET_CALLS); do
        if curl -s --max-time 5 "$API_ENDPOINT" > /dev/null 2>&1; then
            ((successful_calls++))
            if [[ $((successful_calls % 10)) -eq 0 ]]; then
                log "Successfully completed $successful_calls API calls"
            fi
        else
            ((failed_calls++))
            if [[ $failed_calls -le 5 ]]; then  # Only show first 5 failures
                warning "API call $i failed"
            fi
        fi
        
        # Small delay between calls to avoid overwhelming the server
        sleep 0.2
    done
    
    success "Traffic generation completed: $successful_calls successful, $failed_calls failed"
}

# Step 2: Generate test data using keploy record
generate_test_data() {
    log "Step 2: Starting keploy record to generate test data..."
    
    # Change to project directory for recording
    cd "$PROJECT_DIR"
    
    # Start Keploy recording in background
    log "Starting Keploy record command in background..."
    log "Command: sudo timeout $RECORD_TIMEOUT $KEPLOY_BINARY record --metadata \"env=test,app=flask-secret\" -c \"$PYTHON_CMD\""
    
    # Start recording in background
    sudo timeout "$RECORD_TIMEOUT" "$KEPLOY_BINARY" record \
        --metadata "env=test,app=flask-secret" \
        -c "$PYTHON_CMD" &
    
    local keploy_pid=$!
    
    # Wait for Flask to be ready
    sleep 5  # Give Keploy some time to start
    if wait_for_flask; then
        # Generate traffic now that Flask is ready
        generate_test_traffic
        
        # Let Keploy continue recording for a bit more
        log "Allowing Keploy to finish recording..."
        sleep 5
    else
        error "Failed to connect to Flask application"
        kill $keploy_pid 2>/dev/null || true
        exit 1
    fi
    
    # Wait for Keploy to finish or timeout
    wait $keploy_pid
    local exit_code=$?
    
    if [[ $exit_code -eq 124 ]]; then
        success "Keploy recording completed (timed out as expected)"
    elif [[ $exit_code -eq 0 ]]; then
        success "Keploy recording completed successfully"
    else
        error "Keploy recording failed with exit code: $exit_code"
        exit 1
    fi
    
    # Verify that test data was generated
    if [[ -d "$KEPLOY_DATA_DIR" ]]; then
        test_count=$(find "$KEPLOY_DATA_DIR" -name "test-*.yaml" -type f 2>/dev/null | wc -l)
        log "Generated $test_count test files"
        
        if [[ $test_count -eq 0 ]]; then
            error "No test files were generated during recording"
            exit 1
        elif [[ $test_count -lt 50 ]]; then
            warning "Only $test_count test files generated (expected closer to $TARGET_CALLS)"
        else
            success "Generated $test_count test files"
        fi
    else
        error "Keploy data directory was not created during recording"
        exit 1
    fi
}

# Step 3: Workaround the YAML corruption bug
fix_yaml_corruption() {
    log "Step 3: Applying workaround for YAML corruption bug..."
    
    local yaml_config="${KEPLOY_DATA_DIR}/keploy.yml"
    
    if [[ -f "$yaml_config" ]]; then
        log "Found potentially corrupted keploy.yml file: $yaml_config"
        
        # Check if the file contains control characters
        if grep -P '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' "$yaml_config" > /dev/null 2>&1; then
            warning "Detected control characters in keploy.yml - removing corrupted file"
            rm "$yaml_config"
            success "Corrupted keploy.yml file removed"
        else
            log "keploy.yml appears to be valid, keeping file"
        fi
    else
        log "No keploy.yml file found - this is expected"
    fi
    
    # Verify test case files are still intact
    test_count=$(find "$KEPLOY_DATA_DIR" -name "test-*.yaml" -type f 2>/dev/null | wc -l)
    if [[ $test_count -gt 0 ]]; then
        success "Test case files are intact ($test_count files remaining)"
    else
        error "No test case files found after YAML cleanup"
        exit 1
    fi
}

# Step 4: Sanitize the tests
sanitize_tests() {
    log "Step 4: Running keploy sanitize on the test data..."
    
    # Change to project directory for sanitization
    cd "$PROJECT_DIR"
    
    # Run sanitize command and measure time
    log "Command: $KEPLOY_BINARY sanitize"
    local start_time=$(date +%s)
    
    if "$KEPLOY_BINARY" sanitize; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        success "Keploy sanitization completed successfully in ${duration} seconds"
    else
        error "Keploy sanitization failed"
        exit 1
    fi
    
    # Verify secret.yaml was created
    local secret_files=$(find "$KEPLOY_DATA_DIR" -name "secret.yaml" -type f 2>/dev/null)
    if [[ -n "$secret_files" ]]; then
        local secret_count=$(echo "$secret_files" | wc -l)
        success "Sanitization created $secret_count secret.yaml file(s)"
        
        # Count secrets found
        for secret_file in $secret_files; do
            local secrets_found=$(wc -l < "$secret_file" 2>/dev/null || echo "0")
            log "Secret file: $secret_file contains $secrets_found sensitive patterns"
        done
    else
        warning "No secret.yaml files found - this may indicate no secrets were detected"
    fi
}

# Main execution function
main() {
    log "Starting Keploy test automation workflow v2..."
    log "Target: Generate $TARGET_CALLS API calls within $RECORD_TIMEOUT"
    
    # Run all steps in sequence
    check_prerequisites
    cleanup_old_data
    generate_test_data
    fix_yaml_corruption
    sanitize_tests
    
    success "Keploy test automation workflow completed successfully!"
    
    # Summary
    echo
    log "=== WORKFLOW SUMMARY ==="
    if [[ -d "$KEPLOY_DATA_DIR" ]]; then
        test_files=$(find "$KEPLOY_DATA_DIR" -name "test-*.yaml" -type f 2>/dev/null | wc -l)
        secret_files=$(find "$KEPLOY_DATA_DIR" -name "secret.yaml" -type f 2>/dev/null | wc -l)
        
        log "Test files generated: $test_files"
        log "Secret files created: $secret_files"
        log "Keploy data directory: $KEPLOY_DATA_DIR"
        
        # Performance note
        if [[ $test_files -ge 100 ]]; then
            success "Successfully generated $test_files test cases (target: $TARGET_CALLS)"
        elif [[ $test_files -ge 50 ]]; then
            warning "Generated $test_files test cases (target was $TARGET_CALLS)"
            log "This is still sufficient to demonstrate the sanitization performance issue"
        else
            warning "Only generated $test_files test cases (target was $TARGET_CALLS)"
            log "You may want to increase the timeout or check the Flask application"
        fi
    fi
    
    success "All steps completed successfully!"
}

# Script usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -t, --timeout  Set recording timeout (default: 60s)"
    echo "  -c, --calls    Set target number of API calls (default: 100)"
    echo
    echo "This script automates the Keploy test recording and sanitization workflow"
    echo "with proper timing to ensure the target number of test cases are generated."
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -t|--timeout)
            RECORD_TIMEOUT="$2"
            shift 2
            ;;
        -c|--calls)
            TARGET_CALLS="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
