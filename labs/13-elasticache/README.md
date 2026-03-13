# Lab 13 - ElastiCache

> Exam weight: **15-20%** of SAA-C03 questions (as part of database domain)

## What This Lab Creates

- ElastiCache Redis Replication Group (2 nodes, Multi-AZ, TLS)
- ElastiCache Memcached Cluster (2 nodes)
- Security Groups (Redis :6379, Memcached :11211)
- Subnet Group + Parameter Group

## Run

```bash
terraform init
terraform apply   # ~10 minutes for cluster creation
terraform destroy
```

---

## Key Concepts

### Redis vs Memcached

| Feature | Redis | Memcached |
|---------|-------|-----------|
| Data structures | Strings, hashes, lists, sets, sorted sets, streams | Strings only |
| Persistence | Yes (RDB + AOF) | No |
| Replication | Yes (primary + replicas) | No |
| Multi-AZ failover | Yes | No |
| Pub/Sub | Yes | No |
| Transactions | Yes (MULTI/EXEC) | No |
| Multi-threaded | No | Yes |
| Horizontal scaling | Cluster mode | Yes (multiple nodes) |
| Use case | Complex caching, sessions, leaderboards | Simple cache, large data |

**Decision Rule**:
```
Need persistence/failover → Redis
Need simple, horizontal scale, multi-thread → Memcached
Sessions/auth tokens → Redis
Leaderboards/rankings → Redis (sorted sets)
Simple object caching → Either
```

### Redis Cluster Modes

#### Cluster Mode Disabled
- 1 primary + up to 5 read replicas
- Supports Multi-AZ automatic failover
- Max data: single shard (~512 GB)

#### Cluster Mode Enabled
- Multiple shards (partitions) → horizontal scaling
- Data distributed across shards
- Max 500 nodes (90 shards × up to 6 replicas each)
- Use case: very large datasets, high throughput

### Eviction Policies (maxmemory-policy)

| Policy | Behavior |
|--------|---------|
| noeviction | Error when memory full |
| allkeys-lru | Evict least recently used (most common) |
| volatile-lru | Evict LRU among keys with TTL |
| allkeys-random | Random eviction |
| volatile-ttl | Evict keys with shortest TTL first |

**Exam Tip**: Set eviction policy for caches — `allkeys-lru` most common

### Redis Persistence

| Mode | Description | Use Case |
|------|-------------|---------|
| None | No persistence | Pure cache |
| RDB | Snapshot at intervals | Backup, fast restart |
| AOF | Log every write | Durability, data loss tolerance |
| RDB + AOF | Both | Maximum durability |

### Caching Strategies

#### Lazy Loading (Cache-Aside)
```
Read → Check cache → HIT: return | MISS: fetch DB → write to cache → return
```
- Only cache what's needed
- Cache miss = 3 trips (check cache, read DB, write cache)
- Stale data possible

#### Write-Through
```
Write → Write to cache AND DB simultaneously
```
- Cache always up-to-date
- Adds latency to writes
- May cache data that's never read

#### Write-Behind
```
Write → Write to cache → Async write to DB
```
- Fastest writes
- Risk of data loss

**Exam Tip**: "Improve read performance" → ElastiCache (Lazy Loading or Write-Through)

### Use Cases

```
Session store         → Redis (key-value, TTL)
Leaderboard           → Redis (sorted sets: ZADD, ZRANK)
Real-time analytics   → Redis (counters: INCR)
Pub/Sub               → Redis
Database query cache  → Redis or Memcached
Shopping cart         → Redis
Rate limiting         → Redis (INCR + TTL)
```

### ElastiCache vs RDS Read Replicas

| Feature | ElastiCache | RDS Read Replica |
|---------|------------|-----------------|
| Type | In-memory | On-disk |
| Latency | Sub-millisecond | Milliseconds |
| Persistence | Optional (Redis) | Yes |
| SQL queries | No | Yes |
| Use case | Cache layer | Read scale-out |

**Common Pattern**: RDS (write) → ElastiCache (read cache) → Application
