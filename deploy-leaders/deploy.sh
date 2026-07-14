#!/bin/bash
set -euo pipefail

# Zips appspec.yml + scripts/, uploads to the artifact bucket created by
# aws-code-deploy-leaders, and triggers a CodeDeploy deployment. Terraform
# state outputs are used so this stays correct if the bucket/app/group
# names ever change - no names are hardcoded here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../aws-code-deploy-leaders"
REGION="us-east-2"

BUCKET="$(terraform -chdir="$TF_DIR" output -raw artifact_bucket_name)"
APPLICATION="$(terraform -chdir="$TF_DIR" output -raw codedeploy_application_name)"
DEPLOYMENT_GROUP="$(terraform -chdir="$TF_DIR" output -raw codedeploy_deployment_group_name)"

TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
BUNDLE_KEY="cribl-deploy-$TIMESTAMP.zip"
BUNDLE_PATH="$(mktemp -d)/$BUNDLE_KEY"

cd "$SCRIPT_DIR"
zip -r "$BUNDLE_PATH" appspec.yml scripts/

aws s3 cp "$BUNDLE_PATH" "s3://$BUCKET/$BUNDLE_KEY" --region "$REGION"

DEPLOYMENT_ID="$(aws deploy create-deployment \
  --application-name "$APPLICATION" \
  --deployment-group-name "$DEPLOYMENT_GROUP" \
  --region "$REGION" \
  --s3-location bucket="$BUCKET",key="$BUNDLE_KEY",bundleType=zip \
  --description "Deploy latest Cribl Stream release" \
  --query 'deploymentId' --output text)"

echo "Started deployment: $DEPLOYMENT_ID"
echo "Track with: aws deploy get-deployment --deployment-id $DEPLOYMENT_ID --region $REGION"
