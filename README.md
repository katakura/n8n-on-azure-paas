# n8n-on-azure-paas

[日本語](README-ja.md)

A Bicep sample that runs n8n on Azure with PaaS only (**Azure Verified Modules only**).
It is meant for verification: create it, try it, and delete the whole resource group.

## Architecture

| Role | Service | AVM module |
|---|---|---|
| App (n8n 2.46.6) | Container Apps (Consumption, 1 replica, 1 vCPU / 2 GiB) | `app/container-app`, `app/managed-environment` |
| Database (all state) | Azure Database for PostgreSQL flexible server (B1ms, VNet integrated) | `db-for-postgre-sql/flexible-server` |
| Network | VNet (2 subnets), Private DNS zone | `network/virtual-network`, `network/private-dns-zone` |
| Logs | Log Analytics | `operational-insights/workspace` |

- SQLite on a network share (Azure Files) is a poor fit for n8n, so state lives in PostgreSQL (`DB_TYPE=postgresdb`). No volume is mounted.
- Multiple main instances need an n8n Enterprise license, so the app is pinned to exactly one replica.
- Only the n8n ingress is public. PostgreSQL has public access disabled.
- `N8N_WEBHOOK_URL` is built from the environment default domain (referencing the app's own output would be circular). `N8N_PROXY_HOPS=1` is also set.

## Important: pin the encryption key

Without a volume, `N8N_ENCRYPTION_KEY` must be a fixed value. If it is missing or different, n8n fails to start (the key changes whenever the container is recreated):

```text
Deployment key 'signing.hmac' cannot be read with this instance encryption key
```

`deploy.sh` generates a key on the first deployment and reuses the one stored in the app secret (`encryption-key`) afterwards. The key is not stored anywhere else; deleting the resource group loses it.

## Important: restrict the source IP

**The first visitor becomes the owner of an n8n instance.** Between deployment and creating your owner account, someone else could claim it, and n8n can execute code.

Pass the allowed source IPs (CIDR) with `-i`. Without it, the script warns and leaves the app open to the internet.

## Deploy

```bash
./deploy.sh -s "<subscription>" -i "<your-ip>/32"            # what-if only
./deploy.sh -s "<subscription>" -i "<your-ip>/32" --apply    # deploy
```

| Option | Meaning |
|---|---|
| `-s` | Subscription (required) |
| `-g` | Resource group (default `rg-n8n-paas`, created if missing) |
| `-i` | Allowed source IP / CIDR, comma-separated |
| `-u` | PostgreSQL administrator name (default `n8nadmin`) |
| `-p` | PostgreSQL administrator password |
| `--apply` | Deploy after what-if |

- If the password is omitted, `main.bicep` derives it from `uniqueString`. **`uniqueString` is deterministic (derived from the subscription and resource group IDs), not random.** That is acceptable here because PostgreSQL has public access disabled, but pass your own with `-p` for anything else.
- Environment variables (`PG_ADMIN_LOGIN`, `PG_ADMIN_PASSWORD`, `N8N_ENCRYPTION_KEY`, `ALLOWED_IPS`) work too.
- The URL is in the `n8nUrl` output. Open it in a browser to create the owner account.
- `what-if` may show diffs (such as VNet subnets) that are not real changes.

Delete everything when done:

```bash
az group delete -n rg-n8n-paas --subscription "<subscription>" --yes
```

The Container Apps environment also creates an `ME_…` resource group (Load Balancer and IP). Confirm it disappears with the deletion.

## Verification (2026-11-09, Japan East)

- `/healthz` and `/healthz/readiness` return 200; migrations run on PostgreSQL.
- A webhook (`GET /webhook/…`) returns 200.
- After a restart (new replica), the workflow, its active state, and the execution history are still there.
- Idle CPU averages 3.4-3.8 millicores per hour (the idle threshold is 0.01 vCPU), so the app is billed at the idle rate without tuning environment variables.

## Actual cost

Cost Management (ActualCost), per day:

| Item | JPY/day |
|---|---|
| PostgreSQL B1ms (compute) | about 99 |
| PostgreSQL storage | about 23 |
| Private DNS zone | about 3 |
| Container Apps environment infra: Load Balancer (`ME_…` RG) | about 95 |
| Same: public IP | about 19 |
| **Total without the Container Apps app** | **about 239** |

- The app itself did not appear in the bill for about two days, probably because of the monthly free grant (180,000 vCPU-s and 360,000 GiB-s). This is my inference and not confirmed.
- After the free grant: about 124 JPY/day (2026-11-09, a full day), billed at the idle rate. The active share is about 1.6% of the seconds.
- Total after the free grant: about 363 JPY/day, roughly 10,900 JPY/month.
- Not included: Log Analytics, data transfer.

## Not covered

- n8n license terms (check the official documentation for personal or internal use)
- Workflows that handle large files (binary data) without a volume
- Queue mode (Redis) and multiple replicas
- Custom domains and managed certificates
- Key Vault (secrets are stored as Container App secrets)
