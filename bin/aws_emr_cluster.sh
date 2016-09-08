#!/usr/bin/env bash

# Start a EMR cluster in AWS for a Spark job.
#   Non-interactive jobs will run the steps and then quit.
#   Interactive jobs will run the steps and then wait for additional work.
# Checkout the copy_env.sh script to have files ready in S3 for the EMR cluster.

set -e

# === Command line args ===

show_usage_and_exit() {
    set +x
    echo "Usage: $0 [-i] <bucket_name> [<environment>]"
    exit ${1-0}
}

CLUSTER_IS_INTERACTIVE=no
while getopts ":hi" opt; do
  case $opt in
    h)
      show_usage_and_exit
      ;;
    i)
      CLUSTER_IS_INTERACTIVE=yes
      shift
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

if [[ $# -lt 1 || $# -gt 2 ]]; then
    show_usage_and_exit 1
fi

set -x

# === Basic cluster configuration ===

CLUSTER_BUCKET="$1"
CLUSTER_ENVIRONMENT="${2-$USER}"

# FIXME Remove harrys reference? Use config?
SSH_KEY_PAIR_FILE="$HOME/.ssh/harrys-dw-cluster-key.pem"

# === Derived cluster configuration ===

CLUSTER_LOGS="s3://$CLUSTER_BUCKET/$CLUSTER_ENVIRONMENT/logs/"
CLUSTER_NAME="ETL Cluster ($CLUSTER_ENVIRONMENT) `date +'%Y-%m-%d %H:%M'`"
CLUSTER_RELEASE_LABEL="emr-5.0.0"
CLUSTER_APPLICATIONS='[{"Name":"Spark"},{"Name":"Ganglia"},{"Name":"Zeppelin"},{"Name":"Sqoop"}]'
CLUSTER_REGION="us-east-1"

if [ "$CLUSTER_IS_INTERACTIVE" = "yes" ]; then
    CLUSTER_TERMINATE="--no-auto-terminate"
    CLUSTER_TERMINATION_PROTECTION="--termination-protected"
else
    CLUSTER_TERMINATE="--auto-terminate"
    CLUSTER_TERMINATION_PROTECTION="--no-termination-protected"
fi

if [ "$CLUSTER_ENVIRONMENT" = "production" ]; then
    CLUSTER_TAGS="EMR_SPARK_ETL_TYPE=production"
elif [ "$CLUSTER_IS_INTERACTIVE" = "yes" ]; then
    CLUSTER_TAGS="EMR_SPARK_ETL_TYPE=interactive"
else
    CLUSTER_TAGS="EMR_SPARK_ETL_TYPE=development"
fi

# === Validate bucket and environment information (sanity check on args) ===

BOOTSTRAP="s3://$CLUSTER_BUCKET/$CLUSTER_ENVIRONMENT/bootstrap/bootstrap.sh"
if ! aws s3 ls "$BOOTSTRAP" > /dev/null; then
    echo "Failed to find $BOOTSTRAP -- did you initialize the folder \"$CLUSTER_ENVIRONMENT\"?"
    exit 2
fi

# === Fill in config templates ===

# FIXME Allow users to set top dir (when virtual env is not adjacent to bin, config, etc.)
BINDIR=`dirname $0`
TOPDIR=`\cd $BINDIR/.. && \pwd`
CLUSTER_CONFIG_SOURCE="$TOPDIR/aws_config"

CLUSTER_CONFIG_DIR="/tmp/cluster_config_${USER}_${CLUSTER_ENVIRONMENT}_$$"
if [[ -d "$CLUSTER_CONFIG_DIR" ]]; then
    rm -f "$CLUSTER_CONFIG_DIR"/*
else
    mkdir "$CLUSTER_CONFIG_DIR"
fi

# TODO Find a better way to parameterize cluster, check out cloud formation?

for JSON_FILE in application_env.json bootstrap_actions.json steps.json; do
    sed -e "s,#{bucket_name},$CLUSTER_BUCKET,g" \
        -e "s,#{etl_environment},$CLUSTER_ENVIRONMENT,g" \
        "$CLUSTER_CONFIG_SOURCE/$JSON_FILE" > "$CLUSTER_CONFIG_DIR/$JSON_FILE"
done

# ===  Start cluster ===

CLUSTER_ID_FILE="$CLUSTER_CONFIG_DIR/cluster_id.json"

aws emr create-cluster \
        --name "$CLUSTER_NAME" \
        --release-label "$CLUSTER_RELEASE_LABEL" \
        --applications "$CLUSTER_APPLICATIONS" \
        --tags "$CLUSTER_TAGS" \
        --log-uri "$CLUSTER_LOGS" \
        --region "$CLUSTER_REGION" \
        --instance-groups "file://$CLUSTER_CONFIG_SOURCE/instance_groups.json" \
        --use-default-roles \
        --configurations "file://$CLUSTER_CONFIG_DIR/application_env.json" \
        --ec2-attributes "file://$CLUSTER_CONFIG_SOURCE/ec2_attributes.json" \
        --bootstrap-actions "file://$CLUSTER_CONFIG_DIR/bootstrap_actions.json" \
        $CLUSTER_TERMINATE \
        $CLUSTER_TERMINATION_PROTECTION \
        | tee "$CLUSTER_ID_FILE"
CLUSTER_ID=`jq --raw-output < "$CLUSTER_ID_FILE" '.ClusterId'`
sleep 1

if [ "$CLUSTER_IS_INTERACTIVE" = "yes" ]; then
    aws emr wait cluster-running --cluster-id "$CLUSTER_ID"
    say "Your cluster is now running. All functions appear normal." || echo "Your cluster is now running. All functions appear normal."
    aws emr socks --cluster-id "$CLUSTER_ID" --key-pair-file "$SSH_KEY_PAIR_FILE"
else
    aws emr add-steps \
        --cluster-id "$CLUSTER_ID" \
        --steps "file://$CLUSTER_CONFIG_DIR/steps.json"
    echo "If you need to proxy into the cluster, use:"
    echo aws emr socks --cluster-id "$CLUSTER_ID" --key-pair-file "$SSH_KEY_PAIR_FILE"
fi

aws emr describe-cluster --cluster-id "$CLUSTER_ID" | \
    jq '.Cluster.Status | {"State": .State}, .Timeline, .StateChangeReason | if has("CreationDateTime") then map_values(todate) else . end'
