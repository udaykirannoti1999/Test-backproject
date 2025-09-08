#!/bin/bash
set -e

AWS_REGION="ap-south-2"   
BACKUP_VAULT="rds-dr-vault"
DB_INSTANCE_IDENTIFIER="back-upstore"
DB_PORT="3306"
DB_SUBNET_GROUP="default-vpc-051642d98eff4a857"
SECURITY_GROUP_IDS="sg-0dbe4ffceac1371e2"
ECS_CLUSTER="daister-services-cluster"
ECS_SERVICE="back-updashboard"
IAM_ROLE_ARN="arn:aws:iam::585008046531:role/service-role/AWSBackupDefaultServiceRole"
SECRET_NAME="back-service"

# Function: Get latest recovery point
get_latest_recovery_point() {
  echo "Fetching latest recovery point..."
  LATEST_RECOVERY_POINT=$(aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name "$BACKUP_VAULT" \
    --region "$AWS_REGION" \
    --query "RecoveryPoints | sort_by(@, &CreationDate)[-1].RecoveryPointArn" \
    --output text)
  
  if [[ -z "$LATEST_RECOVERY_POINT" || "$LATEST_RECOVERY_POINT" == "None" ]]; then
    echo "❌ No recovery points found in vault: $BACKUP_VAULT"
    exit 1
  fi
  echo "✅ Latest Recovery Point: $LATEST_RECOVERY_POINT"
}

# Function: Check DB identifier availability
check_db_identifier() {
  echo "Checking if DB identifier already exists..."
  EXISTS=$(aws rds describe-db-instances \
    --region "$AWS_REGION" \
    --query "DBInstances[?DBInstanceIdentifier=='$DB_INSTANCE_IDENTIFIER'].DBInstanceIdentifier" \
    --output text || true)

  if [[ "$EXISTS" == "$DB_INSTANCE_IDENTIFIER" ]]; then
    echo "⚠️ DB identifier already exists, appending timestamp."
    DB_INSTANCE_IDENTIFIER="${DB_INSTANCE_IDENTIFIER}-$(date +%Y%m%d%H%M)"
  fi
  echo "✅ Using DB identifier: $DB_INSTANCE_IDENTIFIER"
}

# Function: Validate subnet group
check_subnet_group() {
  echo "Validating DB subnet group..."
  EXISTS=$(aws rds describe-db-subnet-groups \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --region "$AWS_REGION" \
    --query "DBSubnetGroups[0].DBSubnetGroupName" \
    --output text 2>/dev/null || true)

  if [[ "$EXISTS" != "$DB_SUBNET_GROUP" ]]; then
    echo "❌ Subnet group '$DB_SUBNET_GROUP' not found in region $AWS_REGION"
    exit 1
  fi
  echo "✅ Subnet group '$DB_SUBNET_GROUP' exists."
}

# Function: Start restore job
start_restore_job() {
  echo "Starting restore job..."
  
  RESTORE_JOB_ID=$(aws backup start-restore-job \
    --recovery-point-arn "$LATEST_RECOVERY_POINT" \
    --metadata "{
      \"DBInstanceIdentifier\":\"$DB_INSTANCE_IDENTIFIER\",
      \"DBInstanceClass\":\"db.t4g.micro\",
      \"DBSubnetGroupName\":\"$DB_SUBNET_GROUP\",
      \"VpcSecurityGroupIds\":\"$SECURITY_GROUP_IDS\",
      \"Port\":\"$DB_PORT\"
    }" \
    --iam-role-arn "$IAM_ROLE_ARN" \
    --resource-type RDS \
    --region "$AWS_REGION" \
    --query RestoreJobId \
    --output text)

  echo "✅ Restore Job ID: $RESTORE_JOB_ID"
}

# Function: Wait for restore job
wait_for_restore() {
  echo "Waiting for restore job ($RESTORE_JOB_ID) to complete..."
  while true; do
    STATUS=$(aws backup list-restore-jobs \
      --region "$AWS_REGION" \
      --query "RestoreJobs[?RestoreJobId=='$RESTORE_JOB_ID'].Status" \
      --output text)

    echo "   Current Restore Status: $STATUS"

    if [[ "$STATUS" == "COMPLETED" ]]; then
      echo "✅ Restore completed successfully!"
      break
    elif [[ "$STATUS" == "FAILED" ]]; then
      echo "❌ Restore failed. Checking error details..."
      aws backup list-restore-jobs \
        --region "$AWS_REGION" \
        --query "RestoreJobs[?RestoreJobId=='$RESTORE_JOB_ID'].[StatusMessage]" \
        --output text
      exit 1
    fi
    sleep 30
  done
}

# Function: Get restored DB endpoint
get_db_endpoint() {
  echo "Fetching DB endpoint..."
  DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)

  if [[ -z "$DB_ENDPOINT" ]]; then
    echo "❌ Could not fetch DB endpoint."
    exit 1
  fi
  echo "✅ DB Endpoint: $DB_ENDPOINT"
}

# Function: Update Secrets Manager with new endpoint
update_secret() {
  echo "Fetching current secret value..."
  current_secret=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text)

  updated_secret=$(echo "$current_secret" | jq --arg host "$DB_ENDPOINT" '.host = $host')

  echo "Updating secret '$SECRET_NAME' with new host..."
  aws secretsmanager update-secret \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --secret-string "$updated_secret"
  
  echo "✅ Secret updated successfully"
}

# Function: Update ECS service to force new deployment
update_ecs_service() {
  echo "Updating ECS service to force new deployment..."
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --force-new-deployment \
    --region "$AWS_REGION"

  echo "✅ ECS service updated"
}

# ----------------- MAIN -----------------
get_latest_recovery_point
check_db_identifier
check_subnet_group
start_restore_job
wait_for_restore
get_db_endpoint
update_secret
update_ecs_service
# ----------------------------------------
