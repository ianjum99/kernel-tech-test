## Overview


**Key Capabilities:**
- **Scale**: 200M entities with 10k dynamic attributes per entity
- **Throughput**: High OLTP performance- via strategic partitioning
- **Consistency**: Immediate read-after-write for critical operations


## Key Components

### Part A: EAV Schema Design
- **Multi-tenant hash partitioning**: Even distribution across 16 partitions (~12.5M entities each)
- **Time-based partitioning**: Hot/warm/cold data lifecycle (7 days / 30 days / historical)
- **Type-specific value columns**: Separate string_value, integer_value, float_value columns avoid casting overhead
- **Materialized views**: Pre-aggregate frequently accessed attributes into JSONB for sub-100ms queries
- **Strategic composite indexes**: Single index covers all attributes of same type (scales to 10k attributes)

### Part B: Replication & Freshness

- **Logical replication**: PostgreSQL WAL → Debezium → Kafka → Redshift pipeline
- **Freshness budget matrix**: Business-driven SLAs (0ms for alerts, 30sec for analytics, 15min for exports)
- **Intelligent read routing**: Route queries to primary/replica/OLAP based on consistency needs and current lag
- **Lag monitoring**: Real-time replication health with automatic fallback to maintain correctness

### Part C: Infrastructure as Code

- **AWS Postgres RDS**: Optimized for 10k inserts/sec with logical replication enabled
- **Redshift cluster**: Column-store analytics with automated snapshots and audit logging
- **Security-first VPC**: Private subnets, restrictive security groups, encrypted storage
- **Environment parameterization**: Same Terraform code scales from single-node dev to multi-node prod

## Quick Start

### 1. Deploy Infrastructure (5 minutes)
```bash
cd infra/
terraform init                                    
terraform plan -var-file="dev.tfvars"             
terraform apply -var-file="dev.tfvars"           
```
What this creates: VPC, PostgreSQL RDS, Redshift cluster, security groups, S3 bucket

### 2. Set Up Database Schema (2 minutes)
```bash
DB_ENDPOINT=$(terraform output -raw postgres_endpoint)
DB_PASSWORD=$(terraform output -raw postgres_password)

psql -h $DB_ENDPOINT -U atlasco_admin -d atlasco -f ../schema.sql
```
What this creates: Tables, indexes, materialized views, example queries

### 3. Test Performance (2 minutes)
Run the example queries from schema.sql to validate:

- Multi-attribute filtering (operational workload)
- Temperature distribution analysis (analytical workload)
- Expected Performance: Sub-100ms operational queries, 1-5 second analytical queries

## Trade-offs & Limitations

**Deliberate architectural decisions and their implications:**

- **Write scaling**: Single Postgres writer scales to ~10k inserts/sec
- **Query complexity**: Some analytical patterns require expensive JOINs
- **Storage costs**: Full EAV retention can be expensive at billion-row scale


**What's not included** (requires additional time):
- Debezium/Kafka deployment and configuration
- Application code for read routing and lag monitoring
- Full operational runbooks and monitoring dashboards
- Load testing and performance validation
