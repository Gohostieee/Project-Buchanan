# Reno on AWS

This deployment adapts Hail Mary's single-host AWS setup to Project Buchanan.
The game is `fortune13.dmb`, built with BYOND **516.1688**, rust-g **3.3.0**,
and the Node version in `dependencies.sh`. Images and EC2 instances use
**linux/amd64**. BYOND and rust-g require 32-bit Linux libraries; do not use
Graviton instances with this image.

## Deployment flow

- `deploy/aws/ec2-server.yml` creates an Amazon Linux 2023 EC2 host, private
  versioned source bucket, Elastic IP, and retained encrypted 100 GiB gp3 volume.
  It builds the first image, mounts configuration and saved data, and runs as
  UID/GID 10001 with no Linux capabilities. Administration uses Systems Manager;
  there is no SSH ingress.
- `deploy/aws/github-actions-deploy-role.yml` creates an immutable ECR image
  repository and a GitHub OIDC role scoped to one repository and branch. It
  grants the game instance read-only access to that repository and can reuse
  the account's existing GitHub OIDC provider.
- `deploy/aws/automatic-deploy.yml` polls the configured public branch every
  five minutes. Lambda starts a serialized CodeBuild build of the exact commit.
  CodeBuild pushes the image to ECR and sends the rollout script through SSM.
  No GitHub token, BYOND login, SSH key, or stored AWS key is required.
- `rollout-ec2.sh` pulls before stopping the existing server. It starts the
  candidate using the same persistent configuration/data and restores the old
  container if the candidate exits or fails its health check. The most recent
  stopped container remains available for rollback.
- The AWS build records `/reno-automatic-deploy/live-sha` only after the
rollout succeeds and the public TCP port responds. Existing immutable images
  are reused when retrying a failed rollout.

The initial bootstrap runs independently of CloudFormation resource creation.
`CREATE_COMPLETE` alone does not prove the game is running. The deployment
command below waits for `/var/lib/reno/bootstrap.status` to report `RUNNING`
and for the Docker health check before installing automatic deployments.
The image's health check requires both the TCP listener and this process's
game-initialization completion log; explicit map-load failures prevent promotion.

## Deploy from Windows

Requirements: Git, GitHub CLI, AWS CLI v2 with an authenticated identity, a
public x86_64 subnet with an Internet Gateway route, and a clean committed
branch in your public GitHub fork. The AWS identity must be allowed to create
CloudFormation, EC2, IAM, EBS, Elastic IP, S3, ECR, Lambda, CodeBuild,
EventBridge, SQS, CloudWatch, and SSM resources.

Run from the repository root:

```powershell
aws sts get-caller-identity
.\deploy\aws\deploy.ps1 `
  -VpcId vpc-REPLACE_ME `
  -SubnetId subnet-REPLACE_ME `
  -AvailabilityZone us-east-1a `
  -Publish
```

The command publishes the current branch to `fork`, verifies its remote SHA,
downloads and verifies the official BYOND archive, archives the committed
source, creates `reno-ec2`, uploads inputs to its private bucket, waits for game
bootstrap, and creates `reno-github-deploy` and `reno-automatic-deploy`. It
starts the first AWS-native rollout and saves resource identifiers in the
ignored `build/deployment.json`. It leaves automatic deployment completion to
CodeBuild; inspect the build and live SHA before reporting that rollout as
verified. Initial provisioning creates continuously running billable resources.

The setup uses the current branch for automatic deployment. The initial
deployment branch is `feat/aws-deployment`; the upstream `main` branch does
not yet contain the deployment files and build fixes. After merging them into
your fork's `main`, update `GitHubBranch=main` in both the OIDC role and the
automatic-deployment stack. Do not enable two rollout schedulers for the same
host.

The default instance is `c6a.large`, matching Hail Mary. `-InstanceType`,
`-GamePort`, `-AllowedClientCidr`, and `-Region` are configurable. The VPC,
subnet, and Availability Zone must agree. The EC2 data volume is tied to that
Availability Zone. The default client CIDR `0.0.0.0/0` allows public BYOND
clients and hub probes on the game port only.

