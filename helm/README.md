# Basic Helm deployment automation
helm upgrade --install tasky ./helm/tasky \
  --set image.repository=$AWS_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/tasky \
  --set mongodb.host=$MONGO_IP \
  --set mongodb.username=$ADMIN_USERNAME \
  --set mongodb.password=$ADMIN_PASSWORD
