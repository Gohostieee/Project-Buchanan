#!/usr/bin/env bash
set -Eeuo pipefail

required=(
  AWS_DEFAULT_REGION
  GIT_SHA
  ECR_REPOSITORY_URI
  INSTANCE_ID
  PUBLIC_IP
  SOURCE_BUCKET_NAME
  BYOND_ARCHIVE_KEY
  LIVE_SHA_PARAMETER
)

for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || {
    echo "Required environment variable is missing: $name" >&2
    exit 64
  }
done

[[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || {
  echo "GIT_SHA must be a full lowercase Git commit SHA." >&2
  exit 64
}
[[ "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] || exit 64
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 64
GAME_PORT="${GAME_PORT:-54321}"
[[ "$GAME_PORT" =~ ^[0-9]{1,5}$ ]] && ((GAME_PORT >= 1 && GAME_PORT <= 65535)) || exit 64
[[ "$(git rev-parse HEAD)" == "$GIT_SHA" ]] || {
  echo 'Checked-out source does not match GIT_SHA.' >&2
  exit 65
}

registry="${ECR_REPOSITORY_URI%%/*}"
image_uri="${ECR_REPOSITORY_URI}:${GIT_SHA}"

mkdir -p docker/vendor
aws s3 cp \
  "s3://${SOURCE_BUCKET_NAME}/${BYOND_ARCHIVE_KEY}" \
  docker/vendor/516.1688_byond_linux.zip \
  --only-show-errors
echo '16278f318cdeb4b77c57868dd7135032fde717ea6226269d22b2a1a50968e7f9  docker/vendor/516.1688_byond_linux.zip' \
  | sha256sum -c -

aws ecr get-login-password --region "$AWS_DEFAULT_REGION" \
  | docker login --username AWS --password-stdin "$registry"

# Reuse an already-built immutable image when retrying a failed rollout.
if aws ecr describe-images --repository-name "${ECR_REPOSITORY_URI#*/}" \
    --image-ids "imageTag=$GIT_SHA" >/dev/null 2>&1; then
  echo "Reusing $image_uri"
else
  docker build --pull --platform linux/amd64 --tag "$image_uri" .
  docker push "$image_uri"
fi

# Send the repository's guarded handoff script without storing deploy scripts
# or source-control credentials on the game host.
rollout_base64=$(base64 -w0 deploy/aws/rollout-ec2.sh)
remote_script=$(cat <<EOF
set -euo pipefail
work_dir=\$(mktemp -d /var/tmp/reno-rollout.XXXXXX)
trap 'rm -rf "\$work_dir"' EXIT
printf '%s' '$rollout_base64' | base64 -d > "\$work_dir/rollout-ec2.sh"
chmod 0755 "\$work_dir/rollout-ec2.sh"
"\$work_dir/rollout-ec2.sh" --image-uri '$image_uri' --public-ip '$PUBLIC_IP' --port '$GAME_PORT'
EOF
)
parameters=$(jq -cn --arg command "$remote_script" \
  '{commands: [$command], executionTimeout: ["3600"]}')

command_id=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "Deploy Reno ${GIT_SHA}" \
  --parameters "$parameters" \
  --timeout-seconds 3600 \
  --query 'Command.CommandId' \
  --output text)

status='Pending'
for _ in $(seq 1 240); do
  status=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" \
    --query Status \
    --output text 2>/dev/null || true)
  case "$status" in
    Success)
      break
      ;;
    Failed|Cancelled|TimedOut|Cancelling)
      aws ssm get-command-invocation \
        --command-id "$command_id" \
        --instance-id "$INSTANCE_ID" || true
      exit 1
      ;;
  esac
  sleep 15
done

[[ "$status" == Success ]] || {
  echo "Deployment command did not finish successfully: $status" >&2
  exit 1
}
aws ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent \
  --output text

# A public TCP check is the strongest AWS-side verification available. BYOND's
# authenticated Dream Seeker handshake must still come from a real player
# client and is intentionally not emulated with stored user credentials.
reachable=0
for _ in $(seq 1 12); do
  if timeout 5 bash -c "</dev/tcp/${PUBLIC_IP}/${GAME_PORT}"; then
    reachable=1
    break
  fi
  sleep 10
done
[[ "$reachable" == 1 ]] || {
  echo "The deployed server is not publicly reachable on TCP $GAME_PORT." >&2
  exit 1
}

aws ssm put-parameter \
  --name "$LIVE_SHA_PARAMETER" \
  --type String \
  --value "$GIT_SHA" \
  --overwrite >/dev/null

echo "Deployed ${GIT_SHA}; BYOND client reconnect remains the hub activation step."
