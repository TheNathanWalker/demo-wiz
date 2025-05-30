#!/bin/bash

# Verify CloudFormation stack status
echo "Verifying CloudFormation stack status..."
STACK_NAME="tasky-demo"
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].StackStatus" --output text)

if [ "$STACK_STATUS" != "CREATE_COMPLETE" ] && [ "$STACK_STATUS" != "UPDATE_COMPLETE" ]; then
  echo "ERROR: Stack is not in a valid state: $STACK_STATUS"
  exit 1
fi

echo "Stack status: $STACK_STATUS"

# Get MongoDB private IP from CloudFormation stack
echo "Getting MongoDB private IP from CloudFormation stack..."
MONGO_IP=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='MongoDBPrivateIP'].OutputValue" --output text)
CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='EKSClusterName'].OutputValue" --output text)

# Verify valid outputs
if [ -z "$MONGO_IP" ] || [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: Failed to retrieve required outputs from CloudFormation stack"
  echo "MongoDB IP: $MONGO_IP"
  echo "Cluster Name: $CLUSTER_NAME"
  exit 1
fi

echo "MongoDB IP: $MONGO_IP"
echo "Cluster Name: $CLUSTER_NAME"

# Configure kubectl
echo "Configuring kubectl..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $(aws configure get region)

# Create ConfigMap with MongoDB connection string
echo "Creating ConfigMap with MongoDB connection string, for administrator $ADMIN_USERNAME.."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-config
data:
  connection-string: "mongodb://$ADMIN_USERNAME:$ADMIN_PASSWORD@$MONGO_IP:27017/tasky?authSource=admin"
EOF

# Check if MongoDB is accessible
echo "Checking if MongoDB is accessible..."
kubectl run mongo-test --rm -i --restart=Never --image=mongo:4.4 -- bash -c "timeout 5 mongo $MONGO_IP:27017 --eval 'db.runCommand({ping:1})'" || echo "Warning: MongoDB connectivity test failed. Continuing anyway..."

# Set up AWS Load Balancer Controller
echo "Setting up AWS Load Balancer Controller..."

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create policy (ignore if it already exists)
aws iam create-policy --policy-name ALBIngressControllerIAMPolicy --policy-document file://EKS/alb-policy.json || true

# Set up OIDC provider
eksctl utils associate-iam-oidc-provider --region $(aws configure get region) --cluster $CLUSTER_NAME --approve

# Create service account
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/ALBIngressControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

# Install AWS Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."
if ! command -v helm &> /dev/null; then
  echo "Helm not found. Installing Helm..."
  chmod +x EKS/get_helm.sh
  ./EKS/get_helm.sh
fi

# Add AWS EKS Helm repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Check if controller is already installed
if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
  echo "AWS Load Balancer Controller already installed, upgrading..."
  helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --namespace kube-system
else
  echo "Installing AWS Load Balancer Controller..."
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --namespace kube-system
fi

# Wait for the controller to be ready
echo "Waiting for AWS Load Balancer Controller to be ready..."
kubectl -n kube-system wait --for=condition=available --timeout=90s deployment/aws-load-balancer-controller

# Apply Kubernetes resources
echo "Applying Kubernetes resources..."
#kubectl apply -f EKS/tasky-mongodb.yaml
kubectl apply -f EKS/service.yaml
kubectl apply -f EKS/ingress.yaml

# Check if EKS security group allows traffic from ALB
echo "Checking EKS security group configuration..."
EKS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=*eks-cluster-sg*" --query "SecurityGroups[0].GroupId" --output text)
if [ -n "$EKS_SG_ID" ]; then
  echo "Adding ingress rule to allow traffic from ALB to EKS nodes on port 8080..."
  ALB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=*ALB*" --query "SecurityGroups[0].GroupId" --output text)
  aws ec2 authorize-security-group-ingress --group-id $EKS_SG_ID --protocol tcp --port 8080 --source-group $ALB_SG_ID || echo "Rule may already exist"
fi

# Wait for deployment to be ready with a longer timeout
echo "Waiting for deployment to be ready (this may take a few minutes)..."
kubectl rollout status deployment/tasky-mongodb --timeout=300s || true

# Check pod status
echo "Checking pod status..."
kubectl get pods -l app=tasky-mongodb -o wide

# Check logs from the pod
echo "Checking pod logs..."
POD_NAME=$(kubectl get pods -l app=tasky-mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
  kubectl logs $POD_NAME --tail=20
fi

# Verify ECR registry
echo "Verifying ECR registry..."
EXPECTED_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/tasky"
ACTUAL_REGISTRY=$(kubectl get deployment tasky-mongodb -o jsonpath='{.spec.template.spec.containers[0].image}')

if [ -n "$(echo $ACTUAL_REGISTRY | grep $EXPECTED_REGISTRY)" ]; then
  echo "Correct ECR registry verified: $ACTUAL_REGISTRY"
else
  echo "ERROR: Wrong ECR registry detected: $ACTUAL_REGISTRY"
  echo "Expected registry: $EXPECTED_REGISTRY"
  exit 1
fi

echo "Deployment complete!"
echo "Waiting for ALB to be provisioned (this may take a few minutes)..."

# Wait for up to 5 minutes for the ALB to be provisioned
for i in {1..30}; do
  ALB_DNS=$(kubectl get ingress tasky-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$ALB_DNS" ]; then
    echo "ALB DNS: $ALB_DNS"
    echo "You can access the application at: http://$ALB_DNS"
    break
  fi
  echo "Waiting for ALB to be provisioned... ($i/30)"
  sleep 10
done

if [ -z "$ALB_DNS" ]; then
  echo "ALB was not provisioned within the timeout period."
  echo "You can check the status with: kubectl get ingress tasky-ingress"
fi

echo "Checking ALB target group health..."
ALB_ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn" --output text)
if [ -n "$ALB_ARN" ]; then
  TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn $ALB_ARN --query "TargetGroups[0].TargetGroupArn" --output text)
  aws elbv2 describe-target-health --target-group-arn $TG_ARN
fi