The GitHub role uses the repository's immutable OIDC subject, including its
numeric owner/repository IDs. The setup checks that this is enabled. See
[GitHub's OIDC reference](https://docs.github.com/en/actions/reference/security/oidc).

## Configuration and saved data

Host paths:

```text
/srv/reno/config        reviewed game configuration, mounted read-only
/srv/reno/data          mutable saves, logs, round state
/srv/reno/docker        Docker image/container storage on the retained volume
/var/lib/reno/bootstrap.status
/var/log/reno-bootstrap.log
```

Bootstrap seeds `config.txt` with the existing Fallout: Interstate 80 server
name, tagline, and `HUB`, and copies `config/maps.txt` so Reno remains the
default map. Credentials and administrator lists are not copied into the
runtime image or seeded production configuration. Database integration is
disabled until separately configured. Add reviewed files and administrator
settings on the host through SSM, keep them owned by UID/GID 10001, and restart
the container after changing configuration. BYOND 516.1688 could not read the
read-only configuration mount in the Linux verification. The entrypoint copies
it into a writable private `runtime-config` directory and selects it through
the game's `config-directory` parameter. Host configuration stays protected;
runtime edits to this copy disappear with the container. Existing saves and
host configuration survive image rollouts.
Each container start selects its own timestamped log directory under
`data/logs/container-*` so saved logs cannot produce a false readiness result.

Host networking and a hostname-to-Elastic-IP mapping are intentional: they
allow DreamDaemon to advertise a public address. Internal and external game
ports match. TCP reachability and a healthy container verify the AWS server
path. A real Dream Seeker login and in-game UI test are separate checks;
automated deployment does not authenticate as a player or prove hub listing.

## Check or trigger a deployment

```powershell
aws cloudformation describe-stacks --stack-name reno-ec2 --query 'Stacks[0].Outputs'
aws cloudformation describe-stacks --stack-name reno-automatic-deploy --query 'Stacks[0].Outputs'
aws codebuild list-builds-for-project --project-name BUILD_PROJECT_FROM_OUTPUT
aws codebuild batch-get-builds --ids BUILD_ID
aws ssm get-parameter --name /reno-automatic-deploy/live-sha
aws lambda invoke --function-name reno-automatic-deploy-source-check build/source-check.json
```

Use `aws ssm start-session --target INSTANCE_ID` for administration (the local
Session Manager plugin is required), or SSM Run Command. Useful host commands:

```bash
cat /var/lib/reno/bootstrap.status
docker ps -a --filter name=reno
docker logs --tail 200 reno
docker inspect --format '{{.State.Status}} {{.State.Health.Status}}' reno
```

Build logs are under `/aws/codebuild/reno-automatic-deploy`; source-check logs
are under `/aws/lambda/reno-automatic-deploy-source-check`. Scheduled invocation
failures go to the deployment stack's encrypted dead-letter queue. Failed
builds leave the live SHA unchanged and are retried on a later source check.
See [SSM command statuses](https://docs.aws.amazon.com/systems-manager/latest/userguide/monitor-commands.html)
when diagnosing an invocation that has not completed.

## Optional GitHub Actions rollouts

AWS-native automation is the deployed default. `.github/workflows/deploy_ec2.yml`
only runs its deployment job when `AWS_DEPLOY_MODE=github` is set. Before
switching, disable the `reno-automatic-deploy-source-check` EventBridge rule.
Set repository variables `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `AWS_INSTANCE_ID`,
`AWS_ECR_REPOSITORY_URI`, `AWS_PUBLIC_IP`, and optional `AWS_GAME_PORT` from stack
outputs. The role's allowed branch must match the workflow's branch (`main`
after the deployment branch is merged). No AWS access keys are needed.

`docker_publish.yml` builds PR images and publishes branch/tag images to GHCR.
It is separate from the production rollout. `buildspec.yml` is an optional
standalone CodeBuild-to-ECR build; set `BYOND_ARCHIVE_S3_URI` and grant access
to that one pinned archive. The deployed automatic pipeline uses the buildspec
embedded in `automatic-deploy.yml` instead.

## Local container verification

Stage the official BYOND archive at `docker/vendor/516.1688_byond_linux.zip`.
Its verified SHA-256 is:

```text
16278f318cdeb4b77c57868dd7135032fde717ea6226269d22b2a1a50968e7f9
```

```powershell
docker compose config --quiet
docker compose build
docker compose up -d --no-build
docker compose logs --tail 100 server
```

Local Compose mounts your local `config` folder, rather than production's
minimal reviewed configuration, and keeps saves in its own named volume.
`tools/deploy.sh` verifies UI bundles and includes the committed font files
at the paths the game's asset loader expects.

## Rollback and teardown

Stop automatic deployments before manually rolling back, or the poller will
redeploy the configured branch. On the host, identify the retained
`reno-rollback-TIMESTAMP` container and restore it:

```bash
docker stop --time 30 reno
docker rename reno reno-replaced
docker rename reno-rollback-TIMESTAMP reno
docker start reno
```

Shared saved data is not rolled back with the image. Take an EBS snapshot
before deploying changes that migrate persistent data. A container rollback
does not reverse data migrations.

To remove the deployment, delete `reno-automatic-deploy`, then
`reno-github-deploy`, then `reno-ec2`. The ECR repository, source bucket, data
volume, and log groups are retained; they continue to consume storage until
you explicitly clean them up. Save their output identifiers before deleting
the stacks. The EC2 instance and Elastic IP are removed with the host stack.
