# This file is to create ECS to connect to RDS for Data ETL and Analysis


#============================================================
#0 to build docker image and push it to ECR (files will be shared in another repository)

#1 to create VPC with private subnets for ECS Fargate in each AZ (in another file)
  # for security reason, ECS should be in the private subnets
  # if ecs needs to pull from ECR, fetch secret from Secrets Manager,
  # ECR, Secrects Manager, etc, only provide public API 
  # ECS has to access them using internet gateway (internet traffic + public subnets), 
  # or NAT gateway (internet traffic + private subnets), or VPC Endpoints (Amazon network + private subnets)
  # the last 2 options will be more secure. What I most concern between them is cost.
  # One NAT gateway equals 4.5 times of VPC Endpoints. If more than 4 Endpoints (interface type) are deployed, I will choose NAT.
# private subnets--> 2 route tables--> 2 subnets--> 4 interface VPC Endpoints

#2 to create SG for ECS and VPC Endpoint
#3 to set up Interface VPC Endpoint for Secrect Manager, ECR DKR, ECR API, CloudWatch logs
  # to set up Gateway VPC Endpoint for S3
  # ECR requires 3 endpoints to work (one is gateway s3 endpoint, free),
  # the total interface endpoints for fargate are 4.
  # if in future more interface VPC endpoints are needed, delete them all and create NAT gateway
  # because NAT gateway is less expensive than 5 interface VPC endpoints

#4 to create ECS Cluster --> Service --> task definition --> Containers
    # for ECS cluster
    #4.0 to create log group for ECS 
    #4.1 to create ECS cluster
    #4.2 to create Task definition
      #4.2.1 to create role 1 --> Task Role
        # task role is to allow ECS to access other AWS services for tasks(s3, RDS, etc)
      #4.2.2 to create role 2 --> Execution Role
        # execution role is to allow ECS to access CloudWatch Logs, ECR, Secrets Manager. 
    #4.3 to create ECS task
    #4.4 to create ECS service
      # Note: if you need to set up different containers for one task, just combine their container definitions
      # into one under the same container definition json format.
#5 to create ALB (in another file)
#6 to set up Auto Scaling 
#7 the next is to write python file for ECS task, be included into docker image
#============================================================
#0 As another repo will share the dockerfile, python scripts, below are just general steps
  # Note: I prefer to create certain resources using AWS Console or CLI because these resources 
  # are not changing frequently. Like secrets managers, ACM (Certificates), Route53 hosted zones,
  # ECR, etc
  /*
  #0.1 to create private repo in ECR:
    # ("$" is not included in the command)
    $ aws ecr create-repository \
      --repository-name abcd \        
      --image-scanning-configuration scanOnPush=true \
      --region ca-central-1
  # the response should be like:
  {
      "repository": {
          "repositoryArn": "arn:.....",
          "registryId": "1234567890",
          "repositoryName": "abcd",
          "repositoryUri": "1234567890.dkr.ecr.ca-central-1.amazonaws.com/abcd",
          "createdAt": "2023-06-07T23:31:09-04:00",
          "imageTagMutability": "MUTABLE",
          "imageScanningConfiguration": {
              "scanOnPush": true
          },
          "encryptionConfiguration": {
              "encryptionType": "AES256"
          }
      }
  }
  (END)
  #0.2 to login your own repo
    $ aws ecr get-login-password --region ca-central-1 | docker login --username AWS --password-stdin 1234567890.dkr.ecr.ca-central-1.amazonaws.com
  #0.3 to build docker image
    $ docker build -t aaa .
  #0.4 to tag image as latest
    $ docker tag aaa:latest 1234567890.dkr.ecr.ca-central-1.amazonaws.com/abcd    
  #0.5 to push/pull from ECR    
    $ docker push 1234567890.dkr.ecr.ca-central-1.amazonaws.com/abcd  
    $ docker pull 1234567890.dkr.ecr.ca-central-1.amazonaws.com/abcd:latest

  0.6 to test docker right after building
    $ docker container run -it aaa /bin/bash
  0.7 to see what inside the container 
    $ ls
  0.8 to find mysql
    $ pip install mysql
    the result showed all packages are installed in /usr/local/lib/python3.10
  0.9 to get mysql path 
    $ which mysql
    the result: /usr/bin/mysql
  0.10 to connect local mysql using command line
    $ mysql -h host.docker.internal -u your_user_name -pyour_pass_word -D your_db
  0.11 to execute sql file using mysql command line 
    $ mysql -h host.docker.internal -u your_user_name -pyour_pass_word -D your_db < /init.sql

  0.12 when we use docker run to start a container
    we can use 'docker ps' to check the container status in a new terminal window
    and use 'docker logs container_id' to check and debug
    */
