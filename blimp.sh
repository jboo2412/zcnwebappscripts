#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo "This script requires sudo privileges. Please enter your password:"
  exec sudo "$0" "$@" # This re-executes the script with sudo
fi

CONFIG_DIR=$HOME/.zcn
CONFIG_DIR_BLIMP=${CONFIG_DIR}/blimp # to store wallet.json, config.json, allocation.json
MIGRATION_ROOT=$HOME/.s3migration
MINIO_USERNAME=0chainminiousername
MINIO_PASSWORD=0chainminiopassword
ALLOCATION=0chainallocationid
BLOCK_WORKER_URL=0chainblockworker
MINIO_TOKEN=0chainminiotoken
BLIMP_DOMAIN=blimpdomain
WALLET_ID=0chainwalletid
WALLET_PUBLIC_KEY=0chainwalletpublickey
WALLET_PRIVATE_KEY=0chainwalletprivatekey
DOCKER_IMAGE=v1.11.0

sudo apt update
sudo apt install -y unzip curl containerd docker.io jq net-tools

check_port_443() {
  PORT=443
  command -v netstat >/dev/null 2>&1 || {
    echo >&2 "netstat command not found. Exiting."
    exit 1
  }

  if netstat -tulpn | grep ":$PORT" >/dev/null; then
    echo "Port $PORT is in use."
    echo "Please stop the process running on port $PORT and run the script again"
    exit 1
  else
    echo "Port $PORT is not in use."
  fi
}


echo "download docker-compose"
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version

curl -L https://github.com/0chain/zboxcli/releases/download/v1.4.4/zbox-linux.tar.gz -o /tmp/zbox-linux.tar.gz
sudo tar -xvf /tmp/zbox-linux.tar.gz -C /usr/local/bin

# create config dir
mkdir -p ${CONFIG_DIR}
mkdir -p ${CONFIG_DIR_BLIMP}

cat <<EOF >${CONFIG_DIR_BLIMP}/wallet.json
{
  "client_id": "${WALLET_ID}",
  "client_key": "${WALLET_PUBLIC_KEY}",
  "keys": [
    {
      "public_key": "${WALLET_PUBLIC_KEY}",
      "private_key": "${WALLET_PRIVATE_KEY}"
    }
  ],
  "mnemonics": "0chainmnemonics",
  "version": "1.0"
}
EOF

# create config.yaml
cat <<EOF >${CONFIG_DIR_BLIMP}/config.yaml
block_worker: ${BLOCK_WORKER_URL}
signature_scheme: bls0chain
min_submit: 50
min_confirmation: 50
confirmation_chain_length: 3
max_txn_query: 5
query_sleep_time: 5
EOF

# conform if the wallet belongs to an allocationID
curl -L https://github.com/0chain/zboxcli/releases/download/v1.4.4/zbox-linux.tar.gz -o /tmp/zbox-linux.tar.gz
sudo tar -xvf /tmp/zbox-linux.tar.gz -C /usr/local/bin

_contains() { # Check if space-separated list $1 contains line $2
  echo "$1" | tr ' ' '\n' | grep -F -x -q "$2"
}

allocations=$(/usr/local/bin/zbox listallocations --configDir ${CONFIG_DIR_BLIMP} --silent --json | jq -r ' .[] | .id')

if ! _contains "${allocations}" "${ALLOCATION}"; then
  echo "given allocation does not belong to the wallet"
  exit 1
fi

# todo: verify if updating the allocation ID causes issues to the existing deployment
cat <<EOF >${CONFIG_DIR_BLIMP}/allocation.txt
$ALLOCATION
EOF

# create a seperate folder to store caddy files
mkdir -p ${CONFIG_DIR}/caddyfiles

