terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "domain_name" {
  description = "Your registered domain name"
  type        = string
  default     = "samarthpc.shop"
}

# ==============================================================================
# 1. NETWORKING (VPC, Public/Private Subnets, IGW)
# ==============================================================================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "main-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "main-igw" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# PUBLIC SUBNETS (For ALB and now EC2 Instances)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-${count.index + 1}" }
}

# PRIVATE SUBNETS (Kept intact strictly for RDS Isolation)
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 2}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "private-subnet-${count.index + 1}" }
}

# ROUTE TABLES
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Cost Savings: NAT Gateway and private route mapping have been removed.

# ==============================================================================
# 2. SECURITY GROUPS
# ==============================================================================
resource "aws_security_group" "alb" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
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

resource "aws_security_group" "ec2" {
  name   = "ec2-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "storage" {
  name   = "storage-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# 3. STORAGE (S3 & EFS)
# ==============================================================================
resource "aws_s3_bucket" "pictures" {
  bucket_prefix = "user-pictures-bucket-"
}

resource "aws_s3_bucket_lifecycle_configuration" "pictures_lifecycle" {
  bucket = aws_s3_bucket.pictures.id
  rule {
    id     = "delete-old-pictures"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

resource "aws_efs_file_system" "shared_code" {
  creation_token = "shared-web-code"
  tags           = { Name = "SharedWebCode" }
}

resource "aws_efs_mount_target" "efs_mount" {
  count           = 2
  file_system_id  = aws_efs_file_system.shared_code.id
  # Updated to look at the public subnets since our servers reside there now
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.storage.id]
}

# ==============================================================================
# 4. DATABASE (RDS MySQL)
# ==============================================================================
resource "aws_db_subnet_group" "db_subnets" {
  name       = "db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "db" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "picturedb"
  username               = "admin"
  password               = "SuperSecurePassword123!"
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.storage.id]
  skip_final_snapshot    = true
  multi_az               = false # Cost Savings: Disabled Multi-AZ to avoid billing duplicate nodes
}

# ==============================================================================
# 5. SECURITY & IDENTITY (Route 53 Zone Creation & ACM)
# ==============================================================================
resource "aws_route53_zone" "main" {
  name = var.domain_name
}

resource "aws_acm_certificate" "cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "cert_val" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ==============================================================================
# 6. COMPUTE & AUTO SCALING (ALB + ASG Optimization)
# ==============================================================================
resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path = "/"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.cert_val.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_launch_template" "asg_template" {
  name_prefix   = "apache-server-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true # Cost Savings: Enabled direct public communication bypasses NAT requirements
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y apache2 nfs-common
              systemctl start apache2
              systemctl enable apache2
              
              mkdir -p /var/www/html
              mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.shared_code.dns_name}:/ /var/www/html
              
              echo "${aws_efs_file_system.shared_code.dns_name}:/ /var/www/html nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0" >> /etc/fstab
              
              echo "<h1>Hello from Secure Multi-Server Architecture</h1>" > /var/www/html/index.html
              EOF
  )
}

resource "aws_autoscaling_group" "web_asg" {
  vpc_zone_identifier = aws_subnet.public[*].id # Cost Savings: Moved EC2 fleet into Public Subnets
  target_group_arns   = [aws_lb_target_group.tg.arn]
  desired_capacity    = 1 # Cost Savings: Drop to exactly 1 instance to stay within 750 free hours
  max_size            = 1
  min_size            = 1

  launch_template {
    id      = aws_launch_template.asg_template.id
    version = "$Latest"
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_lb.web_alb.dns_name
    zone_id                = aws_lb.web_alb.zone_id
    evaluate_target_health = true
  }
}