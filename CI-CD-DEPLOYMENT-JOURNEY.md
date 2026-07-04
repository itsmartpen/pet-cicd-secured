# CI/CD Pipeline & ECS Deployment — End-to-End Documentation

This document walks through the PetClinic CI/CD pipeline as implemented in
[`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml), and records the real issues
hit while getting a build all the way to a browsable ECS deployment, how each was diagnosed,
and how it was fixed.

## 1. Pipeline overview

The pipeline runs on every push to `dev` and PRs into `main`, as a chain of dependent jobs:

| Job | Purpose |
|---|---|
| `gitleaks` | Scans git history for committed secrets before anything else runs |
| `build` | Compiles the app with Maven, uploads the jar as a build artifact |
| `test` | Runs unit tests, uploads surefire reports |
| `sonarQube-scan` | Static analysis + quality gate check against SonarCloud |
| `trivy-scan` | Filesystem/dependency vulnerability scan (CRITICAL/HIGH, non-blocking) |
| `publish` | Fetches JFrog creds from Vault, uploads the jar to Artifactory |
| `docker-build-push` | Builds the Docker image, pushes `<sha>` and `latest` tags to ECR |
| `docker-image-scan` | Trivy scan of the *pushed image* in ECR |
| `deploy-ecs` | Forces a new ECS deployment to roll out the new image |

Credentials (Sonar, Vault/JFrog, AWS role, ECR/ECS names) are all injected via GitHub Actions
secrets/vars — nothing sensitive is hardcoded in the workflow.

## 2. Issues encountered, in chronological order

### 2.1 Trivy ECR image scan — malformed image reference

**Symptom:**
```
FATAL  Fatal error  run error: image scan error: ... could not parse reference: 
140102337343.dkr.ecr.***.amazonaws.com/\
***:90922c1e4d7998ab53ed6b9a5057e5709d3d8c30
```

**Root cause:** [`ci-cd.yml`](.github/workflows/ci-cd.yml) built the `image-ref` input using a
YAML literal block scalar (`|`) with a trailing shell-style `\` line continuation:
```yaml
image-ref: |
  ${{ steps.login-ecr.outputs.registry }}/\
  ${{ env.ECR_REPOSITORY }}:${{ github.sha }}
```
YAML's `|` block preserves newlines *literally* — it doesn't do shell line-continuation. The
resulting string contained a real backslash and a real newline instead of being concatenated,
so Trivy couldn't parse it as an image reference at all.

**Fix:** Collapse it to a single-line plain scalar:
```yaml
image-ref: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ github.sha }}
```

### 2.2 `deploy-ecs` job — IAM AccessDenied

**Symptom:**
```
AccessDeniedException: User: .../GitHubActions-PetClinic-ECR-Role is not authorized 
to perform: ecs:UpdateService
```

**Root cause:** The IAM role assumed by GitHub Actions (`GitHubActions-PetClinic-ECR-Role`)
was scoped for ECR push/pull only — it was never granted ECS deployment permissions when the
`deploy-ecs` job was added.

**Fix:** Attach an inline/managed policy to that role granting:
```json
{
  "Effect": "Allow",
  "Action": [
    "ecs:UpdateService",
    "ecs:DescribeServices",
    "ecs:DescribeTaskDefinition",
    "ecs:DescribeTasks",
    "ecs:ListTasks"
  ],
  "Resource": "*"
}
```
(Tightened to specific cluster/service ARNs where possible.)

### 2.3 `deploy-ecs` job — ClusterNotFoundException

**Symptom:**
```
ClusterNotFoundException: Cluster not found.
```

**Root cause:** The `ECS_CLUSTER` GitHub secret didn't match any actual cluster name/ARN in the
target account/region. `aws ecs list-clusters` revealed the real cluster is simply named
`default` in `us-east-1`.

**Fix:** Correct the `ECS_CLUSTER` secret value. General lesson: cluster/service names in
secrets should be periodically cross-checked against `list-clusters` / `list-services`,
especially after any manual console changes.

### 2.4 ECS service stuck in a health-check crash loop

**Symptom (from ECS event stream):**
```
Service pet-clinic-5537 has started 1 tasks... Amazon ECS replaced 1 tasks 
due to an unhealthy status. Deployment in progress...
```
repeated every couple of minutes, eventually tripping the deployment circuit breaker:
```
rolloutState: FAILED — "ECS deployment circuit breaker: tasks failed to start."
```

**Diagnosis:** Pulled the task definition and target group directly:
```bash
aws ecs describe-task-definition --task-definition default-pet-clinic-5537:1 \
  --query "taskDefinition.containerDefinitions[*].portMappings"
# containerPort: 80, hostPort: 80

aws elbv2 describe-target-groups --target-group-arns <tg-arn> \
  --query "TargetGroups[0].{Port:Port,HealthCheckPort:HealthCheckPort}"
