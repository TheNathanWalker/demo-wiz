#!/bin/bash
set -e

# Get instance metadata
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# Get MongoDB credentials from Secrets Manager
SECRET_NAME="mongodb-credentials"
SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --region $REGION --query SecretString --output text)
ADMIN_USERNAME=$(echo $SECRET_VALUE | jq -r .username)
ADMIN_PASSWORD=$(echo $SECRET_VALUE | jq -r .password)

# Get S3 bucket name from instance metadata
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

#Hard coded values for testing purpose
S3_BUCKET="tasky-demo-mongobackupbucket-ys8zfqzitvpi"  # Replace with your actual bucket name
SNS_TOPIC="arn:aws:sns:us-east-1:084828583985:mongodb-backup-notifications"  # Replace with your actual SNS topic ARN

# Need to troubleshoot the below lines. 
# Working from my workstation. 
# I've triple-checked the roles and permissions, but it still fails when run on the instance
#S3_BUCKET=$(aws cloudformation describe-stacks --region $REGION --query "Stacks[?Outputs[?OutputKey=='MongoBackupBucketName']].Outputs[?OutputKey=='MongoBackupBucketName'].OutputValue" --output text)
#SNS_TOPIC=$(aws cloudformation describe-stacks --region $REGION --query "Stacks[?Outputs[?OutputKey=='MongoBackupNotificationTopicArn']].Outputs[?OutputKey=='MongoBackupNotificationTopicArn'].OutputValue" --output text)

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
    # aws sns publish --topic-arn $SNS_TOPIC --message "MongoDB backup successful: s3://$S3_BUCKET/$S3_PATH.tar.gz" --subject "MongoDB Backup Success"
    EXIT_CODE=0
else
    echo "Failed to upload backup to S3"
    # aws sns publish --topic-arn $SNS_TOPIC --message "MongoDB backup failed: Error uploading to S3" --subject "MongoDB Backup Failure"
    EXIT_CODE=1
fi

# Clean up
echo "Cleaning up temporary files..."
rm -rf $BACKUP_DIR/$BACKUP_FILENAME
rm -f $BACKUP_DIR/$BACKUP_FILENAME.tar.gz

# Keep only the last 7 days of backups locally
find $BACKUP_DIR -name "mongodb_backup_*.tar.gz" -type f -mtime +7 -delete

exit $EXIT_CODE