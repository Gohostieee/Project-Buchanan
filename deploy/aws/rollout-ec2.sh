#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 --image-uri account.dkr.ecr.region.amazonaws.com/repository:git-sha --public-ip address [--port 54321]" >&2
  exit 64
}

image_uri=''
public_ip=''
port=54321

while (($#)); do
  case "$1" in
    --image-uri) (($# >= 2)) || usage; image_uri="$2"; shift 2 ;;
    --public-ip) (($# >= 2)) || usage; public_ip="$2"; shift 2 ;;
    --port) (($# >= 2)) || usage; port="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$image_uri" =~ ^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9._/-]+:[0-9a-f]{40}$ ]] || usage
[[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || usage
[[ "$port" =~ ^[0-9]{1,5}$ ]] && ((port >= 1 && port <= 65535)) || usage

exec 9>/var/lock/reno-deploy.lock
flock -n 9 || {
  echo 'Another Reno deployment is already running.' >&2
  exit 75
}

registry="${image_uri%%/*}"
region=$(printf '%s' "$registry" | cut -d. -f4)
candidate="reno-candidate-${image_uri##*:}"
candidate="${candidate:0:32}"
rollback_name="reno-rollback-$(date -u +%Y%m%d%H%M%S)"
old_stopped=0
old_renamed=0
candidate_started=0

rollback() {
  local rc="${1:-$?}"
  trap - ERR INT TERM
  echo "Deployment failed with exit code $rc; restoring the previous container." >&2
  if ((candidate_started)); then
    docker stop --time 10 "$candidate" >/dev/null 2>&1 || true
  fi
  docker rm -f "$candidate" >/dev/null 2>&1 || true
  if ((old_renamed)); then
    docker rename "$rollback_name" reno
    docker start reno
  elif ((old_stopped)); then
    docker start reno
  fi
  exit "$rc"
}

trap rollback ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registry"
docker pull --platform linux/amd64 "$image_uri"

docker inspect reno >/dev/null
[[ "$(docker inspect --format '{{.State.Running}}' reno)" == true ]]
if [[ "$(docker inspect --format '{{.Config.Image}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' reno)" == "$image_uri healthy" ]]; then
  echo 'This immutable image is already running and healthy.'
  exit 0
fi
grep -Eq '^[[:space:]]*HUB([[:space:]]|$)' /srv/reno/config/config.txt

docker rm -f "$candidate" >/dev/null 2>&1 || true
host_name=$(hostname)
docker create \
  --name "$candidate" \
  --restart no \
  --platform linux/amd64 \
  --network host \
  --hostname "$host_name" \
  --add-host "$host_name:$public_ip" \
  --init \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  -e PORT="$port" \
  -e BYOND_TRUSTED=1 \
  -v /srv/reno/config:/opt/reno/config:ro \
  -v /srv/reno/data:/opt/reno/data \
  "$image_uri"

echo 'Candidate image pulled successfully; beginning the short container handoff.'
old_stopped=1
docker stop --time 30 reno
docker rename reno "$rollback_name"
old_renamed=1
candidate_started=1
docker start "$candidate"

deadline=$((SECONDS + 600))
while ((SECONDS < deadline)); do
  state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$candidate")
  case "$state" in
    'running healthy') break ;;
    exited*|dead*)
      docker logs --tail 200 "$candidate" >&2 || true
      false
      ;;
  esac
  sleep 10
done

[[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$candidate")" == healthy ]]
docker update --restart unless-stopped "$candidate" >/dev/null
docker rename "$candidate" reno
candidate_started=0
trap - ERR INT TERM

docker ps -a --filter 'name=^/reno-rollback-' --format '{{.Names}}' \
  | awk -v keep="$rollback_name" '$0 != keep' \
  | xargs -r docker rm -f >/dev/null
docker image prune -f >/dev/null

echo "Deployment ${image_uri##*:} is healthy. Previous container retained as $rollback_name."
