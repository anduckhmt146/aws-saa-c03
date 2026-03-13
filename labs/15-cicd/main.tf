# ============================================================
# LAB 15 - CI/CD: CodeCommit, CodeBuild, CodeDeploy, CodePipeline
# Full pipeline: Source → Build → Deploy
# Exam: "CI/CD pipeline" → CodePipeline
#       "Automated deployment" → CodeDeploy
#       "Build and test" → CodeBuild
# ============================================================

data "aws_caller_identity" "current" {}
resource "random_id" "suffix" { byte_length = 4 }

# ============================================================
# S3 ARTIFACT BUCKET (CodePipeline stores artifacts here)
# ============================================================
resource "aws_s3_bucket" "artifacts" {
  bucket        = "lab-cicd-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artifacts" {

  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {

  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# CODECOMMIT REPOSITORY
# Managed private Git repository
# - Encryption at rest (KMS) and in transit
# - Integrates with CodeBuild, CodePipeline
# - Triggers: Lambda, SNS on push/PR events
# NOTE: AWS deprecated CodeCommit for new customers (use GitHub/GitLab via CodePipeline)
# ============================================================
resource "aws_codecommit_repository" "lab" {
  repository_name = var.repo_name
  description     = "SAA Lab 15 - CI/CD demo repository"

  tags = { Name = var.repo_name }
}

# ============================================================
# IAM ROLE FOR CODEBUILD
# ============================================================
resource "aws_iam_role" "codebuild" {
  name = "lab-codebuild-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "codebuild.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "codebuild" {

  name = "lab-codebuild-policy"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketAcl", "s3:GetBucketLocation"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codecommit:GitPull"]
        Resource = aws_codecommit_repository.lab.arn

      }
    ]
  })
}

# ============================================================
# CODEBUILD PROJECT
# Managed build service — compile, test, package
# - Serverless: pay per minute of build time
# - Docker-based: runs in containers
# - buildspec.yml: defines build commands
# ============================================================
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/lab-build"
  retention_in_days = 7
}

resource "aws_codebuild_project" "lab" {

  name          = "lab-build-project"
  description   = "Build and test lab application"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20 # minutes

  source {
    type      = "CODECOMMIT"
    location  = aws_codecommit_repository.lab.clone_url_http
    buildspec = "buildspec.yml" # Path to buildspec in repo
  }

  artifacts {

    type      = "S3"
    location  = aws_s3_bucket.artifacts.bucket
    packaging = "ZIP"
  }

  environment {

    compute_type                = "BUILD_GENERAL1_SMALL" # Smallest = cheapest
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.artifacts.bucket

    }

    environment_variable {

      name  = "ENVIRONMENT"
      value = "lab"

    }
  }

  logs_config {

    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
      status     = "ENABLED"

    }
  }

  tags = { Name = "lab-build-project" }
}

