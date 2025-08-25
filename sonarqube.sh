#!/bin/bash
set -euo pipefail

# ====== CHANGE THESE ======
SONAR_VERSION="10.4.1"              # SonarQube CE version
DB_NAME="sonarqube"
DB_USER="sonar"
DB_PASS="ChangeMe_Strong_Pass!"      # <<< set a strong password
DOMAIN="sonar.example.com"           # set if you’ll use a domain; else leave as-is
EXPOSE_9000="no"                     # "yes" to allow direct :9000 access
# ==========================

SONAR_USER="sonarqube"
SONAR_GROUP="${SONAR_USER}"
SONAR_HOME="/opt/sonarqube"
SONAR_DATA="/var/sonarqube"

echo "[*] Updating OS & installing prerequisites"
dnf -y update || true
dnf -y install curl wget unzip tar xz jq rsync \
               java-17-openjdk java-17-openjdk-devel \
               postgresql-server postgresql \
               nginx policycoreutils-python-utils firewalld

# Enable and start firewalld if present
systemctl enable --now firewalld || true
firewall-cmd --permanent --add-service=http || true
[ "${EXPOSE_9000}" = "yes" ] && firewall-cmd --permanent --add-port=9000/tcp || true
firewall-cmd --reload || true

echo "[*] Initializing PostgreSQL"
if ! test -d /var/lib/pgsql/data/base; then
  postgresql-setup --initdb
fi
systemctl enable --now postgresql

PG_HBA_