# Port: 80, HealthCheckPort: 80
```
**Root cause:** Port mismatch. The task definition and the target group both expected traffic
on port **80**, but the app itself only listens on **8080** — [`Dockerfile`](Dockerfile) has
`EXPOSE 8080` and Spring Boot's default `server.port` is 8080 (no override in
[`application.properties`](src/main/resources/application.properties)). Nothing was
listening on port 80 inside the container, so every ALB health check failed and ECS kept
replacing the task until the circuit breaker gave up.

**Attempted fix #1 (rejected):** Change the target group's `Port` to 8080.
→ Blocked: `Port`/`Protocol` on an ELBv2 target group are **immutable** after creation;
`modify-target-group` only allows changing health-check settings, not the traffic port.
Re-pointing to 8080 properly would require deleting and recreating the service with
ECS-native load balancer config (`--load-balancers` at *service creation* — it also can't be
added to an existing service after the fact).

**Attempted fix #2 (rejected):** Keep the container on port 80 by setting `SERVER_PORT=80`,
and grant the container the `NET_BIND_SERVICE` Linux capability (needed because
[`Dockerfile`](Dockerfile) drops to a non-root `petclinic` user, and Linux blocks non-root
processes from binding ports < 1024).
→ Blocked: **Fargate does not permit adding `NET_BIND_SERVICE`** (or most other Linux
capabilities) to a task — `register-task-definition` rejected it outright:
`"NET_BIND_SERVICE is not allowed on Fargate."`

**Fix actually applied (task definition revision 3):**
- `SERVER_PORT=80` environment variable — makes Spring Boot bind port 80 instead of 8080.
- `"user": "0"` on the container definition — runs the process as root at the task level,
  overriding the Dockerfile's `USER petclinic`, since that's the only way left to bind a
  privileged port on Fargate. Blast radius is mitigated by Fargate isolating each task in its
  own microVM, but it's a real deviation from least-privilege and should be revisited (see
  §3, Follow-ups).
- Kept `containerPort`/`hostPort` at 80, matching the immutable target group.

Also raised `healthCheckGracePeriodSeconds` from `0` to `90` on the service — Spring Boot takes
15–30s to boot, and with a 0s grace period the ALB could start failing health checks before the
app was even up.

**Verification:**
```bash
aws elbv2 describe-target-health --target-group-arn <tg-arn>
# new task: State: healthy
```

### 2.5 "It's healthy, why do I get a 404?"

**Symptom:** `curl http://<alb-dns-name>/` → connection timeout on port 80;
`curl https://<alb-dns-name>/` → `HTTP 404 Not Found`.

**Diagnosis:** `describe-listeners` showed the ALB has **only an HTTPS/443 listener** (no port
80 listener exists at all, hence the timeout). `describe-rules` on that listener showed:
- A rule matching `host-header: pe-<random>.ecs.us-east-1.on.aws` → forwards to the real target
  groups (weighted 95%/5% across two target groups — a canary-style split).
- A `default` rule with no conditions → fixed `404` response.

**Root cause:** This ALB was provisioned by **AWS ECS "Express Mode"**, which issues a friendly
auto-generated public hostname (`*.ecs.<region>.on.aws`) and routes via host-header matching,
rather than exposing the raw ALB DNS name directly. Any request that doesn't send the correct
`Host` header (like hitting the bare ALB DNS name) falls through to the default 404 rule.

**Fix:** Use the actual generated hostname, not the ALB's own DNS name:
```
https://pe-19464cf9a3184f2e9eb1fa65624963cd.ecs.us-east-1.on.aws
```
Confirmed with `curl` — returns `200` and the real PetClinic homepage HTML.

## 3. Follow-ups / hardening not yet done

- **Root user tradeoff:** the container currently runs as root to bind port 80. The clean fix
  is to recreate the ECS service from scratch with proper ECS-native load balancer wiring on
  port 8080 (a new target group created with `Port: 8080` up front, and `--load-balancers`
  specified at service-creation time), restoring the non-root `petclinic` user from the
  Dockerfile. This is a service replacement, not an in-place update, so it needs a deliberate
  maintenance window.
- **Two ECS services exist in the same cluster** (`pet-clinic-5537` and `pet-clinic-service`) —
  worth confirming which one is meant to be canonical and decommissioning the other to avoid
  confusion and duplicate cost.
- **Cost:** the Fargate task and the ALB are billed continuously while running (task ≈
  $0.04–0.05/hr for 1 vCPU/2GB; ALB ≈ $0.0225/hr + LCU usage), not one-time. Scale to zero when
  not needed:
  ```bash
  aws ecs update-service --cluster default --service pet-clinic-5537 --desired-count 0
  ```
- **No infra-as-code in this repo** — the cluster, service, target groups, and ALB were all
  discovered and modified directly via the AWS CLI, with no Terraform/CDK/CloudFormation
  backing them. Any future change (like the port migration above) currently has to be done by
  hand and is at risk of drifting from whatever originally created it (likely the ECS console's
  Express Mode wizard). Codifying this in IaC would make the port-80-vs-8080 mismatch class of
  bug show up at plan/apply time instead of in production.
- **Old failed deployment lingering:** after the fix, the service's deployment history still
  showed the old (revision 1, `rolloutState: FAILED`) deployment with `running: 1` alongside the
  new healthy one, rather than fully draining to zero. It wasn't serving traffic (its target was
  unhealthy) but hadn't cleaned up on its own by the time this was last checked.
