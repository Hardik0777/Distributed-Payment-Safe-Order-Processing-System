# Design decisions & trade-offs

## 1. Delivery semantics: at-least-once + idempotent consumers

Exactly-once delivery across a network isn't something you can buy from a broker. Instead:

- **Producers** never lose an event (transactional outbox + publisher confirms), at the cost of sometimes sending it twice.
- **Consumers** make duplicates harmless (dedupe table / unique constraints / conditional updates).

Result: *effectively-once processing*. Every design choice below follows from accepting duplicates instead of fighting them.

## 2. Transactional Outbox vs. alternatives

**Problem (dual write):** `INSERT order` then `publish(order.created)`. Crash between the two → order exists, payment never happens. Publish first → event for an order that rolled back.

| Option | Why not |
|---|---|
| Publish inside the DB transaction | Broker isn't part of the transaction; still a dual write |
| 2PC / XA | RabbitMQ doesn't support it; blocking, operationally painful |
| CDC (Debezium) | Great at scale, but a heavy dependency for this size |
| **Outbox + polling relay** ✅ | Simple, uses only Postgres guarantees. Costs ~100 ms of latency and DB polling |

Relay details: `SELECT … FOR UPDATE SKIP LOCKED` (multiple relays can run safely), publish with **broker confirms**, then mark `published_at`. A crash after publishing but before committing causes a re-send, which consumers absorb. Scenario 3 tests exactly this window.

**Ordering:** a single relay per DB publishes in `id` order, but retries/redelivery can still reorder events. Consumers don't rely on order: the state machine rejects invalid transitions, and the payment service handles `order.cancelled` overtaking `order.created` with a tombstone row.

## 3. Idempotency: Redis is the fast path, Postgres is the guarantee

- Gateway: `SET idem:<key>:lock NX PX 10000`. Completed responses cached for 24 h. Concurrent duplicates get `409 + Retry-After` so a retry storm never reaches the DB.
- Order service: `idempotency_keys` row inserted **in the same transaction** as the order. A concurrent duplicate's `INSERT … ON CONFLICT DO NOTHING` blocks on the unique index until the first commits, then reads the stored response.
- Request hash: the same key with a different body → `422`, never silently returning the wrong order.

**Why both?** Redis can be down, evicted or failed-over (async replication can lose a lock). If Redis were the only guard, any of those would allow duplicate orders. The gateway **fails open** when Redis is unavailable: availability is preserved and correctness still comes from Postgres (scenario 5).

## 4. Three guards against double charging

1. `UNIQUE(order_id)` on payments, so one payment row per order.
2. Provider idempotency key `charge:<orderId>`, so retrying after a timeout returns the original charge.
3. `UPDATE payments … WHERE status='PROCESSING'`, so only one worker finalises and emits the event.

The provider call is made **outside** any DB transaction. Holding row locks across a network call that can take seconds would exhaust the pool under load. The price is a window where the charge succeeded but our DB still says `PROCESSING`. That window is safe because the next delivery calls the provider again with the same key.

Guard 2 is the critical one for timeouts. Setting `UNSAFE_RANDOM_PROVIDER_KEY=1` removes it and the reconciler finds 100+ double charges in a single run.

## 5. Saga: choreography, not orchestration

Services react to each other's events; no central coordinator.

- **Pro:** no single point of failure, services stay decoupled, fits a 2–3 step flow.
- **Con:** the flow is implicit and spread across services. Beyond ~4–5 steps (inventory, shipping, loyalty points…) an orchestrator (a saga state table, or Temporal) is easier to reason about and monitor.

**Compensation example:** customer cancels while the charge is in flight. Order → `CANCELLED`; then `payment.succeeded` arrives → order goes `CANCELLED → REFUND_PENDING` and emits `order.refund_requested` → payment service refunds (idempotently) → `REFUNDED`. Scenario 6 triggers this ~100 times per run.

## 6. Retries and dead letters

Each consumer queue has retry queues `.retry.1 … .retry.5` with fixed TTLs (0.5 s, 1 s, 2 s, 4 s, 8 s) that dead-letter back into the main queue, plus a `.dlq`.

- Per-level queues instead of per-message TTL: RabbitMQ only expires messages at the head of a queue, so mixing TTLs in one queue causes head-of-line blocking.
- Errors are classified: provider `503` / timeout = transient (retry), declined card or unknown order = permanent (DLQ immediately).
- A message in the DLQ leaves its payment `PROCESSING`; the reconciler flags it as **stuck** (I8) rather than letting it go silent.

## 7. Crash-only services

If a service loses its broker connection it exits and the orchestrator restarts it. No complex in-process reconnection logic: unacked messages are redelivered and unpublished outbox rows stay put, so restarting is always safe. Scenarios 2 and 7 kill services with `-9` mid-load.

## 8. Data ownership

Each service has its own database and never reads another's. The demo runs the three databases on one Postgres instance to stay laptop-friendly; production would use separate instances. The only cross-database reader is the reconciler, which is an offline audit job (like a finance team's daily reconciliation), not part of the request path.

## 9. Known limitations / what I'd do at 100× scale

| Area | Today | At scale |
|---|---|---|
| Broker | RabbitMQ, single node | Quorum queues, or Kafka partitioned by `orderId` for per-order ordering + replay |
| Outbox | Polling every 100 ms | CDC (Debezium) off the WAL; no polling load |
| Dedupe table | Grows forever | TTL/partitioned cleanup (keep > max redelivery window) |
| Idempotency keys | 24 h Redis TTL, Postgres forever | Partition by day, drop old partitions |
| Databases | One Postgres, 3 DBs | One instance per service, read replicas for GETs, PgBouncer |
| DLQ | Inspected manually | Replay tool + alerting on DLQ depth |
| Reconciliation | On demand | Scheduled, with alerts; also against real provider settlement files |
| Payment state | Polling via redelivery | Provider webhooks + periodic status sync for stuck `PROCESSING` |
| Auth | None | JWT at the gateway, per-customer idempotency key scoping |
