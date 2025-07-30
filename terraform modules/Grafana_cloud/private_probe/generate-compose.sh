#!/bin/bash
set -euo pipefail

# Enhanced logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a ~/probe-deployment.log
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# Input validation
if [ $# -ne 4 ]; then
    error_exit "Usage: $0 <count> <proxy_user> <proxy_password> <probes_json>"
fi

COUNT=$1
PROXY_USER=$2
PROXY_PASSWORD=$3
PROBES_JSON=$4

# AWS configuration (passed via environment variables from Terraform)
AWS_REGION=${AWS_REGION:-"eu-central-1"}
SECRET_NAME=${SECRET_NAME:-""}

log "Starting probe deployment with AWS Secrets Manager integration"
log "Count: $COUNT, AWS Region: $AWS_REGION, Secret: $SECRET_NAME"

# Validate inputs
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    error_exit "COUNT must be a positive integer"
fi

# Check required tools
command -v jq >/dev/null 2>&1 || error_exit "jq is required but not installed"
command -v aws >/dev/null 2>&1 || error_exit "AWS CLI is required but not installed"
command -v docker-compose >/dev/null 2>&1 || error_exit "docker-compose is required but not installed"

SERVER_HOSTNAME=$(hostname -f)
log "Running on server: $SERVER_HOSTNAME"

# Validate JSON
if ! echo "$PROBES_JSON" | jq empty 2>/dev/null; then
    error_exit "Invalid JSON in PROBES_JSON parameter"
fi

# Function to retrieve fresh tokens from AWS Secrets Manager
get_fresh_tokens_from_aws() {
    if [ -n "$SECRET_NAME" ]; then
        log "Retrieving fresh tokens from AWS Secrets Manager: $SECRET_NAME"
        
        # Get the latest tokens from AWS Secrets Manager
        FRESH_TOKENS=$(aws secretsmanager get-secret-value \
            --region "$AWS_REGION" \
            --secret-id "$SECRET_NAME" \
            --query 'SecretString' \
            --output text 2>/dev/null || echo "{}")
        
        if [ "$FRESH_TOKENS" != "{}" ]; then
            log "Successfully retrieved fresh tokens from AWS Secrets Manager"
            echo "$FRESH_TOKENS"
        else
            log "No tokens found in AWS Secrets Manager, using provided tokens"
            echo "{}"
        fi
    else
        log "No secret name provided, using tokens from Terraform"
        echo "{}"
    fi
}

# Get fresh tokens from AWS
FRESH_TOKEN_DATA=$(get_fresh_tokens_from_aws)

# Check if this server should run any probes
SHOULD_RUN=false
MATCHING_PROBES=()

for i in $(seq 0 $((COUNT - 1))); do
    PROBE_HOST=$(echo "$PROBES_JSON" | jq -r ".[$i].server_ip // empty")
    if [ -z "$PROBE_HOST" ]; then
        log "WARNING: Missing server_ip for probe $i, skipping"
        continue
    fi
    
    if [[ "$SERVER_HOSTNAME" == "$PROBE_HOST" ]]; then
        SHOULD_RUN=true
        MATCHING_PROBES+=($i)
        log "Found matching probe configuration for index $i"
    fi
done

if [[ "$SHOULD_RUN" == "false" ]]; then
    log "No matching probe configuration found for this host ($SERVER_HOSTNAME), exiting gracefully"
    exit 0
fi

log "Found ${#MATCHING_PROBES[@]} matching probe(s): ${MATCHING_PROBES[*]}"

# Create probe configuration
mkdir -p ~/probe-config || error_exit "Failed to create probe-config directory"

cat <<EOF > ~/probe-config/config.yaml || error_exit "Failed to create config.yaml"
logs:
  level: info
metrics:
  wal_directory: /tmp/wal
  disable_instance_sharing: false
EOF

# Backup existing docker-compose.yml
if [ -f ~/docker-compose.yml ]; then
    cp ~/docker-compose.yml ~/docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S) || log "WARNING: Failed to backup existing docker-compose.yml"
fi

# Generate new docker-compose.yml
log "Generating docker-compose.yml with AWS Secrets Manager integration"
cat <<EOF > ~/docker-compose.yml || error_exit "Failed to create docker-compose.yml"
version: '3.8'
services:
EOF

