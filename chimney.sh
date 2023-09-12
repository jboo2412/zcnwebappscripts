#!/bin/bash

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires sudo privileges. Please enter your password:"
    exec sudo "$0" "$@"  # This re-executes the script with sudo
fi

# setup variables
export CLUSTER=0chaincluster
export DELEGATE_WALLET=0chainclientId
export READ_PRICE=0chainreadPrice
export WRITE_PRICE=0chainwritePrice
export MIN_STAKE=0chainminStake
export MAX_STAKE=0chainmaxStake
export NO_OF_DELEGATES=0chaindelegates
export SERVICE_CHARGE=0chainserviceCharge
export GF_ADMIN_USER=0chaingfadminuser
export GF_ADMIN_PASSWORD='0chaingfadminpassword'
export PROJECT_ROOT=/var/0chain/blobber
export BLOCK_WORKER_URL=0chainblockworker
export BLOBBER_HOST=0chainblobberhost

export VALIDATOR_WALLET_ID=0chainvalwalletid
export VALIDATOR_WALLET_PUBLIC_KEY=0chainvalwalletpublickey
export VALIDATOR_WALLET_PRIV_KEY=0chainvalwalletprivkey
export BLOBBER_WALLET_ID=0chainblobwalletid
export BLOBBER_WALLET_PUBLIC_KEY=0chainblobwalletpublickey
export BLOBBER_WALLET_PRIV_KEY=0chainblobwalletprivkey

export DEBIAN_FRONTEND=noninteractive

export PROJECT_ROOT_SSD=/var/0chain/blobber/ssd
export PROJECT_ROOT_HDD=/var/0chain/blobber/hdd


sudo apt update

if dpkg --get-selections | grep -q "unattended-upgrades"; then
  echo "unattended-upgrades is installed. removing it"
  sudo apt-get remove -y --purge unattended-upgrades
else
  echo "unattended-upgrades is not installed. Nothing to do."
fi

sudo apt install -y unzip curl containerd docker.io systemd systemd-timesyncd
sudo apt install -y ufw ntp ntpdate

sudo ufw allow 123/udp
sudo ufw allow out to any port 123
sudo systemctl stop ntp
sudo ntpdate pool.ntp.org
sudo systemctl start ntp
sudo systemctl enable ntp

# download docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version

## cleanup server before starting the deployment
if [ -f "${PROJECT_ROOT}/docker-compose.yml" ]; then
  echo "previous deployment exists. Clean it up..."
  docker-compose -f ${PROJECT_ROOT}/docker-compose.yml down --volumes
  rm -rf ${PROJECT_ROOT} || true
fi

#Disk setup
mkdir -p $PWD/disk-setup/
wget https://raw.githubusercontent.com/0chain/zcnwebappscripts/main/disk-setup/disk_setup.sh -O $PWD/disk-setup/disk_setup.sh
wget https://raw.githubusercontent.com/0chain/zcnwebappscripts/main/disk-setup/disk_func.sh -O $PWD/disk-setup/disk_func.sh

sudo chmod +x $PWD/disk-setup/disk_setup.sh
bash $PWD/disk-setup/disk_setup.sh $PROJECT_ROOT_SSD $PROJECT_ROOT_HDD

# generate password for portainer
echo -n ${GF_ADMIN_PASSWORD} >/tmp/portainer_password

#### ---- Start Blobber Setup ----- ####

FOLDERS_TO_CREATE="config sql bin monitoringconfig keys_config"

for i in ${FOLDERS_TO_CREATE}; do
  folder=${PROJECT_ROOT}/${i}
  echo "creating folder: $folder"
  mkdir -p $folder
done

ls -al $PROJECT_ROOT

# download and unzip files
curl -L "https://github.com/0chain/zcnwebappscripts/raw/main/artifacts/blobber-files.zip" -o /tmp/blobber-files.zip
unzip -o /tmp/blobber-files.zip -d ${PROJECT_ROOT}
rm /tmp/blobber-files.zip

curl -L "https://github.com/0chain/zcnwebappscripts/raw/main/artifacts/chimney-dashboard.zip" -o /tmp/chimney-dashboard.zip
unzip /tmp/chimney-dashboard.zip -d ${PROJECT_ROOT}
rm /tmp/chimney-dashboard.zip

