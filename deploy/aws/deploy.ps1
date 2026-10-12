[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VpcId,
    [Parameter(Mandatory)][string]$SubnetId,
    [Parameter(Mandatory)][string]$AvailabilityZone,
    [string]$Region = 'us-east-1',
    [string]$StackName = 'reno-ec2',
    [string]$InstanceType = 'c6a.large',
    [string]$AllowedClientCidr = '0.0.0.0/0',
    [ValidateRange(1, 65535)][int]$GamePort = 54321,
    [string]$GitRemote = 'fork',
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''
$env:AWS_CLI_OUTPUT_ENCODING = 'UTF-8'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location -LiteralPath $repoRoot

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    $result = & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
    return $result
}
function Invoke-Aws {
    param([string[]]$Arguments)
    Invoke-Checked aws ($Arguments + @('--region', $Region, '--output', 'json'))
}
function Invoke-AwsOptional {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $result = & aws @Arguments --region $Region --output json 2>$null
    if ($LASTEXITCODE -eq 0) { return ($result | ConvertFrom-Json) }
    return $null
}
function Get-StackOutputs {
    param([string]$Name)
    $stack = (Invoke-Aws @('cloudformation', 'describe-stacks', '--stack-name', $Name) | ConvertFrom-Json).Stacks[0]
    $values = @{}
    foreach ($item in $stack.Outputs) { $values[$item.OutputKey] = $item.OutputValue }
    return $values
}
function Deploy-Stack {
    param([string]$Name, [string]$Template, [string[]]$Parameters)
    Invoke-Checked aws (@('cloudformation', 'deploy', '--stack-name', $Name,
        '--template-file', $Template, '--capabilities', 'CAPABILITY_IAM',
        '--no-fail-on-empty-changeset', '--region', $Region, '--parameter-overrides') + $Parameters) | Out-Host
}

Invoke-Aws @('sts', 'get-caller-identity') | Out-Null
$branch = (Invoke-Checked git @('branch', '--show-current')).Trim()
$sha = (Invoke-Checked git @('rev-parse', 'HEAD')).Trim()
if (!$branch -or (Invoke-Checked git @('status', '--porcelain'))) {
    throw 'Deploy from a clean, committed branch so the source archive and automatic deployments match.'
}
$repoUrl = (Invoke-Checked git @('remote', 'get-url', $GitRemote)).Trim()
if ($repoUrl -notmatch 'github\.com[:/](?<Owner>[A-Za-z0-9_.-]+)/(?<Repo>[A-Za-z0-9_.-]+?)(?:\.git)?$') {
    throw 'GitRemote must point to the public GitHub repository used for automatic deployments.'
}
$owner = $Matches.Owner
$repository = $Matches.Repo
$github = Invoke-Checked gh @('api', "repos/$owner/$repository") | ConvertFrom-Json
if ($github.private) { throw 'AWS-native source polling requires a public repository.' }
$oidcSubject = Invoke-Checked gh @('api', "repos/$owner/$repository/actions/oidc/customization/sub") | ConvertFrom-Json
if (!$oidcSubject.use_immutable_subject) {
    throw 'This OIDC template requires immutable GitHub subject claims. Enable them before deployment.'
}
if ($Publish) { Invoke-Checked git @('push', '-u', $GitRemote, $branch) | Out-Host }
$remoteHead = Invoke-Checked git @('ls-remote', $GitRemote, "refs/heads/$branch")
if (!$remoteHead -or ($remoteHead -split '\s+')[0] -ne $sha) {
    throw 'The remote branch must match HEAD. Use -Publish to publish this deployment branch.'
}

