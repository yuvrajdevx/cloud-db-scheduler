#!/bin/bash
# cloudformation/deploy.sh
#
# Deploys the AWS Instance Scheduler hub stack (hub/shared account)
# and spoke stack (workload/non-prod account).
#
# Must be run by an account with CloudFormation + IAM permissions in both accounts.
#
# Usage:
#   ./cloudformation/deploy.sh
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Set the profile names below to match your local AWS config,
#     or export AWS credentials directly before running
#   - Both profiles need CloudFormation + IAM permissions in their respective accounts

set -euo pipefail

# ─── Edit these if your AWS CLI profiles have different names ─────────────────
SHARED_SERVICES_PROFILE="shared-services"   # your hub account profile
NONPROD_PROFILE="nonprod"                   # your workload account profile
REGION="us-east-1"

HUB_STACK_NAME="instance-scheduler"
SPOKE_STACK_NAME="instance-scheduler-spoke"

TEMPLATE_HUB="https://s3.amazonaws.com/solutions-reference/instance-scheduler-on-aws/latest/instance-scheduler-on-aws.template"
TEMPLATE_SPOKE="https://s3.amazonaws.com/solutions-reference/instance-scheduler-on-aws/latest/instance-scheduler-on-aws-remote.template"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Helpers ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "\n${YELLOW}══════════════════════════════════════════${NC}"; echo -e "${YELLOW}  $*${NC}"; echo -e "${YELLOW}══════════════════════════════════════════${NC}"; }
wait_for_stack() {
  local stack_name="$1" profile="$2" action="$3"
  info "Waiting for $stack_name to reach ${action}_COMPLETE..."
  aws cloudformation wait "stack-${action}-complete" \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --profile "$profile"
  info "$stack_name: ${action}_COMPLETE ✓"
}

# ─── Step 1: Hub stack in the hub/shared account ──────────────────────────────
step "Step 1/2 — Hub stack → hub account"

EXISTING_HUB=$(aws cloudformation describe-stacks \
  --stack-name "$HUB_STACK_NAME" \
  --region "$REGION" \
  --profile "$SHARED_SERVICES_PROFILE" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$EXISTING_HUB" = "DOES_NOT_EXIST" ]; then
  info "Creating hub stack..."
  aws cloudformation create-stack \
    --stack-name "$HUB_STACK_NAME" \
    --template-url "$TEMPLATE_HUB" \
    --parameters file://"${SCRIPT_DIR}/hub-parameters.json" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --profile "$SHARED_SERVICES_PROFILE"
  wait_for_stack "$HUB_STACK_NAME" "$SHARED_SERVICES_PROFILE" "create"
else
  info "Hub stack already exists (status: $EXISTING_HUB) — updating..."
  UPDATE_OUT=$(aws cloudformation update-stack \
    --stack-name "$HUB_STACK_NAME" \
    --template-url "$TEMPLATE_HUB" \
    --parameters file://"${SCRIPT_DIR}/hub-parameters.json" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --profile "$SHARED_SERVICES_PROFILE" 2>&1) && {
    wait_for_stack "$HUB_STACK_NAME" "$SHARED_SERVICES_PROFILE" "update"
  } || {
    if echo "$UPDATE_OUT" | grep -q "No updates are to be performed"; then
      info "Hub stack: no changes to apply"
    else
      echo "$UPDATE_OUT" >&2
      exit 1
    fi
  }
fi

# ─── Step 2: Spoke stack in the workload account ──────────────────────────────
step "Step 2/2 — Spoke stack → workload account"

EXISTING_SPOKE=$(aws cloudformation describe-stacks \
  --stack-name "$SPOKE_STACK_NAME" \
  --region "$REGION" \
  --profile "$NONPROD_PROFILE" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$EXISTING_SPOKE" = "DOES_NOT_EXIST" ]; then
  info "Creating spoke stack..."
  aws cloudformation create-stack \
    --stack-name "$SPOKE_STACK_NAME" \
    --template-url "$TEMPLATE_SPOKE" \
    --parameters file://"${SCRIPT_DIR}/spoke-parameters.json" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --profile "$NONPROD_PROFILE"
  wait_for_stack "$SPOKE_STACK_NAME" "$NONPROD_PROFILE" "create"
else
  info "Spoke stack already exists (status: $EXISTING_SPOKE) — updating..."
  UPDATE_OUT=$(aws cloudformation update-stack \
    --stack-name "$SPOKE_STACK_NAME" \
    --template-url "$TEMPLATE_SPOKE" \
    --parameters file://"${SCRIPT_DIR}/spoke-parameters.json" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --profile "$NONPROD_PROFILE" 2>&1) && {
    wait_for_stack "$SPOKE_STACK_NAME" "$NONPROD_PROFILE" "update"
  } || {
    if echo "$UPDATE_OUT" | grep -q "No updates are to be performed"; then
      info "Spoke stack: no changes to apply"
    else
      echo "$UPDATE_OUT" >&2
      exit 1
    fi
  }
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
step "Done"
echo ""
echo -e "${CYAN}Both stacks are deployed. Next steps:${NC}"
echo "  1. Create the schedule in DynamoDB (scheduler-cli) — see README Step 4"
echo "  2. Tag your databases: ./tagging/tag-nonprod-resources.sh"
echo "  3. Deploy aurora-restop Lambda: ./aurora-restop/deploy.sh"
echo ""
info "Instance Scheduler will begin acting on tagged resources within 5 minutes."
