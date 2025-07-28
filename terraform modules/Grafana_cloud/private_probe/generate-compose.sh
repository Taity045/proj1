#!/bin/bash

# Inputs passed from Terraform:
# $1 = Number of probes
# $2 = Proxy user
# $3 = Proxy password
# $4 = JSON-encoded probe list

COUNT=$1
PROXY_USER=$2
PROXY_PASSWORD=$3
PROBES_JSON=$4

# Ensure jq is available
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Please install jq on the target server."
  exit 1
fi

SERVER_HOSTNAME=$(hostname -f)
echo "Running on: $SERVER_HOSTNAME"

# Debug: Check the PROBES_JSON variable
echo "PROBES_JSON: $PROBES_JSON"

SHOULD_RUN=false
for i in $(seq 0 $((COUNT - 1))); do
  PROBE_HOST=$(echo "$PROBES_JSON" | jq -r ".[$i].server_ip")
  if [[ "$SERVER_HOSTNAME" == "$PROBE_HOST" ]]; then
    SHOULD_RUN=true
    break
  fi
done

if [[ "$SHOULD_RUN" == "false" ]]; then
  echo "No matching probe config found for this host ($SERVER_HOSTNAME), exiting."
  exit 0
fi

mkdir -p ~/probe-config
cat <<EOF > ~/probe-config/config.yaml
logs:
  level: debug
metrics:
  wal_directory: /tmp/wal
EOF

cp ~/docker-compose.yml ~/docker-compose.yml.bak 2>/dev/null || true
> ~/docker-compose.yml

echo "version: '3.8'" >> ~/docker-compose.yml
echo "services:" >> ~/docker-compose.yml

for i in $(seq 0 $((COUNT - 1))); do
  PROBE_HOST=$(echo "$PROBES_JSON" | jq -r ".[$i].server_ip")
  if [[ "$SERVER_HOSTNAME" != "$PROBE_HOST" ]]; then
    continue
  fi

  API_TOKEN=$(echo "$PROBES_JSON" | jq -r ".[$i].api_token")
  if [[ -z "$API_TOKEN" ]]; then
    echo "Error: API token is missing for probe $i."
    exit 1
  fi

  API_SERVER=$(echo "$PROBES_JSON" | jq -r ".[$i].api_server")
  ENVIRONMENT=$(echo "$PROBES_JSON" | jq -r ".[$i].environment")

  SERVICE_NAME="grafana-private-probe-${ENVIRONMENT}-${i}"
  CONTAINER_NAME="kmGroup-${ENVIRONMENT^}-Private-Probe-${i}"

  cat <<EOF >> ~/docker-compose.yml
  ${SERVICE_NAME}:
    image: nexus.kmgroup.net/grafana/synthetic-monitoring-agent:v0.38.0
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      API_TOKEN: ${API_TOKEN}
      API_SERVER: ${API_SERVER}
      http_proxy: http://${PROXY_USER}:${PROXY_PASSWORD}@proxy.muc:8080
      https_proxy: http://${PROXY_USER}:${PROXY_PASSWORD}@proxy.muc:8080
      NO_PROXY: localhost,127.0.0.1
    volumes:
      - ./probe-config:/etc/synthetic-monitoring-agent:ro
    command: >
      --api-server-address=${API_SERVER}
      --api-token=${API_TOKEN}
      --features=adhoc,k6
      --verbose=true
      --debug=true
    logging:
      driver: "json-file"
      options:
        max-size: "500m"
        max-file: "3"
EOF

done

cd ~
docker-compose down || true
docker-compose up -d

echo "Deployment complete for host $SERVER_HOSTNAME."
