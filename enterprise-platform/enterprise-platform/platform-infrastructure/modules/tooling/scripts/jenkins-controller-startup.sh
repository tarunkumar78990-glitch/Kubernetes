#!/bin/bash
set -euxo pipefail

# ---- mount the persistent jenkins-home disk ----
DISK=/dev/disk/by-id/google-jenkins-home
if ! blkid "$DISK"; then
  mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$DISK"
fi
mkdir -p /var/lib/jenkins
grep -q "google-jenkins-home" /etc/fstab || \
  echo "$DISK /var/lib/jenkins ext4 discard,defaults,nofail 0 2" >> /etc/fstab
mount -a

# ---- Java 21 (Jenkins requirement) ----
# Jenkins dropped Java 17 support in the 2.541.1 LTS / 2.543 weekly wave
# (Dec 2025). Java 17 now fails at startup with:
#   Running with Java 17 ... which is older than the minimum required
#   version (Java 21). Supported Java versions are: [21, 25]
# Jenkins raises its Java floor every couple of years - expect to bump this.
apt-get update
apt-get install -y openjdk-21-jdk curl gnupg2 ca-certificates

update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java

# Pin JAVA_HOME for the unit so a later JDK install cannot silently
# re-point Jenkins at the wrong JVM.
mkdir -p /etc/systemd/system/jenkins.service.d
printf '[Service]\nEnvironment="JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64"\n' \
  > /etc/systemd/system/jenkins.service.d/java21.conf
systemctl daemon-reload

# ---- Jenkins LTS ----
# NOTE: Jenkins rotated their repo signing keys in Dec 2025 (weekly 2.543 /
# LTS 2.541.1). The old jenkins.io-2023.key no longer signs the repo and
# apt fails with:
#   NO_PUBKEY 7198F4B714ABFC68 ... repository is not signed
# Keys expire every ~3 years, so EXPECT this to break again. If it does,
# check https://www.jenkins.io/blog/ for the current key filename.
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

# Fail loudly and immediately if the key did not land, rather than 10 lines
# later with an opaque GPG error.
if ! gpg --show-keys /usr/share/keyrings/jenkins-keyring.asc >/dev/null 2>&1; then
  echo "FATAL: Jenkins signing key invalid or empty. The key URL has probably" >&2
  echo "changed again. See https://www.jenkins.io/blog/ for the current one." >&2
  exit 1
fi
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update
apt-get install -y jenkins

chown -R jenkins:jenkins /var/lib/jenkins
systemctl enable jenkins
systemctl restart jenkins

# NOTE: no Docker installed here on purpose. The controller must never build.

echo "jenkins-controller ready" > /var/log/startup-complete.log