############################
###### Security Group ######
############################
#2 SG for ECS
resource "aws_security_group" "ecs_service" {
  name   = "${local.prefix}-sg-ecs-service"
  vpc_id = aws_vpc.web_vpc.id
  
  ingress {
    from_port   = local.ecs_container_port_1st
    to_port     = local.ecs_container_port_1st
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.web_vpc.cidr_block]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.web_vpc.cidr_block]
  }
  
  egress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.private-s3.prefix_list_id]
  }
  # in order to use s3 prefix list
  # ecs task role needs to be granted the permissions
  tags = {
    Name="${local.prefix}-sg-ecs-service"
  }
}

# allow rds <--> ecs
#allow access between ecs and rds
resource "aws_security_group_rule" "ecs_to_rds" {
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  #=====================================================
  source_security_group_id =aws_security_group.ecs_service.id
  #=====================================================
  security_group_id = aws_security_group.rds.id
  depends_on = [ aws_security_group.rds, aws_security_group.ecs_service]
}
resource "aws_security_group_rule" "rds_to_ecs" {
  type            = "ingress"
  from_port       = 3306
  to_port         = 3306
  protocol        = "tcp"
  #=====================================================
  source_security_group_id = aws_security_group.rds.id
  #=====================================================
  security_group_id = aws_security_group.ecs_service.id
  depends_on = [ aws_security_group.rds, aws_security_group.ecs_service]
}
resource "aws_security_group_rule" "rds_to_ecs2" {
  type              = "egress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  #=====================================================
  source_security_group_id =aws_security_group.ecs_service.id
  #=====================================================
  security_group_id = aws_security_group.rds.id
  depends_on = [ aws_security_group.rds, aws_security_group.ecs_service]
}
resource "aws_security_group_rule" "ecs_to_rds2" {
  type            = "egress"
  from_port       = 3306
  to_port         = 3306
  protocol        = "tcp"
  #=====================================================
  source_security_group_id = aws_security_group.rds.id
  #=====================================================
  security_group_id = aws_security_group.ecs_service.id
  depends_on = [ aws_security_group.rds, aws_security_group.ecs_service]
}

#############################
###### VPC Endpoints   ######
#############################
# SG for VPC Endpoint
# we needs ENDpoints to accept requests from ECS on port 443
resource "aws_security_group" "example" {
  name        = "${local.prefix}-sg-example"
  description = "VPC endponts must accept requests from ECS"
  vpc_id      = aws_vpc.web_vpc.id

  tags = {
    Name = "${local.prefix}-sg-example"
  }
}
resource "aws_security_group_rule" "ecs_to_vpc_endpoints" {
  type            = "ingress"
  from_port       = 443
  to_port         = 443
  protocol        = "tcp"
  source_security_group_id = aws_security_group.ecs_service.id

  security_group_id = aws_security_group.vpc_endpoints_ecr_secret_logs.id 
  depends_on = [ aws_security_group.vpc_endpoints_ecr_secret_logs, aws_security_group.ecs_service]
}
resource "aws_security_group_rule" "ecs_to_vpc_endpoints2" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  #=====================================================
  source_security_group_id =aws_security_group.vpc_endpoints_ecr_secret_logs.id
  #=====================================================
  security_group_id = aws_security_group.ecs_service.id
  depends_on = [ aws_security_group.vpc_endpoints_ecr_secret_logs, aws_security_group.ecs_service]
}
#3 there are 3 endpoints for ECR: 
data "aws_route_tables" "ecs" {
  depends_on = [ aws_route_table.nat_gateway ]
  filter {
    name = "tag:Name"
    values = ["${local.prefix}-router-ecs"]
  }
}

