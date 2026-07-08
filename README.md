# cloud-db-scheduler

Automated stop/start scheduling for a non-prod AWS database fleet (RDS, Aurora, and DocumentDB), built to eliminate idle spend on databases that only need to be running during working hours.

## Why

Non-production databases (staging, dev, QA) are usually left running 24/7 even though they're only used ~10 hours a day on weekdays. That's roughly 75% wasted compute/storage cost for zero benefit. This project automates the stop/start cycle across a multi-account AWS Organization, with a self-service escape hatch for developers who need a database outside normal hours.

It's built on top of [AWS Instance Scheduler](https://docs.aws.amazon.com/solutions/instance-scheduler-on-aws/) (a supported AWS Solutions CloudFormation template) plus a small custom Lambda to work around a specific AWS Aurora/DocumentDB limitation described below.

## Architecture

Two components work together across a hub-and-spoke AWS account model:

**1. AWS Instance Scheduler (CloudFormation)**
Handles all routine weekday stop/start. Deployed as a "hub" stack in a central/shared account; reaches into the "spoke" (workload) account via a cross-account IAM role.

**2. Custom re-stop Lambda**
AWS automatically restarts stopped Aurora and DocumentDB clusters after 7 days — this is an AWS platform behavior, not something Instance Scheduler can override. The re-stop Lambda runs weekly, finds any cluster that AWS has auto-restarted, and stops it again before the next working day begins.

```
Hub account
├── Instance Scheduler hub stack
│   ├── EventBridge rule → Orchestration Lambda → Scheduling Lambdas
│   └── DynamoDB config + state tables
└── aurora-restop Lambda (weekly EventBridge rule)

Workload account
├── Instance Scheduler spoke stack
│   └── IAM cross-account role (instance-scheduler-target-role)
└── RDS / Aurora / DocumentDB resources (tagged Schedule=nonprod-schedule)
```

### Schedule

| Window            | Days    | Action                                       |
| ------------------ | ------- | --------------------------------------------- |
| 07:00 (local tz)   | Mon–Fri | Start all tagged resources                    |
| 23:00 (local tz)   | Mon–Fri | Stop all tagged resources                     |
| Saturday–Sunday    | —       | Remain stopped                                 |
| Weekly (off-hours) | Weekly  | Re-stop pass (catches 7-day auto-restarts)     |

The timezone is set per-schedule in Instance Scheduler (e.g. `Pacific/Auckland`, `America/New_York`) — it handles daylight saving transitions automatically. Change it in `cloudformation/hub-parameters.json` / the schedule definition to suit your team's working hours.

---

## Repo structure

```
cloud-db-scheduler/
├── aurora-restop/
│   ├── handler.py          # Lambda: re-stops Aurora/DocDB clusters after AWS's 7-day auto-restart
│   ├── requirements.txt    # Local dev dependencies
│   └── deploy.sh           # Deploys IAM role, SNS topic, Lambda, and EventBridge rule via AWS CLI
├── cloudformation/
│   ├── deploy.sh           # Deploys hub stack (shared/hub account) + spoke stack (workload account)
│   ├── hub-parameters.json # Hub stack parameters
│   └── spoke-parameters.json
├── setup/
│   └── create-github-actions-role.sh  # Creates IAM role for on-demand GitHub Actions workflow
├── tagging/
│   └── tag-nonprod-resources.sh       # Tags example resources with Schedule=nonprod-schedule
└── .github/
    └── workflows/
        └── on-demand.yml   # Self-service start/stop for developers
```

---

## Resources managed (example)

The resource identifiers below are placeholder examples — replace them with your own database identifiers in `tagging/tag-nonprod-resources.sh`.

### RDS Instances

| Identifier                |
| -------------------------- |
| `web-app-stage`             |
| `internal-api-stage`        |
| `user-service-stage`        |
| `billing-service-stage`     |
| `analytics-docdb`           |
| `admin-portal-stage`        |
| `payments-service-stage`    |
| `notification-service-stage`|

