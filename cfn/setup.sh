#!/bin/bash
set -ex

# Create MongoDB repo file
cat > /etc/yum.repos.d/mongodb-org-6.0.repo << EOF
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/6.0/x86_64/
gpgcheck=0
enabled=1
EOF

# Update system
dnf update -y
sleep 10

# Install MongoDB packages
dnf install -y --nogpgcheck mongodb-org

# Verify MongoDB binaries exist
which mongod || echo "mongod binary not found" > /var/log/mongodb-error.log

# Create mongod user and group if they don't exist
getent group mongod || groupadd -r mongod
getent passwd mongod || useradd -r -g mongod -s /sbin/nologin -d /var/lib/mongodb -c "MongoDB Server" mongod

# Create required directories
mkdir -p /var/lib/mongodb /var/log/mongodb /var/run/mongodb
chown -R mongod:mongod /var/lib/mongodb /var/log/mongodb /var/run/mongodb
chmod 0755 /var/run/mongodb

# Create systemd service file for MongoDB
cat > /usr/lib/systemd/system/mongod.service << EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.org/manual
After=network-online.target
Wants=network-online.target

[Service]
User=mongod
Group=mongod
ExecStart=/usr/bin/mongod --config /etc/mongod.conf
PIDFile=/var/run/mongodb/mongod.pid
Type=forking
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitNOFILE=64000
LimitNPROC=64000
LimitMEMLOCK=infinity
TasksMax=infinity
TasksAccounting=false

[Install]
WantedBy=multi-user.target
EOF

# Create MongoDB configuration file
cat > /etc/mongod.conf << EOF
# mongod.conf
net:
  port: 27017
  bindIp: 0.0.0.0
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
processManagement:
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid
EOF

# Reload systemd and start MongoDB
systemctl daemon-reload
systemctl enable mongod
systemctl start mongod || echo "Failed to start MongoDB" > /var/log/mongodb-start-error.log

# Check if MongoDB is running
systemctl status mongod > /var/log/mongodb-status.log 2>&1

# Wait for MongoDB to start
sleep 15

# Create admin user
if command -v mongosh &> /dev/null; then
  mongosh --eval '
    db = db.getSiblingDB("admin");
    db.createUser({
      user: "adminUser",
      pwd: "securePassword",
      roles: [ { role: "root", db: "admin" } ]
    });
    db = db.getSiblingDB("tasky");
    db.createCollection("users");
  ' > /var/log/mongodb-user-creation.log 2>&1

  # Update config to enable authentication
  cat > /etc/mongod.conf << EOF
  # mongod.conf
  net:
    port: 27017
    bindIp: 0.0.0.0
  storage:
    dbPath: /var/lib/mongodb
  systemLog:
    destination: file
    path: /var/log/mongodb/mongod.log
    logAppend: true
  processManagement:
    fork: true
    pidFilePath: /var/run/mongodb/mongod.pid
  security:
    authorization: enabled
  EOF

  # Restart MongoDB
  systemctl restart mongod
else
  echo "mongosh not found, skipping user creation" > /var/log/mongodb-setup-error.log
fi

echo "MongoDB setup complete" > /var/log/mongodb-setup-complete.log
