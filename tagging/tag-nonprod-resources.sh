#!/bin/bash
# tag-nonprod-resources.sh
#
# Tags non-prod RDS instances and Aurora/DocDB clusters with
# Schedule=nonprod-schedule so AWS Instance Scheduler picks them up.
#
# Prerequisites:
#   - AWS CLI configured with credentials for your workload account
#   - The "nonprod-schedule" schedule must already exist in the Instance
#     Scheduler DynamoDB config table (see STEP 0 below)
#
# Usage:
#   chmod +x tag-nonprod-resources.sh
#   ./tag-nonprod-resources.sh
#
# To do a dry-run (echo only, no AWS calls):
#   DRY_RUN=true ./tag-nonprod-resources.sh

set -euo pipefail

ACCOUNT="${ACCOUNT:?Set ACCOUNT to your workload account ID}"
REGION="${REGION:-us-east-1}"
SCHEDULE_TAG_KEY="Schedule"
SCHEDULE_TAG_VALUE="nonprod-schedule"
DRY_RUN="${DRY_RUN:-false}"

# ─── Colour helpers ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
pending() { echo -e "${YELLOW}[DRY]${NC}   $*"; }

tag_rds_instance() {
  local id="$1"
  local arn="arn:aws:rds:${REGION}:${ACCOUNT}:db:${id}"
  if [ "$DRY_RUN" = "true" ]; then
    pending "Would tag RDS instance: $id"
  else
    aws rds add-tags-to-resource \
      --region "$REGION" \
      --resource-name "$arn" \
      --tags "Key=${SCHEDULE_TAG_KEY},Value=${SCHEDULE_TAG_VALUE}"
    info "Tagged RDS instance: $id"
  fi
}

tag_rds_cluster() {
  local id="$1"
  local arn="arn:aws:rds:${REGION}:${ACCOUNT}:cluster:${id}"
  if [ "$DRY_RUN" = "true" ]; then
    pending "Would tag cluster: $id"
  else
    aws rds add-tags-to-resource \
      --region "$REGION" \
      --resource-name "$arn" \
      --tags "Key=${SCHEDULE_TAG_KEY},Value=${SCHEDULE_TAG_VALUE}"
    info "Tagged cluster: $id"
  fi
}

# ─── STEP 0 — Create the schedule in DynamoDB (run once) ─────────────────────
# The Instance Scheduler CLI must be installed:
#   pip install instance-scheduler-cli
#
# Replace <STACK_NAME> with your hub CloudFormation stack name, e.g. instance-scheduler
#
# scheduler-cli create-period \
#   --stack <STACK_NAME> \
#   --region <your-region> \
#   --name nonprod-hours \
#   --begintime 07:00 \
#   --endtime 23:00 \
#   --weekdays mon-fri
#
# scheduler-cli create-schedule \
#   --stack <STACK_NAME> \
#   --region <your-region> \
#   --name nonprod-schedule \
#   --periods nonprod-hours \
#   --timezone <your-timezone>
#
# After running the above, proceed with tagging below.
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Tagging non-prod resources with ${SCHEDULE_TAG_KEY}=${SCHEDULE_TAG_VALUE}"
echo "Account : ${ACCOUNT} | Region : ${REGION} | Dry-run : ${DRY_RUN}"
echo ""

# ─── RDS Instances ────────────────────────────────────────────────────────────
# Replace these placeholder identifiers with your own RDS instance names.
echo "--- RDS Instances ---"
tag_rds_instance "web-app-stage"
tag_rds_instance "internal-api-stage"
tag_rds_instance "user-service-stage"
tag_rds_instance "billing-service-stage"
tag_rds_instance "analytics-docdb"
tag_rds_instance "admin-portal-stage"
tag_rds_instance "payments-service-stage"
tag_rds_instance "notification-service-stage"

# ─── Aurora / DocDB Clusters ──────────────────────────────────────────────────
# Replace these placeholder identifiers with your own cluster names.
echo ""
echo "--- Aurora / DocDB Clusters ---"
tag_rds_cluster "user-service-stage-cluster"
tag_rds_cluster "billing-service-stage-cluster"
tag_rds_cluster "analytics-docdb"
tag_rds_cluster "admin-portal-stage-cluster"
tag_rds_cluster "payments-service-stage"

echo ""
info "Done. Verify tags in the AWS Console: RDS → select resource → Tags tab."
echo ""
echo "NOTE: Instance Scheduler polls every 5 minutes. The first stop will"
echo "occur at the next scheduled stop time on the next weekday the rule fires."