# ============================================================
# CODEDEPLOY
# Automated deployment to EC2, Lambda, ECS, on-premises
#
# Deployment Types:
#   In-Place:   Update existing instances (downtime possible)
#   Blue/Green: New instances → swap traffic → terminate old
#
# Deployment Configs:
#   AllAtOnce:    Deploy all at once (fastest, max downtime)
#   HalfAtATime:  50% at a time
#   OneAtATime:   1 instance at a time (safest, slowest)
#   Custom:       Define your own minimum healthy hosts
# ============================================================
resource "aws_iam_role" "codedeploy" {
  name = "lab-codedeploy-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "codedeploy.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {

  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

resource "aws_codedeploy_app" "lab" {

  name             = "lab-deploy-app"
  compute_platform = "Server" # Server (EC2), Lambda, ECS
}

# Deployment Group = set of EC2 instances to deploy to
resource "aws_codedeploy_deployment_group" "inplace" {
  app_name               = aws_codedeploy_app.lab.name
  deployment_group_name  = "lab-inplace-group"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.HalfAtATime"

  deployment_style {
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  # Target instances by tag
  ec2_tag_set {
    ec2_tag_filter {
      key   = "Environment"
      type  = "KEY_AND_VALUE"
      value = "lab"

    }
  }

  auto_rollback_configuration {

    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

resource "aws_codedeploy_deployment_group" "bluegreen" {

  app_name               = aws_codedeploy_app.lab.name
  deployment_group_name  = "lab-bluegreen-group"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ec2_tag_set {

    ec2_tag_filter {
      key   = "Environment"
      type  = "KEY_AND_VALUE"
      value = "lab"

    }
  }

  blue_green_deployment_config {

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5

    }

    deployment_ready_option {

      action_on_timeout = "CONTINUE_DEPLOYMENT"

    }

    green_fleet_provisioning_option {

      action = "DISCOVER_EXISTING"

    }
  }

  auto_rollback_configuration {

    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
}

# ============================================================
# CODEPIPELINE
# CI/CD orchestration: Source → Build → Test → Deploy
# Stages: at least Source + one more stage required
# Actions: CodeCommit, S3, GitHub, ECR (source)
#          CodeBuild (build/test)
#          CodeDeploy, CloudFormation, ECS (deploy)
#          Lambda, SNS, Manual Approval (invoke/approve)
# ============================================================
resource "aws_iam_role" "codepipeline" {
  name = "lab-codepipeline-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "codepipeline.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {

  name = "lab-codepipeline-policy"
  role = aws_iam_role.codepipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketVersioning", "s3:PutObjectAcl", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codecommit:CancelUploadArchive", "codecommit:GetBranch", "codecommit:GetCommit", "codecommit:GetUploadArchiveStatus", "codecommit:UploadArchive"]
        Resource = aws_codecommit_repository.lab.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = aws_codebuild_project.lab.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codedeploy:CreateDeployment", "codedeploy:GetApplication", "codedeploy:GetApplicationRevision", "codedeploy:GetDeployment", "codedeploy:GetDeploymentConfig", "codedeploy:RegisterApplicationRevision"]
        Resource = "*"

      }
    ]
  })
}

resource "aws_codepipeline" "lab" {

  name     = "lab-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # Stage 1: Source (CodeCommit)
  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        RepositoryName       = aws_codecommit_repository.lab.repository_name
        BranchName           = "main"
        DetectChanges        = "true" # Auto-trigger on push
        PollForSourceChanges = "false"

      }

    }
  }

  # Stage 2: Build (CodeBuild)
  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.lab.name

      }

    }
  }

  # Stage 3: Approval (Manual gate before production)
  stage {
    name = "Approval"
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        CustomData = "Please review the build output and approve deployment."

      }

    }
  }

  # Stage 4: Deploy (CodeDeploy)
  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      version         = "1"
      input_artifacts = ["build_output"]
      configuration = {
        ApplicationName     = aws_codedeploy_app.lab.name
        DeploymentGroupName = aws_codedeploy_deployment_group.inplace.deployment_group_name

      }

    }
  }
}

# ============================================================
# CODEARTIFACT (Artifact/Package Repository)
# Stores: Maven, npm, PyPI, NuGet packages
# Use case: internal packages, proxy public repos
# ============================================================
resource "aws_codeartifact_domain" "lab" {
  domain = "lab-domain"
}

resource "aws_codeartifact_repository" "lab" {

  repository = "lab-repo"
  domain     = aws_codeartifact_domain.lab.domain

  # Upstream = proxy public repos (npm, PyPI, Maven Central)
  upstream {
    repository_name = aws_codeartifact_repository.upstream.repository
  }
}

resource "aws_codeartifact_repository" "upstream" {

  repository = "lab-upstream"
  domain     = aws_codeartifact_domain.lab.domain

  external_connections {
    external_connection_name = "public:npmjs" # Proxy npmjs.com
  }
}
