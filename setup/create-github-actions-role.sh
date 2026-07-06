#!/bin/bash
# setup/create-github-actions-role.sh
#
# Creates the github-actions-db-scheduler IAM role in the workload/non-prod
# account. This role is assumed by the on-demand.yml GitHub Actions workflow
# to start/stop databases without AWS Console access.
#
# Prerequisites:
#   - AWS CLI configured with credentials for the workload account
#   - GitHub OIDC provider must already exist in the account
#     (check: IAM → Identity Providers → token.actions.githubusercontent.com)
#     If it doesn't exist, the script will create it.
#
# Usage:
#   AWS_PROFILE=nonprod ./setup/create-github-actions-role.sh
#
# You only need to run this once.

set -euo pipefail

NONPROD_ACCOUNT="${NONPROD_ACCOUNT:?Set NONPROD_ACCOUNT to your workload account ID}"
REGION="${REGION:-us-east-1}"
ROLE_NAME="github-actions-db-scheduler"
GITHUB_ORG="your-github-org"          # your GitHub org
REPO_NAME="cloud-db-scheduler"        # this repo

AWS_ARGS=""
if [ -n "${AWS_PROFILE:-}" ]; then
  AWS_ARGS="--profile $AWS_PROFILE"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "\n${YELLOW}───────────────────────────────────────${NC}"; echo -e "${YELLOW}$*${NC}"; }

# ─── Verify account ───────────────────────────────────────────────────────────
ACTIVE_ACCOUNT=$(aws sts get-caller-identity --query Account --output text $AWS_ARGS)
if [ "$ACTIVE_ACCOUNT" != "$NONPROD_ACCOUNT" ]; then
  echo "ERROR: Active AWS account is $ACTIVE_ACCOUNT, expected $NONPROD_ACCOUNT (workload account)."
  echo "Set AWS_PROFILE or export credentials for the workload account before running."
  exit 1
fi
info "Account verified: $ACTIVE_ACCOUNT (workload account)"

# ─── Step 1: Ensure GitHub OIDC provider exists ───────────────────────────────
step "Step 1/3 — GitHub OIDC provider"
OIDC_URL="https://token.actions.githubusercontent.com"
EXISTING_OIDC=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text $AWS_ARGS)

if [ -z "$EXISTING_OIDC" ]; then
  info "Creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "1c58a3a8518e8759bf075b76b750d4f2df264fcd" \
    $AWS_ARGS > /dev/null
  info "OIDC provider created"
else
  info "OIDC provider already exists: $EXISTING_OIDC"
fi

# ─── Step 2: Create IAM role with OIDC trust policy ──────────────────────────
step "Step 2/3 — Creating IAM role"
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${NONPROD_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${REPO_NAME}:*"
        }
      }
    }
  ]
}
EOF
)

CREATE_OUT=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --description "Assumed by GitHub Actions on-demand DB start/stop workflow." \
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

# ─── Step 3: Attach least-privilege policy ───────────────────────────────────
step "Step 3/3 — Attaching policy"
INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:StartDBInstance",
        "rds:StopDBInstance",
        "rds:StartDBCluster",
        "rds:StopDBCluster",
        "rds:DescribeDBInstances",
        "rds:DescribeDBClusters"
      ],
      "Resource": "*"
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
info "Policy attached"

step "Done"
echo ""
echo "  Role ARN : $ROLE_ARN"
echo ""
info "The on-demand.yml GitHub Actions workflow is now ready to use."
info "Verify the org/repo values at the top of this script match your repository."
