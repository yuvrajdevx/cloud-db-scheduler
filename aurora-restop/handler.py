"""
Aurora / DocDB 7-day re-stop Lambda
------------------------------------
AWS automatically restarts stopped Aurora and DocumentDB clusters after 7 days.
This Lambda fires weekly via EventBridge (scheduled to run shortly before the
next working day's start window) and re-stops any cluster that AWS has
auto-restarted in the meantime.

Supported engines : aurora, aurora-mysql, aurora-postgresql, docdb
Target account    : configured via the TARGET_ACCOUNT_ID environment variable
Region            : configured via the AWS_REGION environment variable

Override: set tag  Schedule=always  on a cluster to exempt it from re-stopping.
"""

import boto3
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TARGET_ACCOUNT_ID = os.environ["TARGET_ACCOUNT_ID"]
TARGET_ROLE_NAME  = os.environ.get("TARGET_ROLE_NAME", "instance-scheduler-target-role")
SNS_TOPIC_ARN     = os.environ.get("SNS_TOPIC_ARN", "")
REGION            = os.environ.get("AWS_REGION", "us-east-1")

AURORA_ENGINES = {"aurora", "aurora-mysql", "aurora-postgresql", "docdb"}

OVERRIDE_TAG_KEY   = "Schedule"
OVERRIDE_TAG_VALUE = "always"


def assume_role(account_id: str, role_name: str) -> dict:
    """Assume a cross-account IAM role and return temporary credentials."""
    sts = boto3.client("sts")
    response = sts.assume_role(
        RoleArn=f"arn:aws:iam::{account_id}:role/{role_name}",
        RoleSessionName="aurora-restop-session",
    )
    return response["Credentials"]


def get_rds_client(credentials: dict) -> boto3.client:
    """Return an RDS boto3 client using assumed role credentials."""
    return boto3.client(
        "rds",
        region_name=REGION,
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
    )


def publish_failure(subject: str, detail: str) -> None:
    """Publish a structured failure alert to SNS (best-effort — never raises)."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set — skipping alert publish")
        return
    try:
        sns = boto3.client("sns", region_name=REGION)
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=json.dumps({"subject": subject, "detail": detail}, indent=2),
        )
        logger.info(f"SNS alert published: {subject}")
    except Exception as e:
        logger.error(f"Failed to publish SNS alert: {e}")


def has_override_tag(cluster: dict) -> bool:
    """Return True if the cluster has Schedule=always tag."""
    for tag in cluster.get("TagList", []):
        if tag["Key"] == OVERRIDE_TAG_KEY and tag["Value"] == OVERRIDE_TAG_VALUE:
            return True
    return False


def handler(event, context):
    """
    Main Lambda handler.
    Loops through all Aurora/DocDB clusters in the target account.
    Stops any cluster in 'available' state that does not have an override tag.
    """
    logger.info(f"Aurora re-stop triggered. Target account: {TARGET_ACCOUNT_ID}")

    try:
        credentials = assume_role(TARGET_ACCOUNT_ID, TARGET_ROLE_NAME)
        logger.info(f"Assumed role in account {TARGET_ACCOUNT_ID}")
    except Exception as e:
        msg = f"Failed to assume role {TARGET_ROLE_NAME} in account {TARGET_ACCOUNT_ID}: {e}"
        logger.error(msg)
        publish_failure("aurora-restop: role assumption failed", msg)
        raise

    rds = get_rds_client(credentials)

    try:
        paginator = rds.get_paginator("describe_db_clusters")
        clusters = []
        for page in paginator.paginate():
            clusters.extend(page["DBClusters"])
    except Exception as e:
        msg = f"Failed to describe DB clusters: {e}"
        logger.error(msg)
        publish_failure("aurora-restop: describe_db_clusters failed", msg)
        raise

    logger.info(
        f"Found {len(clusters)} clusters in account {TARGET_ACCOUNT_ID} — "
        f"checking for available Aurora/DocDB clusters to re-stop"
    )

    stopped = []
    skipped = []
    errors  = []

    for cluster in clusters:
        cluster_id = cluster["DBClusterIdentifier"]
        engine     = cluster["Engine"]
        status     = cluster["Status"]

        if engine not in AURORA_ENGINES:
            continue

        if status != "available":
            logger.info(f"  {cluster_id}: status={status} — skipping")
            continue

        if has_override_tag(cluster):
            logger.info(f"  {cluster_id}: override tag Schedule=always — skipping")
            skipped.append(cluster_id)
            continue

        try:
            rds.stop_db_cluster(DBClusterIdentifier=cluster_id)
            logger.info(f"  {cluster_id}: stopped (engine={engine})")
            stopped.append(cluster_id)
        except Exception as e:
            logger.error(f"  {cluster_id}: stop failed — {e}")
            errors.append({"cluster": cluster_id, "error": str(e)})

    logger.info(
        f"Done. stopped={stopped} | skipped(override)={skipped} | errors={errors}"
    )

    if errors:
        detail = f"Clusters that failed to stop: {errors}"
        publish_failure("aurora-restop: one or more clusters failed to stop", detail)
        raise Exception(detail)

    return {"stopped": stopped, "skipped": skipped, "errors": errors}
