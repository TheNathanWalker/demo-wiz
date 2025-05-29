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

# Generate random admin username and password
ADMIN_USERNAME="admin$(shuf -i 10000-99999 -n 1)"
ADMIN_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)

# Save credentials to a secure location
echo "MongoDB Admin Username: $ADMIN_USERNAME" > /root/.mongodb_credentials
echo "MongoDB Admin Password: $ADMIN_PASSWORD" >> /root/.mongodb_credentials
chmod 600 /root/.mongodb_credentials

# Create admin user
if command -v mongosh &> /dev/null; then
  mongosh --eval "
    db = db.getSiblingDB('admin');
    db.createUser({
      user: '$ADMIN_USERNAME',
      pwd: '$ADMIN_PASSWORD',
      roles: [ { role: 'root', db: 'admin' } ]
    });
    db = db.getSiblingDB('tasky');
    db.createCollection('users');
  " > /var/log/mongodb-user-creation.log 2>&1

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

# Create a ConfigMap file with the connection string
cat > /tmp/mongodb-connection.txt << EOF
mongodb://$ADMIN_USERNAME:$ADMIN_PASSWORD@$(hostname -I | awk '{print $1}'):27017/tasky?authSource=admin
EOF

# Install AWS CLI
dnf install -y aws-cli

# Create backup directory
mkdir -p /opt/mongodb/backup

# Create backup script
cat > /opt/mongodb/backup/mongodb-backup.sh << 'EOF'
#!/bin/bash
set -e

# MongoDB backup script

# Get credentials from secure file
ADMIN_USERNAME=$(grep "MongoDB Admin Username" /root/.mongodb_credentials | cut -d' ' -f4)
ADMIN_PASSWORD=$(grep "MongoDB Admin Password" /root/.mongodb_credentials | cut -d' ' -f4)

# Get S3 bucket name from instance metadata
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
S3_BUCKET=$(aws cloudformation describe-stacks --region $REGION --query "Stacks[?Outputs[?OutputKey=='MongoBackupBucketName']].Outputs[?OutputKey=='MongoBackupBucketName'].OutputValue" --output text)
SNS_TOPIC=$(aws cloudformation describe-stacks --region $REGION --query "Stacks[?Outputs[?OutputKey=='MongoBackupNotificationTopicArn']].Outputs[?OutputKey=='MongoBackupNotificationTopicArn'].OutputValue" --output text)

# Set backup directory and filename
BACKUP_DIR="/tmp/mongodb_backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="mongodb_backup_$TIMESTAMP"
S3_PATH="backups/$BACKUP_FILENAME"

# Create backup directory if it doesn't exist
mkdir -p $BACKUP_DIR

# Perform MongoDB backup
echo "Starting MongoDB backup..."
mongodump --host localhost --port 27017 --username $ADMIN_USERNAME --password $ADMIN_PASSWORD --authenticationDatabase admin --out $BACKUP_DIR/$BACKUP_FILENAME

# Compress backup
echo "Compressing backup..."
tar -czf $BACKUP_DIR/$BACKUP_FILENAME.tar.gz -C $BACKUP_DIR $BACKUP_FILENAME

# Upload to S3
echo "Uploading to S3..."
if aws s3 cp $BACKUP_DIR/$BACKUP_FILENAME.tar.gz s3://$S3_BUCKET/$S3_PATH.tar.gz; then
    echo "Backup successfully uploaded to S3"
    aws sns publish --topic-arn $SNS_TOPIC --message "MongoDB backup successful: s3://$S3_BUCKET/$S3_PATH.tar.gz" --subject "MongoDB Backup Success"
    EXIT_CODE=0
else
    echo "Failed to upload backup to S3"
    aws sns publish --topic-arn $SNS_TOPIC --message "MongoDB backup failed: Error uploading to S3" --subject "MongoDB Backup Failure"
    EXIT_CODE=1
fi

# Clean up
echo "Cleaning up temporary files..."
rm -rf $BACKUP_DIR/$BACKUP_FILENAME
rm -f $BACKUP_DIR/$BACKUP_FILENAME.tar.gz

# Keep only the last 7 days of backups locally
find $BACKUP_DIR -name "mongodb_backup_*.tar.gz" -type f -mtime +7 -delete

exit $EXIT_CODE
EOF

# Make backup script executable
chmod +x /opt/mongodb/backup/mongodb-backup.sh

# Set up cron job for daily backups at 2 AM
echo "0 2 * * * root /opt/mongodb/backup/mongodb-backup.sh > /var/log/mongodb-backup.log 2>&1" > /etc/cron.d/mongodb-backup
chmod 644 /etc/cron.d/mongodb-backup

# Run initial backup
/opt/mongodb/backup/mongodb-backup.sh > /var/log/mongodb-backup-initial.log 2>&1 || true

echo "MongoDB setup complete" > /var/log/mongodb-setup-complete.log