$archiveName = '516.1688_byond_linux.zip'
$archiveHash = '16278f318cdeb4b77c57868dd7135032fde717ea6226269d22b2a1a50968e7f9'
$vendor = Join-Path $repoRoot "docker/vendor/$archiveName"
New-Item -ItemType Directory -Force (Split-Path $vendor), (Join-Path $repoRoot 'build') | Out-Null
if (!(Test-Path -LiteralPath $vendor)) {
    Invoke-WebRequest "https://www.byond.com/download/build/516/$archiveName" -OutFile $vendor
}
if ((Get-FileHash -LiteralPath $vendor -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash) {
    throw 'The BYOND archive does not match the pinned SHA-256 digest.'
}
$sourceArchive = Join-Path $repoRoot 'build/reno-source.tar.gz'
Invoke-Checked git @('archive', '--format=tar.gz', "--output=$sourceArchive", $sha) | Out-Null

# Create the private bucket before uploading inputs. Host bootstrap waits for them.
$parameters = @("VpcId=$VpcId", "SubnetId=$SubnetId", "AvailabilityZone=$AvailabilityZone",
    "InstanceType=$InstanceType", "AllowedClientCidr=$AllowedClientCidr", "GamePort=$GamePort")
$stackExists = Invoke-AwsOptional @('cloudformation', 'describe-stacks', '--stack-name', $StackName)
$createdNow = !$stackExists
if ($stackExists) {
    Deploy-Stack $StackName 'deploy/aws/ec2-server.yml' $parameters
} else {
    Invoke-Checked aws (@('cloudformation', 'create-stack', '--stack-name', $StackName,
        '--template-body', 'file://deploy/aws/ec2-server.yml', '--capabilities', 'CAPABILITY_IAM',
        '--region', $Region, '--parameters') + ($parameters | ForEach-Object {
            $key, $value = $_ -split '=', 2
            "ParameterKey=$key,ParameterValue=$value"
        })) | Out-Host
}
$bucket = $null
for ($attempt = 0; $attempt -lt 90; $attempt++) {
    $bucketResource = Invoke-AwsOptional @('cloudformation', 'describe-stack-resource', '--stack-name', $StackName, '--logical-resource-id', 'SourceBucket')
    $bucket = $bucketResource.StackResourceDetail.PhysicalResourceId
    if ($bucket) { break }
    Start-Sleep -Seconds 5
}
if (!$bucket) { throw 'The private source bucket was not created.' }
Invoke-Checked aws @('s3', 'cp', $sourceArchive, "s3://$bucket/source/reno-source.tar.gz", '--region', $Region, '--only-show-errors') | Out-Null
Invoke-Checked aws @('s3', 'cp', $vendor, "s3://$bucket/source/dependencies/$archiveName", '--region', $Region, '--only-show-errors') | Out-Null
if ($createdNow) { Invoke-Checked aws @('cloudformation', 'wait', 'stack-create-complete', '--stack-name', $StackName, '--region', $Region) | Out-Null }
$hostOutputs = Get-StackOutputs $StackName

# CloudFormation resource completion does not imply that the game finished booting.
$readyScript = @'
set -e
for attempt in $(seq 1 180); do
  status=$(cat /var/lib/reno/bootstrap.status 2>/dev/null || true)
  if [ "$status" = RUNNING ]; then
    docker inspect --format '{{.State.Status}} {{.State.Health.Status}}' reno
    exit 0
  fi
  if [ "$status" = FAILED ]; then tail -n 80 /var/log/reno-bootstrap.log; exit 1; fi
  sleep 10
done
echo 'Bootstrap readiness timed out'; exit 1
'@
$readyFile = Join-Path $repoRoot 'build/readiness.json'
[IO.File]::WriteAllText($readyFile, (@{commands = @($readyScript); executionTimeout = @('1800')} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$command = $null
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $commandResult = Invoke-AwsOptional @('ssm', 'send-command', '--instance-ids', $hostOutputs.InstanceId, '--document-name', 'AWS-RunShellScript', '--parameters', "file://$readyFile", '--timeout-seconds', '1800')
    if ($commandResult) { $command = $commandResult.Command.CommandId; break }
    Start-Sleep -Seconds 10
}
if (!$command) { throw 'The EC2 instance did not register with Systems Manager.' }
for ($attempt = 0; $attempt -lt 190; $attempt++) {
    $invocation = Invoke-AwsOptional @('ssm', 'get-command-invocation', '--command-id', $command, '--instance-id', $hostOutputs.InstanceId)
    if ($invocation) {
        if ($invocation.Status -eq 'Success') { break }
        if ($invocation.Status -in @('Failed', 'Cancelled', 'TimedOut')) { throw $invocation.StandardOutputContent }
    }
    Start-Sleep -Seconds 10
}
if (!$invocation -or $invocation.Status -ne 'Success') { throw 'Host bootstrap did not complete.' }

$providers = (Invoke-Aws @('iam', 'list-open-id-connect-providers') | ConvertFrom-Json).OpenIDConnectProviderList
$existingProvider = ($providers | Where-Object { $_.Arn.EndsWith('/token.actions.githubusercontent.com') } | Select-Object -First 1).Arn
Deploy-Stack 'reno-github-deploy' 'deploy/aws/github-actions-deploy-role.yml' @(
    "GitHubOwner=$owner", "GitHubRepository=$repository", "GitHubOwnerId=$($github.owner.id)",
    "GitHubRepositoryId=$($github.id)", "GitHubBranch=$branch", "InstanceId=$($hostOutputs.InstanceId)",
    "InstanceRoleName=$($hostOutputs.InstanceRoleName)", "ExistingGitHubOidcProviderArn=$existingProvider")
$imageOutputs = Get-StackOutputs 'reno-github-deploy'
$repositoryName = ($imageOutputs.ImageRepositoryUri -split '/', 2)[1]
Deploy-Stack 'reno-automatic-deploy' 'deploy/aws/automatic-deploy.yml' @(
    "GitHubOwner=$owner", "GitHubRepository=$repository", "GitHubBranch=$branch",
    "InstanceId=$($hostOutputs.InstanceId)", "PublicIp=$($hostOutputs.PublicIp)", "GamePort=$GamePort",
    "EcrRepositoryName=$repositoryName", "SourceBucketName=$bucket")
$automaticOutputs = Get-StackOutputs 'reno-automatic-deploy'
Invoke-Checked aws @('lambda', 'invoke', '--function-name', $automaticOutputs.SourceCheckFunctionName,
    '--region', $Region, 'build/source-check.json') | Out-Host
$receipt = @{Region = $Region; StackName = $StackName; Branch = $branch; SourceSha = $sha;
    Host = $hostOutputs; Images = $imageOutputs; Automation = $automaticOutputs}
[IO.File]::WriteAllText((Join-Path $repoRoot 'build/deployment.json'), ($receipt | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Write-Host "Bootstrap is healthy: $($hostOutputs.ByondAddress). AWS-native immutable-image deployment has been started."
Write-Host 'Check CodeBuild and the live-sha parameter before considering the automated rollout verified.'
