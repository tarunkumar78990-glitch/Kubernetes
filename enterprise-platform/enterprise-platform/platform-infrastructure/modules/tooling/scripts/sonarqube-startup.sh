#!/bin/bash
set -euxo pipefail

# ---- mount persistent data disk ----
DISK=/dev/disk/by-id/google-sonar-data
if ! blkid "$DISK"; then
  mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$DISK"
fi
mkdir -p /opt/sonar-data
grep -q "google-sonar-data" /etc/fstab || \
  echo "$DISK /opt/sonar-data ext4 discard,defaults,nofail 0 2" >> /etc/fstab
mount -a

# ---- SonarQube's Elasticsearch needs a raised mmap limit ----
sysctl -w vm.max_map_count=524288
sysctl -w fs.file-max=131072
grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=524288" >> /etc/sysctl.conf
grep -q "fs.file-max" /etc/sysctl.conf || echo "fs.file-max=131072" >> /etc/sysctl.conf

apt-get update
apt-get install -y ca-certificates curl gnupg

# ---- Docker (used to run SonarQube + Postgres) ----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

mkdir -p /opt/sonar-data/{postgres,sonarqube_data,sonarqube_logs,sonarqube_extensions}
chown -R 1000:1000 /opt/sonar-data/sonarqube_data /opt/sonar-data/sonarqube_logs /opt/sonar-data/sonarqube_extensions

cat > /opt/docker-compose.yml << 'COMPOSE'
services:
  db:
    image: postgres:15
    container_name: sonar-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: CHANGE_ME_IN_SECRET_MANAGER
      POSTGRES_DB: sonarqube
    volumes:
      - /opt/sonar-data/postgres:/var/lib/postgresql/data

  sonarqube:
    image: sonarqube:10-community
    container_name: sonarqube
    restart: unless-stopped
    depends_on:
      - db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonarqube
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: CHANGE_ME_IN_SECRET_MANAGER
    ports:
      - "9000:9000"
    volumes:
      - /opt/sonar-data/sonarqube_data:/opt/sonarqube/data
      - /opt/sonar-data/sonarqube_logs:/opt/sonarqube/logs
      - /opt/sonar-data/sonarqube_extensions:/opt/sonarqube/extensions
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
COMPOSE

systemctl enable docker
systemctl restart docker
cd /opt && docker compose up -d

echo "sonarqube ready" > /var/log/startup-complete.log