resource "aws_vpc_endpoint" "private-s3" {
  vpc_id = aws_vpc.web_vpc.id
  service_name = "com.amazonaws.${local.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = data.aws_route_tables.ecs.ids 
  /* >>>>>>>>>>>>>>>>> */
  policy = <<POLICY
  {
    "Statement": [
      {
        "Sid": "ecr",
        "Effect": "Allow",
        "Principal": "*",
        "Action": [
          "s3:GetObject"
        ],
        "Resource": [
          "arn:aws:s3:::prod-${local.aws_region}-starport-layer-bucket/*"
        ]
      },
      {
        "Sid": "backupbucket",
        "Effect": "Allow",
        "Principal": "*",
        "Action": [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ],
        "Resource": [
          "${var.bucket_arn}",
          "${var.bucket_arn}/*"
        ]
      }
    ]
  }
  POLICY

  tags = {
    Name="${local.prefix}-vpv-endpoint-gateway-s3"
  }
}
# the policies for dkr and api are the same
# dkr is to pull /push images
# api is for other actions

resource "aws_vpc_endpoint" "ecr-dkr" {
  vpc_id            = aws_vpc.web_vpc.id
  private_dns_enabled = true
  service_name      = "com.amazonaws.${local.aws_region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
  subnet_ids = local.private_subnets
  security_group_ids = [aws_security_group.example.id]
  
  /* >>>>>>> */
  policy = <<POLICY
  {
    "Statement": [

      {
        "Effect": "Allow",
        "Action": [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"  
        ],
        "Resource": "arn:aws:ecr:${local.aws_region}:${local.AccountID}:repository/${local.repo_name}",
        "Principal": "*"
      },
      {
        "Effect": "Allow",
        "Action": "ecr:GetAuthorizationToken",
        "Resource": "*",
        "Principal": "*"
      },
      {
        "Action": "ecr:DeleteRepository",
        "Effect": "Deny",
        "Principal": "*",
        "Resource": "arn:aws:ecr:${local.aws_region}:${local.AccountID}:repository/${local.repo_name}"
      }
    ]
  }
  POLICY
 
  tags = {
    Name="${local.prefix}-vpc-endpoint-interface-ecr-dkr"
  }
}
resource "aws_vpc_endpoint" "ecr-api" {
  vpc_id            = aws_vpc.web_vpc.id
  private_dns_enabled = true
  service_name      = "com.amazonaws.${local.aws_region}.ecr.api"
  vpc_endpoint_type = "Interface"
  subnet_ids = local.private_subnets
  security_group_ids = [aws_security_group.example.id]
  
/* >>>>>>> */
policy = <<POLICY
 {
    "Statement": [
      {
        "Action": "ecr:*",
        "Effect": "Allow",
        "Principal": "*",
        "Resource": "arn:aws:ecr:${local.aws_region}:${local.AccountID}:repository/${local.repo_name}"
      },
      {
        "Effect": "Allow",
        "Action": [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"  
        ],
        "Resource": "arn:aws:ecr:${local.aws_region}:${local.AccountID}:repository/${local.repo_name}",
        "Principal": "*"
      },
      {
        "Effect": "Allow",
        "Action": "ecr:GetAuthorizationToken",
        "Resource": "*",
        "Principal": "*"
      },
      {
        "Action": "ecr:DeleteRepository",
        "Effect": "Deny",
        "Principal": "*",
        "Resource": "arn:aws:ecr:${local.aws_region}:${local.AccountID}:repository/${local.repo_name}"
      }
    ]
  }
POLICY

  tags = {
    Name="${local.prefix}-vpc-endpoint-interface-ecr-api"
  }
}

