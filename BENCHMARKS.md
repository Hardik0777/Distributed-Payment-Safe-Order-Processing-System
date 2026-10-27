# Benchmarks

## Rules
1. A throughput number only counts if `npm run reconcile -- --wait 60` passes **after** the run.
2. Record the hardware. Numbers from different machines are not comparable.
3. Change one thing at a time and log it below.

## How to run
```bash
docker compose up --build -d
k6 run -e RATE=100 load/k6-orders.js && npm run reconcile -- --wait 60
k6 run -e RATE=200 load/k6-orders.js && npm run reconcile -- --wait 60
k6 run -e RATE=400 load/k6-orders.js && npm run reconcile -- --wait 60
```
Watch Grafana (http://localhost:3030) while it runs to see where time goes: gateway latency vs. message handling time vs. outbox backlog.

## Baseline (sandbox, 2 vCPU, all services + Postgres + Redis + RabbitMQ on one box)

Measured with `scripts/loadgen.js --dup 0`, 20 s per step:

| Target | p50 | p95 | p99 | Notes | Reconcile |
|---|---|---|---|---|---|
| 100 rps | 78 ms | 252 ms | 330 ms | 0 errors | PASS |
| 200 rps | 2.3 s | 8.8 s | 9.5 s | saturated; client retries | PASS |
| 400 rps | 2.7 s | 10.3 s | 12.1 s | overloaded | PASS |
| 800 rps | 4.1 s | 15.9 s | 22.9 s | 74 % requests failed/timed out | PASS, 1 order per key |

## Tuning log (fill in on your own machine)

| # | Change | Rate | p95 before | p95 after | Why it helped |
|---|---|---|---|---|---|
| 1 | | | | | |

Ideas worth trying, roughly in order of expected impact:
- Run each service with more instances (`docker compose up --scale payment-service=3`). Safe because of `SKIP LOCKED` and idempotent consumers.
- `DB_POOL_SIZE` vs. Postgres `max_connections`; add PgBouncer.
- Combine the create-order inserts into one round trip (CTE).
- `RELAY_INTERVAL_MS` / `RELAY_BATCH` trade-off between latency and DB load.
- Consumer `prefetch` (currently 20).
