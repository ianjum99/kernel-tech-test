# =============================================================================
# AtlasCo Telemetry Platform Infrastructure
# =============================================================================
# Production-ready AWS infrastructure for high-throughput EAV telemetry system
# - PostgreSQL RDS with logical replication for OLTP workloads
# - Redshift cluster for OLAP analytics
# - Security-first VPC with private subnets and restrictive security groups
# - Environment parameterization for dev/staging/prod scaling
# =============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}


variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"                        # West coast for lower latency
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"                      #  ~65k IPs, room for growth
}

variable "postgres_instance_class" {
  description = "PostgreSQL RDS instance class"
  type        = string
  default     = "db.t3.medium"                     # Dev default; prod uses memory-optimized
}

variable "postgres_allocated_storage" {
  description = "PostgreSQL allocated storage in GB"
  type        = number
  default     = 100                                # Dev default; prod scales to 2TB
}

variable "redshift_node_type" {
  description = "Redshift node type"
  type        = string
  default     = "dc2.large"                        # Dev default; compute-optimized for analytics
}

variable "redshift_cluster_size" {
  description = "Number of Redshift nodes"
  type        = number
  default     = 1                                  # Dev single-node; prod multi-node for parallel processing
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}


resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true                      #   RDS endpoint resolution
  enable_dns_support   = true                      #  Route 53 private DNS

  tags = {
    Name        = "atlasco-${var.environment}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "atlasco-${var.environment}-igw"
    Environment = var.environment
  }
}

# Public subnets: Host NAT gateways and load balancers (if needed)
resource "aws_subnet" "public" {
  count = 2                                        # multi-az 

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)      
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true                  

  tags = {
    Name        = "atlasco-${var.environment}-public-${count.index + 1}"
    Environment = var.environment
    Type        = "public"
  }
}

resource "aws_subnet" "private" {
  count = 2                                        # multi az

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)       
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "atlasco-${var.environment}-private-${count.index + 1}"
    Environment = var.environment
    Type        = "private"
  }
}

# NAT Gateways
resource "aws_eip" "nat" {
  count = 2

  domain = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name        = "atlasco-${var.environment}-nat-eip-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "main" {
  count = 2

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name        = "atlasco-${var.environment}-nat-${count.index + 1}"
    Environment = var.environment
  }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "atlasco-${var.environment}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table" "private" {
  count = 2

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name        = "atlasco-${var.environment}-private-rt-${count.index + 1}"
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}


# only allows access from application layer
resource "aws_security_group" "postgres" {
  name_prefix = "atlasco-${var.environment}-postgres-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432                        
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]  # Only app layer can connect 
    description     = "PostgreSQL access from application layer"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"                              # Allow all outbound 
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name        = "atlasco-${var.environment}-postgres-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true                   # Prevents deletion issues 
  }
}

resource "aws_security_group" "redshift" {
  name_prefix = "atlasco-${var.environment}-redshift-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5439
    to_port         = 5439
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "Redshift access from application layer"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name        = "atlasco-${var.environment}-redshift-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "atlasco-${var.environment}-app-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name        = "atlasco-${var.environment}-app-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# PostgreSQL RDS Subnet Group
resource "aws_db_subnet_group" "postgres" {
  name       = "atlasco-${var.environment}-postgres-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name        = "atlasco-${var.environment}-postgres-subnet-group"
    Environment = var.environment
  }
}


resource "aws_db_parameter_group" "postgres" {
  family = "postgres15"
  name   = "atlasco-${var.environment}-postgres-params"

  # Essential extensions for monitoring and debugging
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements,auto_explain"        # query performance tracking
  }

  # Logical replication setup for Debezium/Kafka streaming
  parameter {
    name  = "wal_level"
    value = "logical"                                 #  logical decoding for CDC
  }

  parameter {
    name  = "max_replication_slots"
    value = "10"                                      #  multiple consumers 
  }

  parameter {
    name  = "max_wal_senders"
    value = "10"                                      # parallel replication streams
  }

  # Write performance optimization for high-throughput workloads
  parameter {
    name  = "checkpoint_completion_target"
    value = "0.9"                                     #  checkpoint io over longer period
  }

  # Memory utilization: tell planner about available cache
  parameter {
    name  = "effective_cache_size"
    value = "{DBInstanceClassMemory/1024*3/4}"        # 3/4 instance memory for caching
  }

  tags = {
    Name        = "atlasco-${var.environment}-postgres-params"
    Environment = var.environment
  }
}


resource "aws_db_instance" "postgres" {
  identifier = "atlasco-${var.environment}-postgres"

  # Instance configuration: balanced for write performance and cost
  engine               = "postgres"
  engine_version       = "15.4"                      # latest stable 
  instance_class       = var.postgres_instance_class # r5.4xlarge for prod 
  allocated_storage    = var.postgres_allocated_storage
  max_allocated_storage = var.postgres_allocated_storage * 10  # Auto-scaling
  storage_type         = "gp3"                       
  storage_encrypted    = true                        

  # Database configuration
  db_name  = "atlasco"                               # application database
  username = "atlasco_admin"                         
  password = random_password.postgres_password.result  # generated secure password

  # Network configuration: private subnet deployment
  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  publicly_accessible    = false                    # never expose database to internet

  # Backup strategy: environment-specific retention
  backup_retention_period = var.environment == "prod" ? 30 : 7  # longer retention for prod
  backup_window          = "03:00-04:00"             
  maintenance_window     = "Sun:04:00-Sun:05:00"     

  # Observability: essential for production operations
  performance_insights_enabled = true               # performance monitoring
  monitoring_interval          = 60                 # monitoring every minute
  monitoring_role_arn         = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]  # ship logs to cloudwatch

  # Apply custom parameter group
  parameter_group_name = aws_db_parameter_group.postgres.name

  # Production safety features
  deletion_protection = var.environment == "prod"   # prevent accidental delete in prod
  skip_final_snapshot = var.environment != "prod"   # snapshot prod before deletion
  final_snapshot_identifier = var.environment == "prod" ? "atlasco-${var.environment}-postgres-final-snapshot" : null

  tags = {
    Name        = "atlasco-${var.environment}-postgres"
    Environment = var.environment
  }
}

