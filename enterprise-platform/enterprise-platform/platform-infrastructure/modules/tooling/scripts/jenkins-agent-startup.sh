#!/bin/bash
set -euxo pipefail

apt-get update
# Java 21, not 17. The agent runs Jenkins' remoting JAR and must be on a Java
# version the controller supports. Jenkins dropped Java 17 in the 2.541.1 LTS
# wave (Dec 2025); an agent on 17 fails to connect with a version error.
apt-get install -y openjdk-21-jdk git curl unzip ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv

update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java

# ---- Docker (this host builds images) ----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# ---- Node.js 20 (for the Node services) ----
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# ---- kubectl + GKE auth plugin ----
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list
apt-get update
apt-get install -y kubectl google-cloud-cli-gke-gcloud-auth-plugin

# ---- Trivy (image vulnerability scanning) ----
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  > /etc/apt/sources.list.d/trivy.list
apt-get update
apt-get install -y trivy

# ---- SonarScanner CLI ----
SONAR_SCANNER_VERSION=5.0.1.3006
cd /opt
curl -sSLo sonar-scanner.zip \
  "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux.zip"
unzip -q sonar-scanner.zip
mv "sonar-scanner-${SONAR_SCANNER_VERSION}-linux" /opt/sonar-scanner
ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm -f sonar-scanner.zip

# ---- jenkins user that the controller SSHes in as ----
useradd -m -s /bin/bash jenkins || true
usermod -aG docker jenkins
mkdir -p /home/jenkins/.ssh
chmod 700 /home/jenkins/.ssh
chown -R jenkins:jenkins /home/jenkins

# envsubst comes from gettext-base - we use it instead of Helm/Kustomize
apt-get install -y gettext-base

systemctl enable docker
systemctl restart docker

echo "jenkins-agent ready" > /var/log/startup-complete.log
