#!/bin/bash
set -e

AWS_REGION="ap-south-2"   
BACKUP_VAULT="rds-dr-vault"
DB_INSTANCE_IDENTIFIER="back-upstore"
DB_USER="admin"
DB_PASSWORD="8E|KU5wB62#u"
DB_PORT="3306"
DB_SUBNET_GROUP="default-vpc-051642d98eff4a857"
SECURITY_GROUP_IDS="sg-0dbe4ffceac1371e2"
ECS_CLUSTER="daister-services-cluster"
ECS_SERVICE="back-updashboard"
IAM_ROLE_ARN="arn:aws:iam::585008046531:role/service-role/AWSBackupDefaultServiceRole"
SECRET_NAME="back-service"   

LATEST_RECOVERY_POINT=""
RESTORE_JOB_ID=""
DB_ENDPOINT=""

# === Functions ===

get_latest_recovery_point() {
    echo "Fetching latest recovery point..."
    LATEST_RECOVERY_POINT=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$BACKUP_VAULT" \
        --region "$AWS_REGION" \
        --query "RecoveryPoints | sort_by(@, &CreationDate)[-1].RecoveryPointArn" \
        --output text)

    if [[ "$LATEST_RECOVERY_POINT" == "None" || -z "$LATEST_RECOVERY_POINT" ]]; then
        echo "No recovery points found in vault: $BACKUP_VAULT"
        exit 1
    fi
    echo "Latest Recovery Point: $LATEST_RECOVERY_POINT"
}

start_restore_job() {
    echo "Starting restore job..."
    RESTORE_JOB_ID=$(aws backup start-restore-job \
        --recovery-point-arn "$LATEST_RECOVERY_POINT" \
        --metadata "{
            \"DBInstanceIdentifier\":\"$DB_INSTANCE_IDENTIFIER\",
            \"Engine\":\"mysql\",
            \"DBInstanceClass\":\"db.t4g.micro\",
            \"MasterUsername\":\"$DB_USER\",
            \"MasterUserPassword\":\"$DB_PASSWORD\",
            \"DBSubnetGroupName\":\"$DB_SUBNET_GROUP\",
            \"VpcSecurityGroupIds\":\"$SECURITY_GROUP_IDS\",
            \"MultiAZ\":\"false\",
            \"PubliclyAccessible\":\"true\",
            \"Port\":\"$DB_PORT\"
        }" \
        --iam-role-arn "$IAM_ROLE_ARN" \
        --resource-type RDS \
        --region "$AWS_REGION" \
        --query RestoreJobId \
        --output text)

    echo "Restore Job ID: $RESTORE_JOB_ID"
}

wait_for_restore() {
    echo "Waiting for restore job ($RESTORE_JOB_ID) to complete..."
    while true; do
        STATUS=$(aws backup list-restore-jobs \
            --region "$AWS_REGION" \
            --query "RestoreJobs[?RestoreJobId=='$RESTORE_JOB_ID'].[Status]" \
            --output text)
        echo "   Current Restore Status: $STATUS"

        if [[ "$STATUS" == "COMPLETED" ]]; then
            echo "Restore completed successfully"
            break
        elif [[ "$STATUS" == "FAILED" ]]; then
            echo "Restore failed"
            exit 1
        fi
        sleep 60
    done
}

wait_for_rds_available() {
    echo "Waiting for RDS instance ($DB_INSTANCE_IDENTIFIER) to become available..."
    aws rds wait db-instance-available \
        --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --region "$AWS_REGION"
    echo "RDS instance is now available"
}

get_restored_endpoint() {
    echo "Fetching endpoint for restored DB: $DB_INSTANCE_IDENTIFIER"
    DB_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --region "$AWS_REGION" \
        --query "DBInstances[0].Endpoint.Address" \
        --output text)

    if [[ -z "$DB_ENDPOINT" ]]; then
        echo "Error: Could not fetch DB endpoint"
        exit 1
    fi
    echo "Restored DB Endpoint: $DB_ENDPOINT"
}

update_secret() {
  local endpoint=$1

  if [[ -z "$endpoint" ]]; then
    echo "Error: No endpoint passed to update_secret()"
    exit 1
  fi

  echo "Fetching current secret value..."
  local current_secret
  current_secret=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text)

  if [[ -z "$current_secret" ]]; then
    echo "Error: Could not fetch secret value for $SECRET_NAME"
    exit 1
  fi

  local updated_secret
  updated_secret=$(echo "$current_secret" | jq --arg host "$endpoint" '.host = $host')

  echo "Updating secret '$SECRET_NAME' with new host..."
  aws secretsmanager update-secret \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --secret-string "$updated_secret"

  echo "Secret '$SECRET_NAME' updated successfully with new DB endpoint: $endpoint"
}

update_ecs_service() {
    echo "Updating ECS service ($ECS_SERVICE) to use DR DB..."
    aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$ECS_SERVICE" \
        --force-new-deployment \
        --region "$AWS_REGION"
    echo "ECS service updated"
}

main() {
    get_latest_recovery_point
    start_restore_job
    wait_for_restore
    wait_for_rds_available
    get_restored_endpoint
    update_secret "$DB_ENDPOINT"
    update_ecs_service
    echo "DR Workflow Completed Successfully"
}

# === Run Script ===
main