# create 0chain_blobber.yaml file
echo "creating 0chain_blobber.yaml"
cat <<EOF >${PROJECT_ROOT}/config/0chain_blobber.yaml
version: "1.0"

logging:
  level: "info"
  console: true # printing log to console is only supported in development mode

# for testing
#  500 MB - 536870912
#    1 GB - 1073741824
#    2 GB - 2147483648
#    3 GB - 3221225472
#  100 GB - 107374182400
capacity: 1073741824 # 1 GB bytes total blobber capacity
read_price: ${READ_PRICE}  # token / GB for reading
write_price: ${WRITE_PRICE}    # token / GB / time_unit for writing
price_in_usd: false
price_worker_in_hours: 12
# the time_unit configured in Storage SC and can be given using
#
#     ./zbox sc-config
#

# min_lock_demand is value in [0; 1] range; it represents number of tokens the
# blobber earned even if a user will not read or write something
# to an allocation; the number of tokens will be calculated by the following
# formula (regarding the time_unit and allocation duration)
#
#     allocation_size * write_price * min_lock_demand
#
min_lock_demand: 0.1

# update_allocations_interval used to refresh known allocation objects from SC
update_allocations_interval: 1m

# maximum limit on the number of combined directories and files on each allocation
max_dirs_files: 50000

# delegate wallet (must be set)
delegate_wallet: ${DELEGATE_WALLET}
# maximum allowed number of stake holders
num_delegates: ${NO_OF_DELEGATES}
# service charge of the blobber
service_charge: ${SERVICE_CHARGE}
# min submit from miners
min_submit: 50
# min confirmation from sharder
min_confirmation: 50

block_worker: ${BLOCK_WORKER_URL}

rate_limiters:
  # Rate limiters will use this duration to clean unused token buckets.
  # If it is 0 then token will expire in 10 years.
  default_token_expire_duration: 5m
  # If blobber is behind some proxy eg. nginx, cloudflare, etc.
  proxy: true

  # Rate limiter is applied with two parameters. One is ip-address and other is clientID.
  # Rate limiter will track both parameters independently and will block request if both
  # ip-address or clientID has reached its limit
  # Blobber may not provide any rps values and default will work fine.

  # Commit Request Per second. Commit endpoint is resource intensive.
  # Default is 0.5
  commit_rps: 1600
  # File Request Per Second. This rps is used to rate limit basically upload and download requests.
  # Its better to have 2 request per second. Default is 1
  file_rps: 1600
  # Object Request Per Second. This rps is used to rate limit GetReferencePath, GetObjectTree, etc.
  # which is resource intensive. Default is 0.5
  object_rps: 1600
  # General Request Per Second. This rps is used to rate limit endpoints like copy, rename, get file metadata,
  # get paginated refs, etc. Default is 5
  general_rps: 1600

server_chain:
  id: "0afc093ffb509f059c55478bc1a60351cef7b4e9c008a53a6cc8241ca8617dfe"
  owner: "edb90b850f2e7e7cbd0a1fa370fdcc5cd378ffbec95363a7bc0e5a98b8ba5759"
  genesis_block:
    id: "ed79cae70d439c11258236da1dfa6fc550f7cc569768304623e8fbd7d70efae4"
  signature_scheme: "bls0chain"

contentref_cleaner:
  frequency: 30
  tolerance: 3600
openconnection_cleaner:
  frequency: 30
  tolerance: 3600 # 60 * 60
writemarker_redeem:
  frequency: 10
  num_workers: 5
readmarker_redeem:
  frequency: 10
  num_workers: 5
challenge_response:
  frequency: 10
  num_workers: 5
  max_retries: 20

healthcheck:
  frequency: 60m # send healthcheck to miners every 60 minutes

pg:
  user: postgres
  password: postgres
db:
  name: blobber_meta
  user: blobber_user
  password: blobber
  host: postgres
  port: 5432

storage:
  files_dir: "/var/0chain/blobber/hdd"
