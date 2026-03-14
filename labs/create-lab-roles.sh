#!/bin/bash
# Creates a scoped IAM role for each lab and assumes it for a 1-hour session.
# Compatible with bash 3 (macOS default).
# Usage:
#   ./create-lab-roles.sh setup          # create all roles (run once)
#   source ./create-lab-roles.sh session <lab>  # export creds for a specific lab
#   ./create-lab-roles.sh list           # list all lab roles
#   ./create-lab-roles.sh cleanup        # delete all lab roles

# Detect if script is being sourced (to use return instead of exit)
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0
_exit() { [ "$SOURCED" -eq 1 ] && return "$1" || exit "$1"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
if [ $? -ne 0 ]; then
  echo "ERROR: AWS credentials not configured. Run 'aws configure' first."
  _exit 1
fi
DURATION=3600

# ── Trust policy (allows the account root / any IAM user to assume) ──────────
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_ID}:root" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

# ── All lab names (ordered) ───────────────────────────────────────────────────
ALL_LABS="00-provider 01-ec2 02-s3 03-rds 04-vpc 05-iam 06-lambda 07-ecs 08-alb-cloudfront 09-sqs-sns 10-cloudwatch 11-api-gateway 12-dynamodb 13-elasticache 14-kinesis 15-cicd 16-migration 17-ml-ai 18-backup-iot 19-architecture-complete 20-route53 21-load-balancer 22-auto-scaling 23-eks 24-secrets-manager 25-waf-shield 26-cloudformation 27-step-functions 28-ses 29-redshift 30-opensearch 31-emr 32-glue 33-athena 34-efs 35-fsx 36-storage-gateway 37-transfer-family 38-datasync 39-organizations 40-config 41-guardduty 42-inspector 43-macie 44-kms 45-cognito-advanced 46-appsync 47-eventbridge-advanced 48-fargate 49-capstone"

