#!/usr/bin/env bash
#
# connect-cluster.sh – connect cluster to run.ai
# Usage:
#   ./connect-cluster.sh <cluster-name> <runai.domain> <runai-version>
#
set -euo pipefail

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# must be run as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script must be run as root." >&2
    exit 1
fi

if [[ $# -lt 3 ]]; then
    echo "ERROR: expected 3 args" >&2
    exit 1
fi

# Set up environment variables
export cluster_name=$1
export control_plane_domain=$2
export cluster_version=$3

# Function to log commands and their output
log_command() {
    local cmd="$1"
    local description="$2"

    echo -e "\n\n==== $description ===="
    echo "Command: $cmd"

    # Execute command and capture both stdout and stderr
    if eval "$cmd"; then
        echo "Status: SUCCESS"
        return 0
    else
        local exit_code=$?
        echo "Status: FAILED (exit code: $exit_code)"
        return $exit_code
    fi
}

# Function to check if authentication service is responding
check_auth_service() {
    local max_attempts=50
    local attempt=1
    local auth_url="https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token"
    
    echo -e "${BLUE}Checking if authentication service is responding...${NC}"
    
    while [ $attempt -le $max_attempts ]; do
        # Try a POST request with minimal data
        if curl --insecure --silent --request POST "$auth_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=runai' \
            --data-urlencode 'username=test@run.ai' \
            --data-urlencode 'password=Abcd!234' \
            --data-urlencode 'scope=openid' \
            --data-urlencode 'response_type=id_token' >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Authentication service is responding${NC}"
            return 0
        fi
        
        echo -ne "⏳ Waiting for authentication service to respond... (Attempt $attempt/$max_attempts)\r"
        sleep 5
        ((attempt++))
    done
    
    echo -e "\n${RED}❌ Authentication service is not responding after $max_attempts attempts${NC}"
    return 1
}

# Function to get authentication token
get_auth_token() {
    local max_attempts=50
    local attempt=1
    local auth_url="https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token"
    
    echo -ne "Waiting for back-end token...\r"
    
    while [ $attempt -le $max_attempts ]; do
        # Store the raw response for debugging
        raw_response=$(curl --insecure --silent --location --request POST "$auth_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=runai' \
            --data-urlencode 'username=test@run.ai' \
            --data-urlencode 'password=Abcd!234' \
            --data-urlencode 'scope=openid' \
            --data-urlencode 'response_type=id_token')

        # Try to parse the token, with error handling
        if [ -n "$raw_response" ]; then
            # Check if the response is valid JSON
            if echo "$raw_response" | jq . >/dev/null 2>&1; then
                token=$(echo "$raw_response" | jq -r '.access_token // empty')
                if [ -n "$token" ] && [ "$token" != "null" ]; then
                    return 0
                fi
            fi
        fi

        sleep 5
        ((attempt++))
    done
    
    return 1
}

# Check if authentication service is responding before trying to get token
if ! check_auth_service; then
    echo -e "${RED}❌ Authentication service is not available. Please check the backend installation.${NC}"
    exit 1
fi

# Get authentication token
if ! get_auth_token; then
    echo -e "${RED}❌ Failed to get authentication token. Please check the backend installation.${NC}"
    exit 1
fi

# Create cluster and get UUID
echo -e "${BLUE}Creating cluster...${NC}"
if ! log_command "curl --insecure --silent -X 'POST' \"https://$control_plane_domain/api/v1/clusters\" -H 'accept: application/json' -H \"Authorization: Bearer $token\" -H 'Content-Type: application/json' -d '{\"name\": \"${cluster_name}\", \"version\": \"${cluster_version}\"}'" "Create cluster"; then
    echo -e "${RED}❌ Failed to create cluster${NC}"
    exit 1
fi

# Get UUID
uuid=$(curl --insecure --silent -X 'GET' \
    "https://$control_plane_domain/api/v1/clusters" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' | jq ".[] | select(.name | contains(\"$cluster_name\"))" | jq -r .uuid)

# Get installation string
echo -e "${BLUE}Getting installation information...${NC}"
while true; do
    installationStr=$(curl --insecure --silent "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json')

    if echo "$installationStr" | grep "helm" > /dev/null; then
        echo -n "$installationStr" | jq -c ".clientSecret | fromjson" > runai-cluster-client-secret.txt
        echo -n "$uuid" > runai-cluster-uuid.txt
        break
    fi
    
    echo -ne "⏳ Waiting for valid installation information...\r"
    sleep 5
done