resource "aws_vpc_endpoint" "cloudwatch" {
  vpc_id            = aws_vpc.web_vpc.id
  private_dns_enabled = true
  service_name      = "com.amazonaws.${local.aws_region}.logs"
  vpc_endpoint_type = "Interface"
  subnet_ids = local.private_subnets
  security_group_ids = [aws_security_group.vpc_endpoints_ecr_secret_logs.id]
  
/* >>>>>>>> */
  policy = <<POLICY
  {
    "Statement": [
      {
        "Principal": "*",
        "Action":  [
          "logs:CreateLogStream",
          "logs:CreateLogGroup",
          "logs:PutLogEvents"
        ],
        "Resource":  [
          "arn:aws:logs:${local.aws_region}:${local.AccountID}:log-group:${local.ecs_cluster_log_group}:*",
          "arn:aws:logs:${local.aws_region}:${local.AccountID}:log-group:${local.ecs_cluster_log_group}:log-stream:*"
        ],
        "Effect": "Allow"
      }
    ]
  }  
POLICY

  tags = {
    Name="${local.prefix}-vpc-endpoint-interface-cloudwatch"
  }
}
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id            = aws_vpc.web_vpc.id
  service_name      = "com.amazonaws.${local.aws_region}.secretsmanager"
  vpc_endpoint_type = "Interface"
  subnet_ids = local.private_subnets
  security_group_ids = [aws_security_group.example.id]
  private_dns_enabled = true
/* >>>>>>> */
  policy = <<POLICY
  {
    "Statement": [
      {
        "Principal": "*",
        "Action": "secretsmanager:GetSecretValue",
        "Effect": "Allow",
        "Resource": [
          "${local.mysql-creds-arn}", 
          "${local.mysql-creds-db-maintanance-arn}"
        ]
      }
    ]
  }  
POLICY

  tags = {
    Name="${local.prefix}-vpc-endpoint-interface-secret"
  }
}
# two secrets, one is master user
# the other is user for detailed work
#############################
###### Private Fargate ######
#############################
locals {
  ecs_cluster_log_group     = "ecs/fargate/${local.prefix}"
}
#4 ECS Cluster
resource "aws_cloudwatch_log_group" "ecs" {
  name = local.ecs_cluster_log_group
  tags = {
    Environment = "dev"
  }
}

resource "aws_ecs_cluster" "example" {
  depends_on = [ aws_cloudwatch_log_group.ecs ]
  name = "${local.prefix}-ecs-cluster"
  tags = {
    Name        = "${local.prefix}-ecs-cluster"
    Environment = var.environment
  }
}

# container definition for task

locals {
  repo_name                 = local.prefix
  task_image_1              = "${local.AccountID}.dkr.ecr.${local.aws_region}.amazonaws.com/${local.prefix}:latest"
  ecs_container_port_1st    = 80
  ecs_container_port_2nd    = 443
  container_definition = [{
    cpu         = 1024
    image       = local.task_image_1
    memory      = 2048
    name        = "${local.prefix}-container-1"
    networkMode = "awsvpc"
    environment = [
      {"name":"task", "value": "rds_init"},
      # one container may do multiple tasks
      {"name":"rds_endpoint", "value": "${aws_db_instance.mysql.endpoint}"}, 
      {"name":"aws_region", "value": "${local.aws_region}"},
      {"name":"mysql_database", "value": "${aws_db_instance.mysql.db_name}"}
    ] 
    secrets=[
      {"name":"secret_string", "valueFrom":"${local.mysql-creds-arn}"} ,
      {"name":"secret_string_db_maintain", "valueFrom":"${local.mysql-creds-db-maintanance-arn}"}
    ]
    # the above environment variables will be passed in to containers
    portMappings = [
      {
        protocol      = "tcp"
        containerPort = local.ecs_container_port_1st
        hostPort      = local.ecs_container_port_1st
      }
    ]
    logConfiguration = {
      logdriver = "awslogs"
      options = {
        "awslogs-group"         = local.ecs_cluster_log_group
        "awslogs-region"        = local.aws_region
        "awslogs-stream-prefix" = "fargate"
      }
    }
    # make sure to export logs to cloudwatch for debugging
  }]
}

