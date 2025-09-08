#!/bin/bash
set -e

AWS_REGION="ap-south-2"
BACKUP_VAULT="rds-dr-vault"
DB_INSTANCE_IDENTIFIER="back-upstore"
DB_PORT="3306"
DB_SUBNET_GROUP="default-vpc-051642d98eff4a857"
SECURITY_GROUP_IDS='["sg-0dbe4ffceac1371e2"]'  # <-- JSON string
ECS_CLUSTER="daister-services-cluster"
ECS_SERVICE="back-updashboard"
IAM_ROLE_ARN="arn:aws:iam::585008046531:role/service-role/AWSBackupDefaultServiceRole"
SECRET_NAME="back-service"

# Get latest recovery point
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

# Validate subnet group
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

# Start restore job
# Function: Start restore job
start_restore_job() {
    echo "Starting restore job..."
    
    # Build metadata JSON safely using jq
    METADATA_JSON=$(jq -n \
        --arg db "$DB_INSTANCE_IDENTIFIER" \
        --arg class "db.t4g.micro" \
        --arg subnet "$DB_SUBNET_GROUP" \
        --arg sg "$SECURITY_GROUP_IDS" \
        --arg port "$DB_PORT" \
        '{DBInstanceIdentifier:$db, DBInstanceClass:$class, DBSubnetGroupName:$subnet, VpcSecurityGroupIds:$sg, Port:$port, PubliclyAccessible:"true"}')

    RESTORE_JOB_ID=$(aws backup start-restore-job \
        --recovery-point-arn "$LATEST_RECOVERY_POINT" \
        --metadata "$METADATA_JSON" \
        --iam-role-arn "$IAM_ROLE_ARN" \
        --resource-type RDS \
        --region "$AWS_REGION" \
        --query RestoreJobId \
        --output text)

    echo "✅ Restore Job ID: $RESTORE_JOB_ID"
}


# Wait for restore job
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

# MAIN
get_latest_recovery_point
check_subnet_group
start_restore_job
wait_for_restore