resource "aws_db_instance" "postgres_replica" {
  count = var.environment == "prod" ? 1 : 0         # only deploy in production for cost efficiency

  identifier                = "atlasco-${var.environment}-postgres-replica"
  replicate_source_db       = aws_db_instance.postgres.id   # replicates from primary
  instance_class           = var.postgres_instance_class    # same size as primary - consistent performance
  publicly_accessible     = false                           # security posture
  performance_insights_enabled = true                       # replica lag and query performance

  tags = {
    Name        = "atlasco-${var.environment}-postgres-replica"
    Environment = var.environment
  }
}

resource "aws_redshift_subnet_group" "main" {
  name       = "atlasco-${var.environment}-redshift-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name        = "atlasco-${var.environment}-redshift-subnet-group"
    Environment = var.environment
  }
}

resource "aws_redshift_parameter_group" "main" {
  name   = "atlasco-${var.environment}-redshift-params"
  family = "redshift-1.0"

  parameter {
    name  = "enable_user_activity_logging"
    value = "true"
  }

  parameter {
    name  = "query_group"
    value = "atlasco_analytics"
  }

  tags = {
    Name        = "atlasco-${var.environment}-redshift-params"
    Environment = var.environment
  }
}


resource "aws_redshift_cluster" "main" {
  cluster_identifier = "atlasco-${var.environment}-redshift"

  # Instance configuration: optimized for analytical queries
  node_type                = var.redshift_node_type        # dc2.8xlarge for prod 
  number_of_nodes         = var.redshift_cluster_size      # multinode for parallel query processing -> prod
  cluster_version         = "1.0"                          

  # Database configuration
  database_name   = "atlasco"                              # analytics db
  master_username = "atlasco_admin"                        
  master_password = random_password.redshift_password.result

  cluster_subnet_group_name    = aws_redshift_subnet_group.main.name
  vpc_security_group_ids       = [aws_security_group.redshift.id]
  publicly_accessible          = false                    
  cluster_parameter_group_name = aws_redshift_parameter_group.main.name

  # Backup strategy: snapshots for disaster recovery
  automated_snapshot_retention_period = var.environment == "prod" ? 30 : 7
  preferred_maintenance_window        = "Sun:05:00-Sun:06:00"  

  # Security and audit logging
  encrypted                  = true                        
  logging {
    enable        = true                                   
    bucket_name   = aws_s3_bucket.redshift_logs.bucket
    s3_key_prefix = "redshift-logs/"                       
  }

  # Production safety
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "atlasco-${var.environment}-redshift-final-snapshot" : null

  tags = {
    Name        = "atlasco-${var.environment}-redshift"
    Environment = var.environment
  }
}

resource "aws_s3_bucket" "redshift_logs" {
  bucket = "atlasco-${var.environment}-redshift-logs-${random_id.bucket_suffix.hex}"  

  tags = {
    Name        = "atlasco-${var.environment}-redshift-logs"
    Environment = var.environment
  }
}

# Enable versioning for audit log integrity
resource "aws_s3_bucket_versioning" "redshift_logs" {
  bucket = aws_s3_bucket.redshift_logs.id
  versioning_configuration {
    status = "Enabled"                                   #  accidental overwrites protection
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redshift_logs" {
  bucket = aws_s3_bucket.redshift_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"                           
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "redshift_logs" {
  bucket = aws_s3_bucket.redshift_logs.id

  rule {
    id     = "log_retention"
    status = "Enabled"

    expiration {
      days = var.environment == "prod" ? 90 : 30        # retention for production compliance
    }

    noncurrent_version_expiration {
      noncurrent_days = 7                                # clean up old versions 
    }
  }
}

resource "random_password" "postgres_password" {
  length  = 32
  special = true
}

resource "random_password" "redshift_password" {
  length  = 32
  special = true
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_iam_role" "rds_monitoring" {
  name = "atlasco-${var.environment}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}


output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

# Database connection endpoints (marked sensitive to prevent console display)
output "postgres_endpoint" {
  description = "PostgreSQL primary database endpoint"
  value       = aws_db_instance.postgres.endpoint
  sensitive   = true                                      
}

output "postgres_replica_endpoint" {
  description = "PostgreSQL read replica endpoint (prod only)"
  value       = var.environment == "prod" ? aws_db_instance.postgres_replica[0].endpoint : null
  sensitive   = true
}

output "redshift_endpoint" {
  description = "Redshift analytics cluster endpoint"
  value       = aws_redshift_cluster.main.endpoint
  sensitive   = true
}

output "postgres_password" {
  description = "Generated PostgreSQL admin password"
  value       = random_password.postgres_password.result
  sensitive   = true
}

output "redshift_password" {
  description = "Generated Redshift admin password"
  value       = random_password.redshift_password.result
  sensitive   = true
}
