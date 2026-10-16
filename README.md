# data-sync-deploy

Deploys the `data-sync` FastAPI service to Amazon EKS (Helm and Kustomize) and to EC2 hosts (Ansible), plus a written design. The brief is written for GCP; the GCP-to-AWS mapping is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#gcp-to-aws-mapping).

### Why the name

This repo holds everything needed to *deploy* data-sync, and nothing else: no application code, no Dockerfile. So I named it after what it does: `<service>-deploy`. It's the name I'd give it on the platform team, where a service's code and its deployment config usually live in separate repos with different owners and release cycles. I kept the company name out so the repo reads as normal infrastructure work rather than an interview exercise.

| Part | What | Where |
| --- | --- | --- |
| 1 | Helm chart, three values files, ServiceMonitor | [`helm/charts/data-sync/`](helm/charts/data-sync/README.md) |
| 1 | Kustomize production overlay | [`standard/data-sync/production/`](standard/data-sync/production/kustomization.yaml) |
| 2 | Ansible role, playbook, group_vars | [`ansible/`](ansible/) |
| 3 | Design answers | [`docs/DESIGN.md`](docs/DESIGN.md) |
| - | Options and trade-offs | [`docs/DECISIONS.md`](docs/DECISIONS.md) |
| - | Architecture, NFRs, maintaining the repo | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |

## Checks

```bash
make lint template        # helm lint and helm template for default, staging, production
make render               # regenerate the kustomize base from the chart
make kustomize            # build the production overlay
make ansible-syntax ansible-lint
make all                  # what CI runs
```

You need `helm` 3.12+, `kubectl` 1.27+ (it has kustomize built in), `ansible-core` 2.14+ and `ansible-lint`.

## Deploying

```bash
# staging
helm upgrade --install data-sync helm/charts/data-sync -n data-sync-staging --create-namespace \
  -f helm/charts/data-sync/values.yaml -f helm/charts/data-sync/values.staging.yaml \
  --set-file secret.redisPassword=./redis-password.txt --atomic

# production (also creates the data-sync-redis Secret through External Secrets)
kubectl apply -k standard/data-sync/production

# EC2 hosts
cd ansible && ansible-playbook playbooks/playbook-data-sync.yml --tags install,deploy
```

Upgrades, rollbacks and a local smoke test are in the [chart README](helm/charts/data-sync/README.md).

## Shortcuts

- The ECR image `123456789012.dkr.ecr.us-east-1.amazonaws.com/brightedge/data-sync` is a placeholder, and the app entry point `app.main:app` is assumed.
- Redis is not a sub-chart. Install Bitnami Redis separately for local development (chart README).
- Checked with `helm lint`, `helm template`, `kubectl kustomize`, `ansible-lint` and `--syntax-check`. Not run on a live cluster or VM. More in [`docs/DECISIONS.md`](docs/DECISIONS.md#whats-not-done).
