# Implementation Notes & TODOs

## Assumptions Made
- **Tenant Scale**: Assumed 16 tenants for initial partitioning 
- **Data Retention**: 7 days hot / 30 days warm / unlimited cold storage 
- **Attribute Cardinality**: Most attributes have moderate cardinality 
- **Query Patterns**: 80% operational queries on recent data, 20% analytical on historical 
- **Security**: Assumed VPC-private deployment with application-layer authentication

## Known Limitations & Mitigations
### Scale Bottlenecks
- **Single Postgres Writer**: Current design peaks at 10k inserts/sec
  - *Mitigation*: Horizontal sharding by tenant_id, or switch to distributed database
- **Attribute Cardinality**: High-cardinality attributes (>1M values) slow down indexes
  - *Mitigation*: Pre-aggregate hot combinations, use bloom filters for existence checks
- **Cold Query Performance**: Historical analytics on years of data will be slow
  - *Mitigation*: Column-store extension (cstore_fdw), or archive to data lake (S3 + Athena)

### Cost Optimization Opportunities
**Strategies to reduce operational costs as data volume grows**

- **Storage Tiering**: Move cold partitions to S3
  - *Implementation*: pg_dump + COPY to S3, query via foreign data wrapper
- **Compute Rightsizing**: Auto-scaling read replicas based on connection pool metrics
  - *Implementation*: CloudWatch alarms trigger Lambda functions to scale RDS
- **Reserved Instances**: 1-year commitments save 30-40% on predictable baseline load
  - *Strategy*: Reserve 70% of expected capacity, use on-demand for spikes

### Operational Complexity

- **Schema Changes**: Adding new attribute types requires DDL across OLTP and OLAP
  - *Mitigation*: Version schema changes, blue-green deployments for breaking changes
- **Multi-Tenant Queries**: Cross-tenant analytics risk data leakage without careful ACL
  - *Mitigation*: Separate analytics user with tenant-scoped views, audit all queries
- **Time-Zone Handling**: Customer data in local time vs UTC storage causes confusion
  - *Mitigation*: Always store UTC, convert in application layer with customer timezone metadata

## Follow-Up Architecture Decisions
**Trade-offs and alternatives**

### Alternative Approaches Considered
1. **NoSQL Document Store**: Rejected due to analytical query complexity
   - *Pro*: Natural fit for dynamic attributes, horizontal scaling
   - *Con*: Weak analytical capabilities, eventual consistency challenges

2. **Time-Series Database** (InfluxDB, TimescaleDB): Considered but Postgres EAV more flexible
   - *Pro*: Optimized for time-series data, better compression
   - *Con*: Limited multi-dimensional queries, less operational expertise

3. **Microservices**: Single service with bounded context preferred for 2-hour scope
   - *Pro*: Clear separation of concerns, independent scaling
   - *Con*: Distributed transaction complexity, operational overhead

4. **Event Sourcing**: Would add complexity without clear benefit for this use case
   - *Pro*: Full audit trail, temporal queries
   - *Con*: Query complexity, storage overhead, no clear business requirement

### Improvements not implemented**

- **Federated Queries**: Cross-OLTP/OLAP queries with Presto/Trino for unified analytics
  - *Use case*: Real-time dashboards combining fresh operational data with historical trends

- **Real-Time ML**: Stream processing for anomaly detection and predictive analytics
  - *Implementation*: Kafka Streams → MLflow models → real-time alerts

- **Multi-Region**: Geographic distribution for global latency optimization
  - *Strategy*: Read replicas in each region, master-master with conflict resolution

- **API Gateway**: Rate limiting, authentication, intelligent request routing
  - *Features*: Per-tenant rate limits, JWT-based auth, automatic failover routing