# ── Per-lab managed policies (bash 3 compatible: case statement) ──────────────
get_lab_policies() {
  local lab=$1
  case "$lab" in
    00-provider)
      echo "arn:aws:iam::aws:policy/ReadOnlyAccess"
      ;;
    01-ec2)
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/AutoScalingFullAccess"
      ;;
    02-s3)
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    03-rds)
      echo "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      ;;
    04-vpc)
      echo "arn:aws:iam::aws:policy/AmazonVPCFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    05-iam)
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      echo "arn:aws:iam::aws:policy/AWSKeyManagementServicePowerUser"
      echo "arn:aws:iam::aws:policy/AmazonCognitoPowerUser"
      ;;
    06-lambda)
      echo "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess"
      ;;
    07-ecs)
      echo "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    08-alb-cloudfront)
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudFrontFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess"
      ;;
    09-sqs-sns)
      echo "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess"
      ;;
    10-cloudwatch)
      echo "arn:aws:iam::aws:policy/CloudWatchFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    11-api-gateway)
      echo "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
      echo "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    12-dynamodb)
      echo "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      ;;
    13-elasticache)
      echo "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      ;;
    14-kinesis)
      echo "arn:aws:iam::aws:policy/AmazonKinesisFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonKinesisFirehoseFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonAthenaFullAccess"
      echo "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    15-cicd)
      echo "arn:aws:iam::aws:policy/AWSCodeCommitFullAccess"
      echo "arn:aws:iam::aws:policy/AWSCodeBuildAdminAccess"
      echo "arn:aws:iam::aws:policy/AWSCodeDeployFullAccess"
      echo "arn:aws:iam::aws:policy/AWSCodePipeline_FullAccess"
      echo "arn:aws:iam::aws:policy/AWSCodeArtifactAdminAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    16-migration)
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AWSDataSyncFullAccess"
      echo "arn:aws:iam::aws:policy/AWSBackupFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    17-ml-ai)
      echo "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonRekognitionFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    18-backup-iot)
      echo "arn:aws:iam::aws:policy/AWSIoTFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEventBridgeSchedulerFullAccess"
      echo "arn:aws:iam::aws:policy/AWSDirectoryServiceFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    19-architecture-complete)
      echo "arn:aws:iam::aws:policy/AdministratorAccess"
      ;;
    20-route53)
      echo "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchFullAccess"
      ;;
    21-load-balancer)
      echo "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/AutoScalingFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchFullAccess"
      ;;
    22-auto-scaling)
      echo "arn:aws:iam::aws:policy/AutoScalingFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      ;;
    23-eks)
      echo "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
      echo "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      echo "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      ;;
    24-secrets-manager)
      echo "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
      echo "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
      echo "arn:aws:iam::aws:policy/AWSKeyManagementServicePowerUser"
      echo "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
      ;;
    25-waf-shield)
      echo "arn:aws:iam::aws:policy/AWSWAFFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudFrontFullAccess"
      echo "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
      ;;
    26-cloudformation)
      echo "arn:aws:iam::aws:policy/AWSCloudFormationFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      ;;
    27-step-functions)
      echo "arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess"
      echo "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    28-ses)
      echo "arn:aws:iam::aws:policy/AmazonSESFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchFullAccess"
      ;;
    29-redshift)
      echo "arn:aws:iam::aws:policy/AmazonRedshiftFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    30-opensearch)
      echo "arn:aws:iam::aws:policy/AmazonOpenSearchServiceFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    31-emr)
      echo "arn:aws:iam::aws:policy/AmazonEMRFullAccessPolicy_v2"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    32-glue)
      echo "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonAthenaFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    33-athena)
      echo "arn:aws:iam::aws:policy/AmazonAthenaFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      ;;
    34-efs)
      echo "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      ;;
    35-fsx)
      echo "arn:aws:iam::aws:policy/AmazonFSxFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    36-storage-gateway)
      echo "arn:aws:iam::aws:policy/AWSStorageGatewayFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    37-transfer-family)
      echo "arn:aws:iam::aws:policy/AWSTransferFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    38-datasync)
      echo "arn:aws:iam::aws:policy/AWSDataSyncFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      ;;
    39-organizations)
      echo "arn:aws:iam::aws:policy/AWSOrganizationsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      echo "arn:aws:iam::aws:policy/AWSCloudFormationFullAccess"
      ;;
    40-config)
      echo "arn:aws:iam::aws:policy/AWSConfigUserAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      echo "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
      ;;
    41-guardduty)
      echo "arn:aws:iam::aws:policy/AmazonGuardDutyFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      ;;
    42-inspector)
      echo "arn:aws:iam::aws:policy/AmazonInspector2FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      ;;
    43-macie)
      echo "arn:aws:iam::aws:policy/AmazonMacieFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      ;;
    44-kms)
      echo "arn:aws:iam::aws:policy/AWSKeyManagementServicePowerUser"
      echo "arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    45-cognito-advanced)
      echo "arn:aws:iam::aws:policy/AmazonCognitoPowerUser"
      echo "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    46-appsync)
      echo "arn:aws:iam::aws:policy/AWSAppSyncAdministrator"
      echo "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
      echo "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    47-eventbridge-advanced)
      echo "arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess"
      echo "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    48-fargate)
      echo "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
      echo "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
      echo "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
      echo "arn:aws:iam::aws:policy/AmazonVPCFullAccess"
      echo "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
      echo "arn:aws:iam::aws:policy/IAMFullAccess"
      ;;
    49-capstone)
      echo "arn:aws:iam::aws:policy/AdministratorAccess"
      ;;
    *)
      echo "ERROR: Unknown lab: $lab" >&2
      return 1
      ;;
  esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────
role_name() { echo "saa-lab-${1}"; }

create_role() {
  local lab=$1
  local role
  role=$(role_name "$lab")

  echo "──────────────────────────────────────────"
  echo "Creating role: $role"

  if aws iam get-role --role-name "$role" &>/dev/null; then
    echo "  Role already exists, updating trust policy..."
    aws iam update-assume-role-policy \
      --role-name "$role" \
      --policy-document "$TRUST_POLICY"
  else
    aws iam create-role \
      --role-name "$role" \
      --assume-role-policy-document "$TRUST_POLICY" \
      --description "Scoped role for lab $lab" \
      --max-session-duration $DURATION \
      --tags Key=Environment,Value=lab Key=Lab,Value="$lab" \
      --output text --query 'Role.RoleName' | xargs echo "  Created:"
  fi
  aws iam tag-role --role-name "$role" \
    --tags Key=Environment,Value=lab Key=Lab,Value="$lab"

  aws iam put-role-policy \
    --role-name "$role" \
    --policy-name "lab-tagging-read" \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"tag:GetResources","Resource":"*"}]}'

  while IFS= read -r policy_arn; do
    [ -z "$policy_arn" ] && continue
    echo "  Attaching: $policy_arn"
    aws iam attach-role-policy \
      --role-name "$role" \
      --policy-arn "$policy_arn"
  done <<< "$(get_lab_policies "$lab")"
}

