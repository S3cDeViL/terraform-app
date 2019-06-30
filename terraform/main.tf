# Step1
variable "access_key" {}
variable "secret_key" {}
variable "region" {
  default = "ap-northeast-1"
}

provider "aws" {
  profile = "default"
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region = "${var.region}"
}

# Step2 VPCの作成
resource "aws_vpc" "tsujimoto_app" {
  cidr_block = "10.0.0.0/16"
  tags {
    Name = "tsujimoto_app VPC"
  }
}

# Step3 サブネットの作成
resource "aws_subnet" "tsujimoto_app_a" {
  vpc_id = "${aws_vpc.tsujimoto_app.id}"
  cidr_block = "10.0.1.0/24"
  availability_zone = "${var.region}a"
  tags {
    Name = "Public Subnet A"
  }
}

resource "aws_subnet" "tsujimoto_app_b" {
  vpc_id = "${aws_vpc.tsujimoto_app.id}"
  cidr_block = "10.0.2.0/24"
  availability_zone = "${var.region}c"
  tags {
    Name = "Public Subnet B"
  }
}

# Step4 インターネットゲートウェイの作成
resource "aws_internet_gateway" "tsujimoto_app" {
  vpc_id = "${aws_vpc.tsujimoto_app.id}"

  tags {
    Name = "tsujimotoapp Internet Gateway"
  }
}

# Step5 ルートテーブルの作成
resource "aws_route_table" "tsujimoto_app" {
  vpc_id = "${aws_vpc.tsujimoto_app.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.tsujimoto_app.id}"
  }

  tags {
    Name = "tsujimotoapp Route Table"
  }
}

# Step6 ルートテーブルとサブネットの紐づけ
resource "aws_route_table_association" "tsujimoto_app_a" {
  subnet_id = "${aws_subnet.tsujimoto_app_a.id}"
  route_table_id = "${aws_route_table.tsujimoto_app.id}"
}

resource "aws_route_table_association" "tsujimoto_app_b" {
  subnet_id = "${aws_subnet.tsujimoto_app_b.id}"
  route_table_id = "${aws_route_table.tsujimoto_app.id}"
}

# Step7 Security Groupの作成
resource "aws_security_group" "tsujimoto_app_security_alb" {
  name = "tsujimoto_app_security_alb"
  vpc_id = "${aws_vpc.tsujimoto_app.id}"

  ingress = {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  tags {
    Name = "tsujimotoapp ALB SG"
  }
}

resource "aws_security_group" "tsujimoto_app_security_group" {
  name = "tsujimoto_app_security_group"
  vpc_id = "${aws_vpc.tsujimoto_app.id}"

  ingress = {
    from_port = 0
    to_port = 65535
    protocol = "tcp"

    security_groups = [
      "${aws_security_group.tsujimoto_app_security_alb.id}",
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  tags {
    Name = "tsujimoto_app SG"
  }
}


# Step8: alb用のs3バケットの作成
resource "aws_s3_bucket" "tsujimoto_app_alb_log_bucket" {
  bucket = "tsujimoto-app-alb-log-bucket" 
  lifecycle_rule {
    enabled = true
    expiration {
      days = 180
    }
  }
}

data "aws_iam_policy_document" "tsujimoto_alb_log" {
  statement {
    effect = "Allow"
    actions = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.tsujimoto_app_alb_log_bucket.id}/*"]
    principals {
      type = "AWS"
      identifiers = ["582318560864"]
    }
  }
}

resource "aws_s3_bucket_policy" "tsujimoto_app_alb_log" {
  bucket = "${aws_s3_bucket.tsujimoto_app_alb_log_bucket.id}"
  policy = "${data.aws_iam_policy_document.tsujimoto_alb_log.json}"
}


# Step9: albの作成
resource "aws_alb" "tsujimoto_app_alb" {
  name = "tsujimoto-app-alb"
  security_groups = ["${aws_security_group.tsujimoto_app_security_alb.id}"]
  subnets = [
    "${aws_subnet.tsujimoto_app_a.id}",
    "${aws_subnet.tsujimoto_app_b.id}",
  ]
  internal = false
  enable_deletion_protection = true
  access_logs {
    bucket = "${aws_s3_bucket.tsujimoto_app_alb_log_bucket.id}"
    enabled = true
  }
}

resource "aws_alb_target_group" "tsujimoto_app_alb_target_group" {
  name = "tsujimoto-app-alb-target-group"
  port = 8000
  protocol = "HTTP"
  vpc_id = "${aws_vpc.tsujimoto_app.id}"
  target_type = "ip"

  health_check {
    interval = 60
    path = "/test_app"
    port = 80
    protocol = "HTTP"
    timeout = 30
    unhealthy_threshold = 3
    matcher = 200
  }
}

resource "aws_alb_listener" "tsujimoto_app" {
  load_balancer_arn = "${aws_alb.tsujimoto_app_alb.arn}"
  port = "80"
  protocol = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.tsujimoto_app_alb_target_group.arn}"
    type = "forward" # リクエストをターゲットグループに転送
  }
}

# Step10: ecsクラスターの作成
resource "aws_ecs_cluster" "tsujimoto_app" {
  name = "tsujimoto_app"
}


# Step11: Cloudwatchロググループの作成
resource "aws_cloudwatch_log_group" "tsujimoto_app_api" {
  name = "/ecs/api"
  retention_in_days = 180
}

resource "aws_cloudwatch_log_group" "tsujimoto_app_nginx" {
  name = "/ecs/nginx"
  retention_in_days = 180
}


# Step12: ECS Task Execution Roleの作成
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecs-task-execution"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_tasks_role.json}"
}

data "aws_iam_policy_document" "ecs_tasks_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ecs_task_execution" {
  name = "ecs-task-execution"
  policy =  <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Action": [
              "ecr:GetAuthorizationToken",
              "ecr:BatchCheckLayerAvailability",
              "ecr:GetDownloadUrlForLayer",
              "ecr:BatchGetImage",
              "logs:CreateLogStream",
              "logs:PutLogEvents"
          ],
          "Resource": "*"
      }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role = "${aws_iam_role.ecs_task_execution.name}"
  policy_arn = "${aws_iam_policy.ecs_task_execution.arn}"
}