cat <<EOF >${CONFIG_DIR}/caddyfiles/Caddyfile
{
   acme_ca https://acme.ssl.com/sslcom-dv-ecc
    acme_eab {
        key_id 73c05aaf847a
        mac_key 2RgDeFUTLy898F-4lcDesaWUc91IADS1Lv4_QVknhlY
    }
   email   b.manu199@gmail.com
}
import /etc/caddy/*.caddy
EOF

cat <<EOF >${CONFIG_DIR}/caddyfiles/blimp.caddy
${BLIMP_DOMAIN} {
	route /minioclient/* {
		uri strip_prefix /minioclient
		reverse_proxy minioclient:3001
	}

	route /logsearch/* {
		uri strip_prefix /logsearch
		reverse_proxy api:8080
	}

 	route {
  		reverse_proxy minioserver:9000
  	}
}
EOF

if [[ -f ${CONFIG_DIR}/docker-compose.yml ]]; then
	sudo docker-compose -f ${CONFIG_DIR}/docker-compose.yml down
fi

echo "checking if ports are available..."
check_port_443

# create docker-compose
cat <<EOF >${CONFIG_DIR}/docker-compose.yml
version: '3.8'
services:
  caddy:
    image: caddy:2.6.4
    ports:
      - 80:80
      - 443:443
    volumes:
      - ${CONFIG_DIR}/caddyfiles:/etc/caddy
      - ${CONFIG_DIR}/caddy/site:/srv
      - ${CONFIG_DIR}/caddy/caddy_data:/data
      - ${CONFIG_DIR}/caddy/caddy_config:/config
    restart: "always"

  db:
    image: postgres:13-alpine
    container_name: postgres-db
    restart: always
    command: -c "log_statement=all"
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
    volumes:
      - db:/var/lib/postgresql/data

  api:
    image: 0chaindev/blimp-logsearchapi:${DOCKER_IMAGE}
    depends_on:
      - db
    environment:
      LOGSEARCH_PG_CONN_STR: "postgres://postgres:postgres@postgres-db/postgres?sslmode=disable"
      LOGSEARCH_AUDIT_AUTH_TOKEN: 12345
      MINIO_LOG_QUERY_AUTH_TOKEN: 12345
      LOGSEARCH_DISK_CAPACITY_GB: 5
    links:
      - db

  minioserver:
    image: 0chaindev/blimp-minioserver:${DOCKER_IMAGE}
    container_name: minioserver
    command: ["minio", "gateway", "zcn"]
    environment:
      MINIO_AUDIT_WEBHOOK_ENDPOINT: http://api:8080/api/ingest?token=${MINIO_TOKEN}
      MINIO_AUDIT_WEBHOOK_AUTH_TOKEN: 12345
      MINIO_AUDIT_WEBHOOK_ENABLE: "on"
      MINIO_ROOT_USER: ${MINIO_USERNAME}
      MINIO_ROOT_PASSWORD: ${MINIO_PASSWORD}
      MINIO_BROWSER: "OFF"
    links:
      - api:api
    volumes:
      - ${CONFIG_DIR_BLIMP}:/root/.zcn
    expose:
      - "9000"

  minioclient:
    image: 0chaindev/blimp-clientapi:${DOCKER_IMAGE}
    container_name: minioclient
    depends_on:
      - minioserver
    environment:
      MINIO_SERVER: "minioserver:9000"

  s3mgrt:
    image: 0chaindev/s3mgrt:staging
    restart: always
    volumes:
      - ${MIGRATION_ROOT}:/migrate

volumes:
  db:
    driver: local

EOF


sudo docker-compose -f ${CONFIG_DIR}/docker-compose.yml pull
sudo docker-compose -f ${CONFIG_DIR}/docker-compose.yml up -d

CERTIFICATES_DIR=caddy/caddy_data/caddy/certificates/acme.ssl.com-sslcom-dv-ecc

while [ ! -d ${CONFIG_DIR}/${CERTIFICATES_DIR}/${BLIMP_DOMAIN} ]; do
  echo "waiting for certificates to be provisioned"
  sleep 2
done

echo "S3 Server deployment completed."
