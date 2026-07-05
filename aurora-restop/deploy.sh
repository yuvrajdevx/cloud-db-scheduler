#!/bin/bash
# aurora-restop/deploy.sh
#
# Deploys the aurora-restop Lambda and all supporting AWS resources
# (IAM role, SNS topic, EventBridge rule) using the AWS CLI.
#
# Run this from the hub/shared account.
#
# Usage:
#   ./deploy.sh                                      # first deploy (default credentials)
#   AWS_PROFILE=shared-services ./deploy.sh          # with a named profile
#   ./deploy.sh --update-code-only                   # re-deploy Lambda code only

set -euo pipefail

# ─── Config — edit these for your environment ─────────────────────────────────
SHARED_SERVICES_ACCOUNT="${SHARED_SERVICES_ACCOUNT:?Set SHARED_SERVICES_ACCOUNT to your hub account ID}"
TARGET_ACCOUNT="${TARGET_ACCOUNT:?Set TARGET_ACCOUNT to your workload account ID}"
REGION="${REGION:-us-east-1}"
LAMBDA_NAME="aurora-restop"
ROLE_NAME="aurora-restop-lambda"
SNS_TOPIC_NAME="aurora-restop-alerts"
RULE_NAME="aurora-restop-weekly"
ALERT_EMAIL="${ALERT_EMAIL:-}"          # optional: ALERT_EMAIL=you@example.com ./deploy.sh
UPDATE_CODE_ONLY="${1:-}"

# If AWS_PROFILE is set in the environment, pass it through to all aws commands.
AWS_ARGS=""
if [ -n "${AWS_PROFILE:-}" ]; then
  AWS_ARGS="--profile $AWS_PROFILE"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "\n${YELLOW}───────────────────────────────────────${NC}"; echo -e "${YELLOW}$*${NC}"; }

# ─── Verify we're in the right account ───────────────────────────────────────
ACTIVE_ACCOUNT=$(aws sts get-caller-identity --query Account --output text $AWS_ARGS)
if [ "$ACTIVE_ACCOUNT" != "$SHARED_SERVICES_ACCOUNT" ]; then
  echo "ERROR: Active AWS account is $ACTIVE_ACCOUNT, expected $SHARED_SERVICES_ACCOUNT (hub account)."
  echo "Set AWS_PROFILE or export credentials for the hub account before running."
  exit 1
fi
info "Account verified: $ACTIVE_ACCOUNT (hub account)"

# ─── Package Lambda ───────────────────────────────────────────────────────────
step "Packaging Lambda"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
zip -q handler.zip handler.py
info "handler.zip created"

# ─── Code-only update (skip infra) ────────────────────────────────────────────
if [ "$UPDATE_CODE_ONLY" = "--update-code-only" ]; then
  step "Updating Lambda code only"
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file fileb://handler.zip \
    --region "$REGION" \
    $AWS_ARGS
  info "Lambda code updated. Done."
  rm -f handler.zip
  exit 0
fi

# ─── Step 1: SNS topic ────────────────────────────────────────────────────────
step "Step 1/5 — Creating SNS topic"
SNS_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --region "$REGION" \
  --query TopicArn --output text \
  $AWS_ARGS)
info "SNS topic: $SNS_ARN"

if [ -n "$ALERT_EMAIL" ]; then
  aws sns subscribe \
    --topic-arn "$SNS_ARN" \
    --protocol email \
    --notification-endpoint "$ALERT_EMAIL" \
    --region "$REGION" \
    $AWS_ARGS > /dev/null
  info "Subscribed $ALERT_EMAIL — check your inbox to confirm"
fi

# ─── Step 2: IAM role ─────────────────────────────────────────────────────────
step "Step 2/5 — Creating IAM role"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

CREATE_OUT=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --query Role.Arn --output text \
  $AWS_ARGS 2>&1) && ROLE_ARN="$CREATE_OUT" || {
  if echo "$CREATE_OUT" | grep -q "EntityAlreadyExists"; then
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text $AWS_ARGS)
  else
    echo "$CREATE_OUT" >&2
    exit 1
  fi
}
info "Role: $ROLE_ARN"

INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${TARGET_ACCOUNT}:role/instance-scheduler-target-role"
    },
    {
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "${SNS_ARN}"
    },
    {
      "Effect": "Allow",
      "Action": "logs:CreateLogGroup",
      "Resource": "arn:aws:logs:${REGION}:${SHARED_SERVICES_ACCOUNT}:log-group:/aws/lambda/${LAMBDA_NAME}"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${SHARED_SERVICES_ACCOUNT}:log-group:/aws/lambda/${LAMBDA_NAME}:*"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${ROLE_NAME}-policy" \
  --policy-document "$INLINE_POLICY" \
  $AWS_ARGS
info "Inline policy attached"

info "Waiting 10s for IAM propagation..."
sleep 10

# ─── Step 3: Lambda function ──────────────────────────────────────────────────
step "Step 3/5 — Creating Lambda function"
EXISTING=$(aws lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" \
  $AWS_ARGS 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --description "Re-stops Aurora/DocDB clusters auto-restarted by AWS after 7 days." \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler handler.handler \
    --zip-file fileb://handler.zip \
    --timeout 120 \
    --environment "Variables={TARGET_ACCOUNT_ID=${TARGET_ACCOUNT},TARGET_ROLE_NAME=instance-scheduler-target-role,SNS_TOPIC_ARN=${SNS_ARN}}" \
    --region "$REGION" \
    $AWS_ARGS > /dev/null
  info "Lambda created"
else
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file fileb://handler.zip \
    --region "$REGION" \
    $AWS_ARGS > /dev/null
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "Variables={TARGET_ACCOUNT_ID=${TARGET_ACCOUNT},TARGET_ROLE_NAME=instance-scheduler-target-role,SNS_TOPIC_ARN=${SNS_ARN}}" \
    --region "$REGION" \
    $AWS_ARGS > /dev/null
  info "Lambda updated"
fi

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" \
  --query Configuration.FunctionArn --output text \
  $AWS_ARGS)
info "Lambda ARN: $LAMBDA_ARN"

# ─── Step 4: EventBridge rule ─────────────────────────────────────────────────
# cron(0 17 ? * SUN *) = Sunday 17:00 UTC — an example schedule that fires
# before a Monday-morning start window in a UTC+12/+13 timezone. Adjust the
# cron expression to run shortly before your own Instance Scheduler start time.
step "Step 4/5 — Creating EventBridge rule"
RULE_ARN=$(aws events put-rule \
  --name "$RULE_NAME" \
  --description "Weekly re-stop of Aurora/DocDB clusters auto-restarted by AWS." \
  --schedule-expression "cron(0 17 ? * SUN *)" \
  --state ENABLED \
  --region "$REGION" \
  --query RuleArn --output text \
  $AWS_ARGS)
info "EventBridge rule: $RULE_ARN"

aws lambda add-permission \
  --function-name "$LAMBDA_NAME" \
  --statement-id "AllowEventBridgeInvoke" \
  --action "lambda:InvokeFunction" \
  --principal "events.amazonaws.com" \
  --source-arn "$RULE_ARN" \
  --region "$REGION" \
  $AWS_ARGS > /dev/null 2>&1 || true   # ignore if permission already exists

aws events put-targets \
  --rule "$RULE_NAME" \
  --targets "Id=aurora-restop-lambda,Arn=${LAMBDA_ARN}" \
  --region "$REGION" \
  $AWS_ARGS > /dev/null
info "EventBridge target set"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
rm -f handler.zip

# ─── Step 5: Summary ──────────────────────────────────────────────────────────
step "Done"
echo ""
echo "  Lambda    : $LAMBDA_ARN"
echo "  SNS topic : $SNS_ARN"
echo "  Rule      : $RULE_ARN"
echo "  Schedule  : every Sunday 17:00 UTC (adjust to suit your timezone)"
echo ""
info "To test immediately:"
echo "  aws lambda invoke --function-name $LAMBDA_NAME --region $REGION /tmp/out.json $AWS_ARGS && cat /tmp/out.json"
echo ""
info "To update code only in future:"
echo "  AWS_PROFILE=${AWS_PROFILE:-shared-services} ./deploy.sh --update-code-only"
