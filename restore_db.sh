#!/bin/bash
set -euo pipefail

# ----------------- CONFIGURATION -----------------
DB_INSTANCE_IDENTIFIER="$1"
SECURITY_GROUP_IDS=["sg-0c7ff10ff513eaaf4","sg-0ebf411a4d322834f"]
RESTORE_TIMEOUT_MINUTES=60

# -------------------------------------------------

# Function: Get latest recovery point
get_latest_recovery_point() {
    echo "Fetching latest recovery point..."
    LATEST_RECOVERY_POINT=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$BACKUP_VAULT" \
        --region "$AWS_REGION" \
        --query "RecoveryPoints | sort_by(@, &CreationDate)[-1].RecoveryPointArn" \
        --output text)

    if [[ -z "$LATEST_RECOVERY_POINT" || "$LATEST_RECOVERY_POINT" == "None" ]]; then
        echo "ERROR: No recovery points found in vault: $BACKUP_VAULT"
        exit 1
    fi
    echo "Latest Recovery Point: $LATEST_RECOVERY_POINT"
}

# Function: Check DB identifier availability
check_db_identifier() {
    echo "Checking if DB identifier already exists..."
    EXISTS=$(aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --query "DBInstances[?DBInstanceIdentifier=='$DB_INSTANCE_IDENTIFIER'].DBInstanceIdentifier" \
        --output text || true)

    if [[ "$EXISTS" == "$DB_INSTANCE_IDENTIFIER" ]]; then
        echo "DB identifier already exists. Appending timestamp."
        DB_INSTANCE_IDENTIFIER="${DB_INSTANCE_IDENTIFIER}-$(date +%Y%m%d%H%M)"
    fi
    echo "Using DB identifier: $DB_INSTANCE_IDENTIFIER"
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
        echo "ERROR: Subnet group '$DB_SUBNET_GROUP' not found in region $AWS_REGION"
        exit 1
    fi
    echo "Subnet group '$DB_SUBNET_GROUP' exists."
}

start_restore_job() {
    echo "Starting restore job..."
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

    echo "Restore Job ID: $RESTORE_JOB_ID"
}


# Function: Wait for restore job
wait_for_restore() {
    echo "Waiting for restore job ($RESTORE_JOB_ID) to complete..."
    END_TIME=$(( $(date +%s) + RESTORE_TIMEOUT_MINUTES*60 ))
    while true; do
        STATUS=$(aws backup list-restore-jobs \
            --region "$AWS_REGION" \
            --query "RestoreJobs[?RestoreJobId=='$RESTORE_JOB_ID'].Status" \
            --output text)

        echo "Current Restore Status: $STATUS"

        if [[ "$STATUS" == "COMPLETED" ]]; then
            echo "Restore completed successfully!"
            break
        elif [[ "$STATUS" == "FAILED" ]]; then
            echo "Restore failed. Error details:"
            aws backup list-restore-jobs \
                --region "$AWS_REGION" \
                --query "RestoreJobs[?RestoreJobId=='$RESTORE_JOB_ID'].[StatusMessage]" \
                --output text
            exit 1
        fi

        if [[ $(date +%s) -ge $END_TIME ]]; then
            echo "Restore timed out after $RESTORE_TIMEOUT_MINUTES minutes."
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
        echo "ERROR: Could not fetch DB endpoint."
        exit 1
    fi
    echo "DB Endpoint: $DB_ENDPOINT"
}

# Function: Update Secrets Manager with new endpoint
# Function: Update Secrets Manager with new DB endpoint
update_secret() {
    echo "Updating Secrets Manager with new DB endpoint..."
    
    # Fetch current secret
    current_secret=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_NAME" \
        --region "$AWS_REGION" \
        --query SecretString \
        --output text)

    # Update the DB_HOST key
    updated_secret=$(echo "$current_secret" | jq --arg db_host "$DB_ENDPOINT" '.DB_HOST = $db_host')

    # Push updated secret back to Secrets Manager
    aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --region "$AWS_REGION" \
        --secret-string "$updated_secret"

    echo "Secret updated successfully"
}
# Function: Update ECS service with desired count
update_ecs_service() {
    echo "Updating ECS service to force new deployment with desired count..."
    aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$ECS_SERVICE" \
        --desired-count 1 \
        --force-new-deployment \
        --region "$AWS_REGION"
    echo "✅ ECS service update triggered"
}

# Function: Wait until ECS service is stable
wait_for_ecs_service() {
    echo "Waiting for ECS service to reach a stable state..."
    aws ecs wait services-stable \
        --cluster "$ECS_CLUSTER" \
        --services "$ECS_SERVICE" \
        --region "$AWS_REGION"
    echo "✅ ECS service is now stable"
}


# ----------------- MAIN PIPELINE -----------------
get_latest_recovery_point
check_db_identifier
check_subnet_group
start_restore_job
wait_for_restore
get_db_endpoint
update_secret
update_ecs_service
wait_for_ecs_service
-------------------------------------------------