### Aurora / DocumentDB Clusters

| Identifier                         | Engine        |
| ------------------------------------ | ------------- |
| `user-service-stage-cluster`         | aurora-mysql  |
| `billing-service-stage-cluster`      | aurora-mysql  |
| `analytics-docdb`                    | docdb         |
| `admin-portal-stage-cluster`         | aurora-mysql  |
| `payments-service-stage`             | docdb         |

Any resource that's a shared dependency (e.g. a database used by multiple staging services) should be tagged and scheduled alongside the rest of the fleet so nothing breaks when its dependents shut down.

---

## Deployment

Steps 1–3 require CloudFormation and IAM permissions. Steps 4–5 require only standard AWS power-user access.

### Prerequisites

- AWS CLI installed and configured
- Instance Scheduler CLI: `pip install instance-scheduler-cli`
- Two AWS accounts (or reuse one account for both roles in a smaller setup): a hub/shared account and a workload/non-prod account

### Step 1 — Deploy CloudFormation stacks

Ensure your AWS credentials are active for both accounts. The script uses the profile names `shared-services` and `nonprod` by default — edit the variables at the top of `cloudformation/deploy.sh` to match your local AWS CLI profile names, and set your own account IDs in `hub-parameters.json` / `spoke-parameters.json`.

```bash
./cloudformation/deploy.sh
```

Waits for both stacks to reach `CREATE_COMPLETE` before exiting. Takes ~5 minutes.

> `hub-parameters.json` sets `ScheduleRdsClusters=Yes` to enable Aurora cluster scheduling. If your CloudFormation template version doesn't recognize this parameter, remove it from the file and enable Aurora cluster support via the console after deployment.

### Step 2 — Create the GitHub Actions IAM role

Ensure your AWS credentials are active for the workload account. Edit `GITHUB_ORG` and `REPO_NAME` at the top of the script to match your own GitHub org/repo before running.

```bash
./setup/create-github-actions-role.sh
```

Creates a least-privilege IAM role (via GitHub OIDC — no long-lived AWS keys stored in GitHub) scoped to RDS start/stop/describe.

### Step 3 — Deploy the re-stop Lambda

Ensure your AWS credentials are active for the hub account.

```bash
./aurora-restop/deploy.sh
```

To redeploy only the Lambda code after a change to `handler.py`:

```bash
./aurora-restop/deploy.sh --update-code-only
```

### Step 4 — Create the schedule in DynamoDB

```bash
# Create the time period (e.g. 07:00–23:00, Mon–Fri)
scheduler-cli create-period \
  --stack instance-scheduler \
  --region <your-region> \
  --name nonprod-hours \
  --begintime 07:00 \
  --endtime 23:00 \
  --weekdays mon-fri

# Create the named schedule referencing that period
scheduler-cli create-schedule \
  --stack instance-scheduler \
  --region <your-region> \
  --name nonprod-schedule \
  --periods nonprod-hours \
  --timezone <your-timezone>
```

### Step 5 — Tag all resources

```bash
# Dry run first — prints what would be tagged, no AWS calls
DRY_RUN=true ./tagging/tag-nonprod-resources.sh

# Apply tags
./tagging/tag-nonprod-resources.sh
```

Instance Scheduler polls every 5 minutes. The first scheduled action occurs at the next start/stop boundary you configured.

---

## Day-to-day operations

### Override — keep a resource running outside schedule hours

Set `Schedule=always` on the resource. Instance Scheduler skips it on the next poll; the re-stop Lambda also respects this tag.

```bash
# RDS instance
aws rds add-tags-to-resource \
  --region <your-region> \
  --resource-name arn:aws:rds:<your-region>:<account-id>:db:admin-portal-stage \
  --tags Key=Schedule,Value=always \
  --profile nonprod

# Aurora or DocDB cluster
aws rds add-tags-to-resource \
  --region <your-region> \
  --resource-name arn:aws:rds:<your-region>:<account-id>:cluster:payments-service-stage \
  --tags Key=Schedule,Value=always \
  --profile nonprod
```