#  sha256 hash will have 64 characters of hex encoded length. So if dir_level is [2,2] this means for an allocation id
#  "4c9bad252272bc6e3969be637610d58f3ab2ff8ca336ea2fadd6171fc68fdd56" directory below will be created.
#  alloc_dir = {files_dir}/4c/9b/ad252272bc6e3969be637610d58f3ab2ff8ca336ea2fadd6171fc68fdd56
#
#  So this means, there will maximum of 16^4 = 65536 numbers directories for all allocations stored by blobber.
#  Similarly for some file_hash "ef935503b66b1ce026610edf18bffd756a79676a8fe317d951965b77a77c0227" with dir_level [2, 2, 1]
#  following path is created for the file:
# {alloc_dir}/ef/93/5/503b66b1ce026610edf18bffd756a79676a8fe317d951965b77a77c0227
  alloc_dir_level: [2, 1]
  file_dir_level: [2, 2, 1]

disk_update:
  # defaults to true. If false, blobber has to manually update blobber's capacity upon increase/decrease
  # If blobber has to limit its capacity to 5% of its capacity then it should turn automaci_update to false.
  automatic_update: true
  blobber_update_interval: 5m # In minutes
# integration tests related configurations
integration_tests:
  # address of the server
  address: host.docker.internal:15210
  # lock_interval used by nodes to request server to connect to blockchain
  # after start
  lock_interval: 1s
admin:
  username: "${GF_ADMIN_USER}"
  password: "${GF_ADMIN_PASSWORD}"
EOF

### Create 0chain_validator.yaml file
echo "creating 0chain_validator.yaml"
cat <<EOF >${PROJECT_ROOT}/config/0chain_validator.yaml
version: 1.0

# delegate wallet (must be set)
delegate_wallet: ${DELEGATE_WALLET}
# maximum allowed number of stake holders
num_delegates: 50
# service charge of related blobber
service_charge: ${SERVICE_CHARGE}

block_worker: ${BLOCK_WORKER_URL}

rate_limiters:
  # Rate limiters will use this duration to clean unused token buckets.
  # If it is 0 then token will expire in 10 years.
  default_token_expire_duration: 5m
  # If blobber is behind some proxy eg. nginx, cloudflare, etc.
  proxy: true

logging:
  level: "error"
  console: true # printing log to console is only supported in development mode

healthcheck:
  frequency: 60m # send healthcheck to miners every 60 mins

server_chain:
  id: "0afc093ffb509f059c55478bc1a60351cef7b4e9c008a53a6cc8241ca8617dfe"
  owner: "edb90b850f2e7e7cbd0a1fa370fdcc5cd378ffbec95363a7bc0e5a98b8ba5759"
  genesis_block:
    id: "ed79cae70d439c11258236da1dfa6fc550f7cc569768304623e8fbd7d70efae4"
  signature_scheme: "bls0chain"
# integration tests related configurations
integration_tests:
  # address of the server
  address: host.docker.internal:15210
  # lock_interval used by nodes to request server to connect to blockchain
  # after start
  lock_interval: 1s
EOF

### Create minio_config.txt file
echo "creating minio_config.txt"
cat <<EOF >${PROJECT_ROOT}/keys_config/minio_config.txt
block_worker: ${BLOCK_WORKER_URL}
EOF

