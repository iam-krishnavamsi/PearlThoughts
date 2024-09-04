# main.tf

# Terraform Initialization
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "medusa-backend/terraform.tfstate"
    region = "us-east-1"
  }
}

# Provider Configuration
provider "aws" {
  region = "us-east-1"
}

# VPC and Networking
resource "aws_vpc" "medusa_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "medusa_subnet_public" {
  count             = 2
  vpc_id            = aws_vpc.medusa_vpc.id
  cidr_block        = "10.0.${count.index}.0/24"
  map_public_ip_on_launch = true
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
}

resource "aws_internet_gateway" "medusa_igw" {
  vpc_id = aws_vpc.medusa_vpc.id
}

resource "aws_route_table" "medusa_route_table_public" {
  vpc_id = aws_vpc.medusa_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.medusa_igw.id
  }
}

resource "aws_route_table_association" "medusa_route_table_assoc_public" {
  count          = 2
  subnet_id      = aws_subnet.medusa_subnet_public[count.index].id
  route_table_id = aws_route_table.medusa_route_table_public.id
}

# Security Groups
resource "aws_security_group" "medusa_sg" {
  vpc_id = aws_vpc.medusa_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "medusa_rds_sg" {
  vpc_id = aws_vpc.medusa_vpc.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    security_groups = [aws_security_group.medusa_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS PostgreSQL Database
resource "aws_db_instance" "medusa_db" {
  allocated_storage    = 20
  engine               = "postgres"
  instance_class       = "db.t3.micro"
  name                 = "medusadb"
  username             = "medusauser"
  password             = "yourpassword"
  parameter_group_name = "default.postgres10"
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.medusa_rds_sg.id]
  db_subnet_group_name = aws_db_subnet_group.medusa_subnet_group.name

  publicly_accessible = false
  multi_az            = false
}

resource "aws_db_subnet_group" "medusa_subnet_group" {
  name       = "medusa-db-subnet-group"
  subnet_ids = aws_subnet.medusa_subnet_public[*].id
}

# ECS Cluster
resource "aws_ecs_cluster" "medusa_cluster" {
  name = "medusa-cluster"
}

# ECR Repository
resource "aws_ecr_repository" "medusa_repo" {
  name = "medusa-backend"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "medusa_task" {
  family                   = "medusa-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"

  container_definitions = <<DEFINITION
[
  {
    "name": "medusa",
    "image": "${aws_ecr_repository.medusa_repo.repository_url}:latest",
    "cpu": 512,
    "memory": 1024,
    "essential": true,
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ],
    "environment": [
      { "name": "DATABASE_TYPE", "value": "postgres" },
      { "name": "DATABASE_URL", "value": "${aws_db_instance.medusa_db.endpoint}" },
      { "name": "JWT_SECRET", "value": "your_jwt_secret" },
      { "name": "COOKIE_SECRET", "value": "your_cookie_secret" },
      { "name": "NODE_ENV", "value": "production" }
    ]
  }
]
DEFINITION
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn      = aws_iam_role.ecs_task_execution_role.arn
}

# IAM Role for ECS Task
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  ]
}

# ECS Service
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.medusa_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.medusa_subnet_public[*].id
    security_groups = [aws_security_group.medusa_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_tg.arn
    container_name   = "medusa"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.medusa_listener]
}

# Application Load Balancer
resource "aws_lb" "medusa_lb" {
  name               = "medusa-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.medusa_sg.id]
  subnets            = aws_subnet.medusa_subnet_public[*].id
}

resource "aws_lb_target_group" "medusa_tg" {
  name     = "medusa-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.medusa_vpc.id
  target_type = "ip"
}

resource "aws_lb_listener" "medusa_listener" {
  load_balancer_arn = aws_lb.medusa_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.medusa_tg.arn
  }
}

# Outputs
output "alb_dns_name" {
  description = "The DNS name of the ALB"
  value       = aws_lb.medusa_lb.dns_name
}

output "db_endpoint" {
  description = "The endpoint of the PostgreSQL database"
  value       = aws_db_instance.medusa_db.endpoint
}