assume_role() {
  local lab=$1
  local role
  role=$(role_name "$lab")
  local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role}"

  # Clear any existing session so we always assume from the base IAM user
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
  unset AWS_SESSION_TOKEN

  echo "Assuming role for lab: $lab"
  echo "Role ARN: $role_arn"

  CREDS=$(aws sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "saa-${lab}-$(date +%s)" \
    --duration-seconds $DURATION)

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
  AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
  AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')

  echo ""
  echo "Session active until: $(echo "$CREDS" | jq -r '.Credentials.Expiration')"
  echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
  echo ""
  echo "Run: cd labs/$lab && terraform init && terraform plan"
}

delete_role() {
  local lab=$1
  local role
  role=$(role_name "$lab")

  echo "Deleting role: $role"

  aws iam delete-role-policy --role-name "$role" --policy-name "lab-tagging-read" 2>/dev/null || true

  aws iam list-attached-role-policies --role-name "$role" \
    --query 'AttachedPolicies[].PolicyArn' --output text | \
  tr '\t' '\n' | while read -r arn; do
    [ -z "$arn" ] && continue
    echo "  Detaching: $arn"
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
  done

  aws iam delete-role --role-name "$role"
  echo "  Deleted."
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "${1:-help}" in
  setup)
    echo "Creating IAM roles for all labs (Account: $ACCOUNT_ID)"
    for lab in $ALL_LABS; do
      create_role "$lab"
    done
    echo ""
    echo "Done. To start a session: source ./create-lab-roles.sh session <lab-name>"
    echo "Example: source ./create-lab-roles.sh session 01-ec2"
    ;;

  session)
    if [ -z "$2" ]; then
      echo "Usage: source ./create-lab-roles.sh session <lab-name>"
      echo "Labs: $ALL_LABS"
      _exit 1
    fi
    assume_role "$2"
    ;;

  list)
    echo "Lab roles in account $ACCOUNT_ID:"
    for lab in $ALL_LABS; do
      role=$(role_name "$lab")
      if aws iam get-role --role-name "$role" --query 'Role.RoleName' --output text &>/dev/null; then
        status="EXISTS"
      else
        status="MISSING"
      fi
      printf "  %-35s %s\n" "$role" "$status"
    done
    ;;

  tag-all)
    echo "Tagging all lab roles (Account: $ACCOUNT_ID)"
    for lab in $ALL_LABS; do
      role=$(role_name "$lab")
      if aws iam get-role --role-name "$role" &>/dev/null; then
        aws iam tag-role --role-name "$role" \
          --tags Key=Environment,Value=lab Key=Lab,Value="$lab"
        echo "  Tagged: $role"
      else
        echo "  Role $role not found, skipping."
      fi
    done
    echo "Done. Query with:"
    echo "  aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=lab --query 'ResourceTagMappingList[].ResourceARN' --output text"
    ;;

  cleanup)
    echo "Deleting all lab roles (Account: $ACCOUNT_ID)"
    for lab in $ALL_LABS; do
      role=$(role_name "$lab")
      if aws iam get-role --role-name "$role" &>/dev/null; then
        delete_role "$lab"
      else
        echo "  Role $role not found, skipping."
      fi
    done
    echo "Done."
    ;;

  *)
    echo "Usage:"
    echo "  ./create-lab-roles.sh setup                    # Create all roles (run once)"
    echo "  source ./create-lab-roles.sh session <lab>     # Export creds for a lab"
    echo "  ./create-lab-roles.sh list                     # List all roles + status"
    echo "  ./create-lab-roles.sh tag-all                  # Tag all existing roles (Environment=lab)"
    echo "  ./create-lab-roles.sh cleanup                  # Delete all roles"
    echo ""
    echo "Available labs:"
    echo "$ALL_LABS" | tr ' ' '\n' | sed 's/^/  /'
    ;;
esac
