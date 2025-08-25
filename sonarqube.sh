#!/bin/bash
set -euo pipefail

# ---------- VARIABLES ----------
SONAR_VERSION="10.4.1"             # change if you want a different CE version
SONAR_USER="sonarqube"
SONAR_GROUP="${SONAR_USER}"
SONAR_HOME="/opt/sonarqube"
SONAR_DATA="/var/sonarqube"        # logs/temp/extensions live here
DB_NAME="sonarqube"
DB_USER="sonar"
DB_PASS="ChangeMe_Strong_Pass!"    # <<< CHANGE THIS
DOMAIN="sonar.example.com"         # <<< set your domain if using Nginx; else leave as-is
EXPOSE_9000="yes"                  # set "no" if you only want Nginx:80 exposed

# ---------- OS PREP ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y unzip curl wget gnupg2 ca-certificates apt-transport-https lsb-release software-properties-common
apt-get install -y openjdk-17-jdk postgresql nginx

# Optional: basic firewall (comment out if you use a security group only)
if command -v ufw >/dev/null 2>&1; then
  ufw allow ssh || true
  [ "${EXPOSE_9000}" = "yes" ] && ufw allow 9000 || true
  ufw allow http || true
  ufw --force enable || true
fi

# ---------- POSTGRESQL ----------
systemctl enable --now postgresql
sudo -u postgres psql <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname='${DB_NAME}') THEN
      CREATE DATABASE ${DB_NAME};
   END IF;
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
      CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
   ELSE
      ALTER USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
   END IF;
   GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
END
\$\$;
SQL

# Ensure local md5 auth (Ubuntu defaults to peer for local). Append a rule if absent.
PG_HBA="/etc/postgresql/$(psql -V | awk '{print $3}' | cut -d. -f1,2)/main/pg_hba.conf"
grep -qE "^local\s+${DB_NAME}\s+${DB_USER}\s+md5" "${PG_HBA}" || \
  echo "local   ${DB_NAME}   ${DB_USER}                                   md5" >> "${PG_HBA}"
systemctl restart postgresql

# ---------- KERNEL/LIMITS TUNING (required by Elasticsearch) ----------
sysctl -w vm.max_map_count=262144
sysctl -w fs.file-max=65536
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-sonarqube.conf
echo "fs.file-max=65536"      >> /etc/sysctl.d/99-sonarqube.conf

cat >/etc/security/limits.d/99-sonarqube.conf <<'LIM'
sonarqube   -   nofile   65536
sonarqube   -   nproc    4096
LIM

# ---------- SONARQUBE USER & DIRECTORIES ----------
id -u "${SONAR_USER}" >/dev/null 2>&1 || useradd -r -s /bin/bash -m -U "${SONAR_USER}"
mkdir -p "${SONAR_HOME}" "${SONAR_DATA}"/{logs,temp,extensions}
chown -R "${SONAR_USER}:${SONAR_GROUP}" "${SONAR_HOME}" "${SONAR_DATA}"

# ---------- DOWNLOAD & INSTALL SONARQUBE ----------
TMPD="$(mktemp -d)"
cd "${TMPD}"
SQ_TGZ="sonarqube-${SONAR_VERSION}.zip"
SQ_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SQ_TGZ}"
echo "Downloading ${SQ_URL}"
curl -fsSLO "${SQ_URL}"
unzip -q "${SQ_TGZ}"
# move to /opt/sonarqube
rsync -a "sonarqube-${SONAR_VERSION}/" "${SONAR_HOME}/"
chown -R "${SONAR_USER}:${SONAR_GROUP}" "${SONAR_HOME}"
rm -rf "${TMPD}"

# ---------- CONFIGURE sonar.properties ----------
SONAR_PROP="${SONAR_HOME}/conf/sonar.properties"
cp "${SONAR_PROP}" "${SONAR_PROP}.bak.$(date +%s)"

# set data dirs + JDBC
sed -i "s|^#\(sonar.path.data=\).*|\1${SONAR_DATA}|g" "${SONAR_PROP}"
sed -i "s|^#\(sonar.path.temp=\).*|\1${SONAR_DATA}/temp|g" "${SONAR_PROP}"

# DB settings
sed -i "s|^#\(sonar.jdbc.username=\).*|\1${DB_USER}|g" "${SONAR_PROP}"
sed -i "s|^#\(sonar.jdbc.password=\).*|\1${DB_PASS}|g" "${SONAR_PROP}"
if grep -q "^#sonar.jdbc.url=jdbc:postgresql" "${SONAR_PROP}"; then
  sed -i "s|^#sonar.jdbc.url=jdbc:postgresql.*|sonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME}|g" "${SONAR_PROP}"
else
  echo "sonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME}" >> "${SONAR_PROP}"
fi

# JVM sizing (tweak for your instance size)
# App (web) JVM:
grep -q "^sonar.web.javaOpts" "${SONAR_PROP}" && \
  sed -i 's|^sonar.web.javaOpts=.*|sonar.web.javaOpts=-Xms512m -Xmx1g -XX:+HeapDumpOnOutOfMemoryError|' "${SONAR_PROP}" || \
  echo "sonar.web.javaOpts=-Xms512m -Xmx1g -XX:+HeapDumpOnOutOfMemoryError" >> "${SONAR_PROP}"
# Search (Elasticsearch) JVM:
grep -q "^sonar.search.javaOpts" "${SONAR_PROP}" && \
  sed -i 's|^sonar.search.javaOpts=.*|sonar.search.javaOpts=-Xms1g -Xmx1g -XX:+HeapDumpOnOutOfMemoryError|' "${SONAR_PROP}" || \
  echo "sonar.search.javaOpts=-Xms1g -Xmx1g -XX:+HeapDumpOnOutOfMemoryError" >> "${SONAR_PROP}"

# ---------- SYSTEMD SERVICE ----------
cat >/etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube service
After=network.target postgresql.service

[Service]
Type=notify
User=${SONAR_USER}
Group=${SONAR_GROUP}
LimitNOFILE=65536
LimitNPROC=4096
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
Environment=SONAR_JAVA_PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin/java
Environment=SONAR_HOME=${SONAR_HOME}
Environment=SONAR_DATA=${SONAR_DATA}
ExecStart=${SONAR_HOME}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONAR_HOME}/bin/linux-x86-64/sonar.sh stop
# Restart on failure
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sonarqube

# ---------- NGINX REVERSE PROXY (optional but recommended) ----------
cat >/etc/nginx/sites-available/sonarqube <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/sonarqube_access.log;
    error_log  /var/log/nginx/sonarqube_error.log;

    location / {
        proxy_pass         http://127.0.0.1:9000;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/sonarqube /etc/nginx/sites-enabled/sonarqube
nginx -t && systemctl restart nginx

# Optionally expose port 9000 (if using without Nginx)
if [ "${EXPOSE_9000}" = "yes" ]; then
  iptables -I INPUT -p tcp --dport 9000 -j ACCEPT || true
fi

echo "===== SonarQube setup complete. ====="
echo "Service status: systemctl status sonarqube"
echo "If using Nginx: http://$DOMAIN"
echo "Direct port (if allowed): http://<instance-ip>:9000"