### docker-compose.yaml
echo "creating docker-compose file"
cat <<EOF >${PROJECT_ROOT}/docker-compose.yml
---
version: "3"
services:
  postgres:
    image: postgres:14
    environment:
      POSTGRES_HOST_AUTH_METHOD: trust
    volumes:
      - /var/0chain/blobber/ssd/data/postgresql:/var/lib/postgresql/data
      - /var/0chain/blobber/postgresql.conf:/var/lib/postgresql/postgresql.conf
      - /var/0chain/blobber/sql_init:/docker-entrypoint-initdb.d
    command: postgres -c config_file=/var/lib/postgresql/postgresql.conf
    networks:
      - testnet0
    restart: "always"

  validator:
    image: 0chaindev/validator:staging
    environment:
      - DOCKER= true
    volumes:
      - /var/0chain/blobber/config:/validator/config
      - /var/0chain/blobber/hdd/data:/validator/data
      - /var/0chain/blobber/hdd/log:/validator/log
      - /var/0chain/blobber/keys_config:/validator/keysconfig
    command: ./bin/validator --port 5061 --hostname blobberbeta3.zusfiver.com --deployment_mode 0 --keys_file keysconfig/b0vnode01_keys.txt --log_dir /validator/log --hosturl https://blobberbeta3.zusfiver.com/validator
    networks:
      - testnet0
    restart: "always"

  blobber:
    image: 0chaindev/blobber:staging
    environment:
      DOCKER: "true"
      DB_NAME: blobber_meta
      DB_USER: blobber_user
      DB_PASSWORD: blobber
      DB_PORT: "5432"
      DB_HOST: blobber_validator_1
    depends_on:
      - validator
    links:
      - validator:validator
    volumes:
      - /var/0chain/blobber/config:/blobber/config
      - /var/0chain/blobber/hdd/files:/blobber/files
      - /var/0chain/blobber/hdd/data:/blobber/data
      - /var/0chain/blobber/hdd/log:/blobber/log
      - /var/0chain/blobber/keys_config:/blobber/keysconfig # keys and minio config
      - /var/0chain/blobber/hdd/data/tmp:/tmp
      - /var/0chain/blobber/sql:/blobber/sql
    command: ./bin/blobber --port 5051 --grpc_port 31501 --hostname blobberbeta3.zusfiver.com  --deployment_mode 0 --keys_file keysconfig/b0bnode01_keys.txt --files_dir /blobber/files --log_dir /blobber/log --db_dir /blobber/data --hosturl https://blobberbeta3.zusfiver.com
    networks:
      - testnet0
    restart: "always"

networks:
  testnet0:
    external: true

volumes:
  grafana_data:
  prometheus_data:
  portainer_data:

EOF

cat <<EOF >${PROJECT_ROOT}/keys_config/b0bnode01_keys.txt
${BLOBBER_WALLET_PUBLIC_KEY}
${BLOBBER_WALLET_PRIV_KEY}
EOF

cat <<EOF >${PROJECT_ROOT}/keys_config/b0vnode01_keys.txt
${VALIDATOR_WALLET_PUBLIC_KEY}
${VALIDATOR_WALLET_PRIV_KEY}
EOF

/usr/local/bin/docker-compose -f ${PROJECT_ROOT}/docker-compose.yml pull
/usr/local/bin/docker-compose -f ${PROJECT_ROOT}/docker-compose.yml up -d

while [ ! -d ${PROJECT_ROOT}/caddy_data/caddy/certificates ]; do
  echo "waiting for certificates to be provisioned"
  sleep 2
done

DASHBOARDS=${PROJECT_ROOT}/chimney-dashboard
echo "sleeping for 10secs.."
sleep 10

escapedPassword=$(curl -Gso /dev/null -w %{url_effective} --data-urlencode "password=$GF_ADMIN_PASSWORD" "" | cut -d'=' -f2)

sed -i "s/blobber_host/${BLOBBER_HOST}/g" ${DASHBOARDS}/homepage.json

echo "setting up chimney dashboards..."

curl -X POST -H "Content-Type: application/json" \
      -d "{\"dashboard\":$(cat ${DASHBOARDS}/homepage.json)}" \
      "https://${GF_ADMIN_USER}:${escapedPassword}@${BLOBBER_HOST}/grafana/api/dashboards/import"

curl -X PUT -H "Content-Type: application/json" \
     -d '{ "theme": "", "homeDashboardUID": "homepage", "timezone": "utc" }' \
     "https://${GF_ADMIN_USER}:${escapedPassword}@${BLOBBER_HOST}/grafana/api/org/preferences"

for dashboard in "${DASHBOARDS}/blobber.json" "${DASHBOARDS}/server.json" "${DASHBOARDS}/validator.json"; do
    echo -e "\nUploading dashboard: ${dashboard}"
    curl -X POST -H "Content-Type: application/json" \
          -d "@${dashboard}" \
         "https://${GF_ADMIN_USER}:${escapedPassword}@${BLOBBER_HOST}/grafana/api/dashboards/import"
     echo ""
done
