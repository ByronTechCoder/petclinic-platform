# Database Initialization Strategy

**Last Updated:** 2026-09-22
**Purpose:** Documents how the shared `petclinic` MySQL database on RDS gets its schema created by the three database-backed services, and the connection string format those services (and their K8s ConfigMaps) need to use.

## Table of Contents

- [Strategy](#strategy)
- [Shared Database](#shared-database)
- [Schema Scripts](#schema-scripts)
- [Initialization Order](#initialization-order)
- [Connection String Format](#connection-string-format)
- [Verification Status](#verification-status)

## Strategy

**Spring Boot auto-initialization** — not a manual bootstrap script, migration tool (Flyway/Liquibase), or Kubernetes init container that runs SQL directly.

Each of the three database-backed services ships its own `schema.sql` (and `data.sql`) under `src/main/resources/db/mysql/` in the (read-only) `spring-petclinic-microservices` repo. With the `mysql` Spring profile active and `spring.sql.init.mode=always` set, Spring Boot runs that service's `schema.sql` against the configured datasource on every pod startup. The statements are idempotent (`CREATE DATABASE IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`), so re-running them on every restart is safe and self-healing — no separate migration/versioning tool is needed for this project's scope.

There is no cross-service schema coordinator. Ordering (below) is enforced entirely by **Kubernetes deployment order** — an init container per CLAUDE.md's "Service startup order" convention (Config Server → Discovery Server → all others) will additionally gate visits-service on customers-service being Ready, once E-8 (Kubernetes Manifests — Base) implements it. That K8s wiring is out of scope for this RDS-focused pass (E-5) and not yet built.

## Shared Database

All three services connect to a **single shared `petclinic` database** on one RDS instance (`petclinic-{env}-mysql`, provisioned by `terraform/modules/rds/`) — not one database per service. This matches ADR-0003 and is required by the app's own design: `visits.pet_id` has a foreign key to `pets.id`, which lives in the customers-service schema, so the two services must share a database to satisfy that constraint.

## Schema Scripts

Identified directly from the application repo (read-only reference — not modified):

| Service | Script | Tables Created |
|---------|--------|-----------------|
| customers-service | `spring-petclinic-customers-service/src/main/resources/db/mysql/schema.sql` | `types`, `owners`, `pets` |
| vets-service | `spring-petclinic-vets-service/src/main/resources/db/mysql/schema.sql` | `vets`, `specialties`, `vet_specialties` |
| visits-service | `spring-petclinic-visits-service/src/main/resources/db/mysql/schema.sql` | `visits` |

7 tables total. Each script starts with `CREATE DATABASE IF NOT EXISTS petclinic; USE petclinic;`, so any one of the three services could bootstrap the database on its own — ordering only matters because of the one cross-service foreign key below.

## Initialization Order

1. **customers-service** — creates `types`, `owners`, `pets` (no external dependencies)
2. **vets-service** — creates `vets`, `specialties`, `vet_specialties` (independent; can start in either order relative to step 1)
3. **visits-service** — creates `visits`, which has `FOREIGN KEY (pet_id) REFERENCES pets(id)` — **must** run after customers-service has created `pets`, or its `schema.sql` fails

## Connection String Format

```
jdbc:mysql://{rds-endpoint}:3306/petclinic
```

`{rds-endpoint}` is the RDS module's `endpoint` output (host only, no port — see `terraform/modules/rds/outputs.tf`), surfaced per-environment as the root module's `rds_endpoint` output (`terraform/environments/{dev,prod}/outputs.tf`). Once E-8 (K8s Base manifests) exists, each of the three DB-backed services' Helm values / ConfigMap should set `SPRING_DATASOURCE_URL` (or equivalent) to this format rather than hardcoding a host — the value is only known after `terraform apply` and will differ between dev and prod.

Example (dev, illustrative — actual hostname known only after apply): `jdbc:mysql://petclinic-dev-mysql.xxxxxxxxxx.eu-central-1.rds.amazonaws.com:3306/petclinic`

Credentials (`username`/`password`) come from AWS Secrets Manager (`petclinic/{env}/rds-credentials`, created by the RDS module per PETPLAT-23) via the External Secrets Operator — never hardcoded in the connection string or a ConfigMap. See [Secrets Management](./technical-spec.md#secrets-management).

## Verification Status

**Not yet tested.** Verifying that "services can connect and tables exist" requires customers-service (and the other two) to actually run against RDS, which requires E-8 (K8s base manifests), E-16 (Helm chart), and E-17 (ArgoCD) — none of which exist yet. This is tracked as open work, not a gap in this ticket: once customers-service is first deployed to dev, verify via `kubectl logs` (Hibernate/`schema.sql` startup output) or by exec-ing a MySQL client pod and running `SHOW TABLES;` against the dev RDS endpoint.