# Generate service configurations for matching probes
for i in "${MATCHING_PROBES[@]}"; do
    log "Configuring probe service for index $i"
    
    # Extract probe configuration
    PROBE_ID=$(echo "$PROBES_JSON" | jq -r ".[$i].probe_id // empty")
    API_SERVER=$(echo "$PROBES_JSON" | jq -r ".[$i].api_server // \"https://synthetic-monitoring-api.grafana.net\"")
    ENVIRONMENT=$(echo "$PROBES_JSON" | jq -r ".[$i].environment // \"unknown\"")
    
    # Try to get token from AWS first, fallback to provided token
    REGISTRATION_TOKEN=""
    if [ "$FRESH_TOKEN_DATA" != "{}" ]; then
        REGISTRATION_TOKEN=$(echo "$FRESH_TOKEN_DATA" | jq -r ".probe_${i}_token // empty")
        if [ -n "$REGISTRATION_TOKEN" ] && [ "$REGISTRATION_TOKEN" != "empty" ]; then
            log "Using fresh token from AWS Secrets Manager for probe $i"
        fi
    fi
    
    # Fallback to token provided by Terraform
    if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" == "empty" ]; then
        REGISTRATION_TOKEN=$(echo "$PROBES_JSON" | jq -r ".[$i].registration_token // empty")
        log "Using token from Terraform for probe $i"
    fi
    
    # Validate required fields
    if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" == "empty" ]; then
        error_exit "Missing registration_token for probe $i"
    fi
    
    if [ -z "$PROBE_ID" ]; then
        error_exit "Missing probe_id for probe $i"
    fi
    
    SERVICE_NAME="grafana-private-probe-${ENVIRONMENT}-${i}"
    CONTAINER_NAME="kmGroup-${ENVIRONMENT^}-Private-Probe-${i}"
    
    log "Creating service: $SERVICE_NAME with probe ID: $PROBE_ID"
    
    cat <<EOF >> ~/docker-compose.yml
  ${SERVICE_NAME}:
    image: nexus.kmgroup.net/grafana/synthetic-monitoring-agent:v0.38.0
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      # Using token from AWS Secrets Manager or Terraform
      API_TOKEN: ${REGISTRATION_TOKEN}
      API_SERVER: ${API_SERVER}
      http_proxy: http://${PROXY_USER}:${PROXY_PASSWORD}@proxy.muc:8080
      https_proxy: http://${PROXY_USER}:${PROXY_PASSWORD}@proxy.muc:8080
      NO_PROXY: localhost,127.0.0.1
    volumes:
      - ./probe-config:/etc/synthetic-monitoring-agent:ro
    command: >
      --api-server-address=${API_SERVER}
      --api-token=${REGISTRATION_TOKEN}
      --features=adhoc,k6
      --verbose=true
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:4040/metrics"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
    networks:
      - probe-network

EOF
done

# Add network configuration
cat <<EOF >> ~/docker-compose.yml

networks:
  probe-network:
    driver: bridge
EOF

# Deploy with error handling
log "Stopping existing containers"
cd ~ || error_exit "Failed to change to home directory"

if docker-compose ps -q 2>/dev/null | grep -q .; then
    docker-compose down --timeout 30 || log "WARNING: Some containers may not have stopped cleanly"
fi

# Start new containers
log "Starting containers with fresh tokens"
if docker-compose up -d; then
    log "Containers started successfully"
else
    error_exit "Failed to start containers"
fi

# Verify deployment
log "Verifying container health..."
sleep 30

FAILED_CONTAINERS=()
for i in "${MATCHING_PROBES[@]}"; do
    ENVIRONMENT=$(echo "$PROBES_JSON" | jq -r ".[$i].environment // \"unknown\"")
    SERVICE_NAME="grafana-private-probe-${ENVIRONMENT}-${i}"
    
    if ! docker-compose ps "$SERVICE_NAME" | grep -q "Up"; then
        FAILED_CONTAINERS+=("$SERVICE_NAME")
    fi
done

if [ ${#FAILED_CONTAINERS[@]} -gt 0 ]; then
    log "WARNING: The following containers are not running properly: ${FAILED_CONTAINERS[*]}"
    log "Check logs with: docker-compose logs <service_name>"
else
    log "All containers are running successfully"
fi

log "Deployment completed for host $SERVER_HOSTNAME"
log "Active services: $(docker-compose ps --services | wc -l)"
log "Tokens retrieved from: $([ "$FRESH_TOKEN_DATA" != "{}" ] && echo "AWS Secrets Manager" || echo "Terraform")"