To resume the normal schedule, set the tag back to `nonprod-schedule`.

### On-demand start/stop

Developers can start or stop any resource via GitHub Actions without AWS Console access.

1. Go to **Actions** → **On-demand DB start/stop** → **Run workflow**
2. Select `action` (start/stop), `resource_type`, and enter the `resource_id`
3. Click **Run workflow**

The resource is available within 2–5 minutes after a start. A manual start outside schedule hours doesn't persist — Instance Scheduler stops the resource again at the next scheduled stop time unless the `Schedule` tag is also updated to `always`.

### Kill switch — disable all scheduling

**Instance Scheduler (main stop/start):**

```bash
aws cloudformation update-stack \
  --stack-name instance-scheduler \
  --use-previous-template \
  --parameters \
    ParameterKey=SchedulingActive,ParameterValue=No \
    ParameterKey=TagName,UsePreviousValue=true \
    ParameterKey=ScheduledServices,UsePreviousValue=true \
    ParameterKey=ScheduleRdsClusters,UsePreviousValue=true \
    ParameterKey=DefaultTimezone,UsePreviousValue=true \
    ParameterKey=Regions,UsePreviousValue=true \
    ParameterKey=Principals,UsePreviousValue=true \
    ParameterKey=CrossAccountRoles,UsePreviousValue=true \
    ParameterKey=ScheduleLambdaAccount,UsePreviousValue=true \
    ParameterKey=SchedulingIntervalMinutes,UsePreviousValue=true \
    ParameterKey=CreateRdsSnapshot,UsePreviousValue=true \
    ParameterKey=MemorySize,UsePreviousValue=true \
    ParameterKey=Trace,UsePreviousValue=true \
    ParameterKey=LogRetentionDays,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --region <your-region> \
  --profile shared-services
```

All tagged resources remain in their current state. Re-enable by setting `SchedulingActive` back to `Yes`.

**Re-stop Lambda (weekly re-stop):**

```bash
# Disable
aws events disable-rule --name aurora-restop-weekly --region <your-region> --profile shared-services

# Re-enable
aws events enable-rule --name aurora-restop-weekly --region <your-region> --profile shared-services
```

---

## Monitoring

**Instance Scheduler** publishes CloudWatch metrics. Monitor the `SchedulingError` metric in the hub account.

**Re-stop Lambda** publishes structured JSON to the `aurora-restop-alerts` SNS topic on any failure. Errors also appear in CloudWatch Logs under `/aws/lambda/aurora-restop`.

```bash
aws logs tail /aws/lambda/aurora-restop --follow --region <your-region> --profile shared-services
```

---

## Design notes / what this demonstrates

- **Hub-and-spoke, cross-account IAM** — the scheduler assumes a least-privilege role in the target account rather than requiring credentials to be duplicated across accounts.
- **OIDC over static credentials** — the GitHub Actions workflow authenticates via a federated OIDC role, so no long-lived AWS access keys live in GitHub secrets.
- **Working around a platform limitation** — AWS's 7-day forced restart on stopped Aurora/DocumentDB clusters isn't handled by Instance Scheduler, so a small, single-purpose Lambda closes that gap instead of disabling scheduling for those engines entirely.
- **Fail loud, not silent** — the re-stop Lambda publishes structured failure alerts to SNS rather than swallowing errors, so a broken IAM role or an unstoppable cluster surfaces immediately instead of silently costing money.
- **Tag-driven, not hardcoded into scheduler logic** — resources opt in/out via a single `Schedule` tag, so scaling the fleet up or down is a tagging change, not a code change.
- **Self-service escape hatch** — a `workflow_dispatch` GitHub Actions job lets developers start/stop a database on demand without AWS Console access, while the scheduler still reasserts the default schedule afterward.

## Related

- AWS Instance Scheduler: https://docs.aws.amazon.com/solutions/instance-scheduler-on-aws/