# ecs task role
resource "aws_iam_role" "ecs_task_role" {
  name = "${local.prefix}-ecsTaskRole"

  assume_role_policy = <<EOF
  {
   "Version":"2012-10-17",
   "Statement":[
      {
         "Effect":"Allow",
         "Principal":{
            "Service":[
               "ecs-tasks.amazonaws.com"
            ]
         },
         "Action":"sts:AssumeRole",
         "Condition":{
            "ArnLike":{
            "aws:SourceArn":"arn:aws:ecs:${local.aws_region}:${local.AccountID}:*"
            },
            "StringEquals":{
               "aws:SourceAccount":"${local.AccountID}"
            }
         }
      }
    ]
  }
EOF
}

# policy for task role --> CloudWatch
resource "aws_iam_policy" "ecs_logging_policy" {
  name   = "${local.prefix}-ecs-log-task"
  policy =  <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
        "Effect": "Allow",
        "Action": [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
        ],
        "Resource":[
          "arn:aws:logs:${local.aws_region}:${local.AccountID}:log-group:${local.ecs_cluster_log_group}:*",
          "arn:aws:logs:${local.aws_region}:${local.AccountID}:log-group:${local.ecs_cluster_log_group}:log-stream:*"
        ]
    }
  ]
}
EOF
}
# policy for task role --> RDS (according to aws, no need to create policy to connect to RDS)
# policy for task role --> s3
resource "aws_iam_policy" "ecs_s3" {
  name        = "${local.prefix}-policy-ECS-S3"
  path        = "/"
  description = "Attached to ecs. it allows ecs to access s3"
  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "VisualEditor1",
        "Effect": "Allow",
        "Action": [
            "s3:PutObject",
            "s3:GetObject",
            "s3:ListBucket",
            "s3:DeleteObject",
            "s3:GetBucketLocation"
        ],
        "Resource": [
            "${var.bucket_arn}",
            "${var.bucket_arn}/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:GetManagedPrefixListAssociations",
          "ec2:GetManagedPrefixListEntries",
          "ec2:ModifyManagedPrefixList",
          "ec2:RestoreManagedPrefixListVersion"
        ],
        "Resource": "arn:aws:ec2:${local.aws_region}:aws:prefix-list/${aws_vpc_endpoint.private-s3.prefix_list_id}"
      },
      {
        "Effect": "Allow",
        "Action": "ec2:DescribeManagedPrefixLists",
        "Resource": "*"
      }
        
    ]
})
}
# if we attach AWS managed policy to the role
# can use terraform to find its arn
# ECS doesnot need policy to access RDS
# it needs SG settings to connect to RDS 
resource "aws_iam_role_policy_attachment" "ecs-task-role-policy-attachment" {
  for_each =zipmap(
  [0,1],
  [
    tostring(aws_iam_policy.ecs_logging_policy.arn),
    tostring(aws_iam_policy.ecs_s3.arn)
  ])
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = each.value
}
# ECS Task Execution role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.prefix}-ecs-TaskExecutionRole"

  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
# execution role is responsible for log, ecr and secrets
# policy for task execution role -> ECR 
resource "aws_iam_policy" "ECR" {
  name        = "${local.prefix}-policy-ecs-ecr"
  description = "Attached to ECS. it allows ECS to pull from ecr"
 
  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"  
        ],
        "Resource": "arn:aws:ecr:${local.aws_region}:${local.AccountID}:repository/${local.repo_name}"
      },
      {
        "Effect": "Allow",
        "Action": [
            "ecr:GetAuthorizationToken"
        ],
        "Resource": "*"
      }
    ]
})
}
# policy for task execution role -> Secrets 

resource "aws_iam_policy" "SecretsManager" {
  name        = "${local.prefix}-policy-ecs-secretsmanager"
  path        = "/"
  description = "Attached to ECS. it allows ECS to get secrect of RDS"
 
  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
          "Effect": "Allow",
          "Action": [
            "secretsmanager:GetSecretValue",
            "ssm:GetParameters",
            "kms:Decrypt"
          ],
          "Resource": [
              "${local.mysql-creds-arn}",
              "${local.mysql-creds-db-maintanance-arn}"
          ]
      }
    ]
})
}

resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment-2" {

  for_each =zipmap(
  [0,1,2],
  [
    tostring(aws_iam_policy.ECR.arn),
    tostring(aws_iam_policy.SecretsManager.arn),
    tostring(aws_iam_policy.ecs_logging_policy.arn)
  ])
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = each.value
}
################################
###### task definition #########
################################
locals {
  # below variables are created for policy creation
  task_arn_without_version=join(":",["arn:aws:ecs","${local.aws_region}","${local.AccountID}","task-definition/${aws_ecs_task_definition.example.family}"])
  task_id_for_lambda_policy=join(":",["arn:aws:ecs","${local.aws_region}","${local.AccountID}","task/*"])
}
resource "aws_ecs_task_definition" "example" {
  depends_on = [ aws_db_instance.mysql ]
  family = "${local.prefix}-family-ecs-containers"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.container_definition.0.cpu
  memory                   = local.container_definition.0.memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  
  container_definitions = jsonencode(local.container_definition)
  
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture = "X86_64"
  }
}

# ecs service
# ECS Service decides how many and how the tasks will run within which cluster
# below service can be omitted if we wish ecs container is triggered by lambda 
# for those situation where ecs service is needed for auto scaling, please refer to file '08-03'
/*
resource "aws_ecs_service" "example" {
  name                 = "${local.prefix}-ecs-service"
  #define cluser
  cluster              = aws_ecs_cluster.example.id
  #define task
  task_definition      = aws_ecs_task_definition.example.arn
  launch_type          = "FARGATE"
  #scheduling_strategy  = "REPLICA"
  desired_count        = 1
  #force_new_deployment = true
  #deployment_minimum_healthy_percent = 50
  #deployment_maximum_percent         = 200

  network_configuration {
    subnets          = local.private_subnets
    assign_public_ip = false
    security_groups = [
      aws_security_group.ecs_service.id
    ]
  }
}

#6 below is to setup auto scaling

resource"aws_appautoscaling_target""ecs_target" {

  max_capacity       =2

  min_capacity       =1

  resource_id        ="service/${aws_ecs_cluster.example.name}/${aws_ecs_service.example.name}"

  scalable_dimension="ecs:service:DesiredCount"

  service_namespace  ="ecs"

}

resource"aws_appautoscaling_policy""ecs_policy_memory" {

  name               ="${local.prefix}-autoscaling-ecs-memory"

  policy_type        ="TargetTrackingScaling"

  resource_id        =aws_appautoscaling_target.ecs_target.resource_id

  scalable_dimension=aws_appautoscaling_target.ecs_target.scalable_dimension

  service_namespace  =aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {

    predefined_metric_specification {

    predefined_metric_type="ECSServiceAverageMemoryUtilization"

    }

    target_value=80

  }

}

resource"aws_appautoscaling_policy""ecs_policy_cpu" {

  name               ="${local.prefix}-autoscaling-ecs-cpu"

  policy_type        ="TargetTrackingScaling"

  resource_id        =aws_appautoscaling_target.ecs_target.resource_id

  scalable_dimension=aws_appautoscaling_target.ecs_target.scalable_dimension

  service_namespace  =aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {

    predefined_metric_specification {

    predefined_metric_type="ECSServiceAverageCPUUtilization"

    }

    target_value=80

  }
}
*/