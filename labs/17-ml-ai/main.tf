# ============================================================
# LAB 17 - ML/AI Services: SageMaker, Rekognition, Comprehend,
#          Polly, Transcribe, Translate, Lex, Forecast, Personalize
# Most AI services are API-based — infrastructure is minimal
# Focus: IAM roles, S3 buckets, SageMaker notebook/endpoint
# ============================================================

data "aws_caller_identity" "current" {}
resource "random_id" "suffix" { byte_length = 4 }

# ============================================================
# S3 BUCKETS for ML workflows
# ============================================================
resource "aws_s3_bucket" "ml_data" {
  bucket        = "lab-ml-data-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket" "ml_models" {
  bucket        = "lab-ml-models-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket" "ml_output" {
  bucket        = "lab-ml-output-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

locals {

  buckets = [aws_s3_bucket.ml_data, aws_s3_bucket.ml_models, aws_s3_bucket.ml_output]
}

resource "aws_s3_bucket_public_access_block" "ml" {
  for_each                = { data = aws_s3_bucket.ml_data.id, models = aws_s3_bucket.ml_models.id, output = aws_s3_bucket.ml_output.id }
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# SAGEMAKER
# Build, train, deploy ML models
# Components:
#   Notebook Instance: Jupyter for exploration
#   Training Job: Run training algorithm
#   Model: Trained artifact
#   Endpoint Config: Instance type + model
#   Endpoint: Real-time inference API
# ============================================================
resource "aws_iam_role" "sagemaker" {
  name = "lab-sagemaker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {

  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "sagemaker_s3" {

  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# SageMaker Notebook Instance (Jupyter)
resource "aws_sagemaker_notebook_instance" "lab" {
  name          = "lab-notebook"
  role_arn      = aws_iam_role.sagemaker.arn
  instance_type = "ml.t3.medium" # Cheapest notebook instance

  # Volume for notebook storage
  volume_size = 5 # GB

  tags = { Name = "lab-sagemaker-notebook" }
}

# SageMaker Domain (Studio — modern unified IDE)
# Commented out as it has significant setup cost/complexity
# resource "aws_sagemaker_domain" "lab" {
#   domain_name = "lab-domain"
#   auth_mode   = "IAM"
#   vpc_id      = data.aws_vpc.default.id
#   subnet_ids  = data.aws_subnets.default.ids
#   default_user_settings {
#     execution_role = aws_iam_role.sagemaker.arn
#   }
# }

# SageMaker Model (reference a pre-built container)
resource "aws_sagemaker_model" "lab" {
  name               = "lab-xgboost-model"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    # AWS built-in XGBoost container
    image          = "683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.7-1"
    model_data_url = "s3://${aws_s3_bucket.ml_models.bucket}/model.tar.gz"
    environment = {
      SAGEMAKER_PROGRAM = "train.py"

    }
  }
}

# SageMaker Endpoint Config
resource "aws_sagemaker_endpoint_configuration" "lab" {
  name = "lab-endpoint-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.lab.name
    instance_type          = "ml.t2.medium" # Cheapest inference instance
    initial_instance_count = 1
  }
}

# SageMaker Endpoint (Real-time inference)
resource "aws_sagemaker_endpoint" "lab" {
  name                 = "lab-inference-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.lab.name

  tags = { Name = "lab-inference-endpoint" }
}

# ============================================================
# REKOGNITION - Image and Video Analysis
# Use case: face detection, object recognition, content moderation
# API-based (no infrastructure to provision)
# Just need IAM permissions
# ============================================================
resource "aws_iam_role" "rekognition" {
  name = "lab-rekognition-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rekognition.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rekognition" {

  role       = aws_iam_role.rekognition.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRekognitionFullAccess"
}

# Rekognition Custom Labels project
resource "aws_rekognition_project" "lab" {
  name = "lab-custom-labels"
}

# ============================================================
# COMPREHEND - Natural Language Processing (NLP)
# Use case: sentiment analysis, entity extraction, topic modeling
# Languages: 100+ supported
# ============================================================
resource "aws_iam_role" "comprehend" {
  name = "lab-comprehend-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "comprehend.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "comprehend_s3" {

  role       = aws_iam_role.comprehend.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# ============================================================
# POLLY - Text-to-Speech
# Use case: voice apps, accessibility
# Engines: Standard, Neural (more natural)
# Output: MP3, OGG, PCM
# ============================================================
resource "aws_iam_role" "polly_lambda" {
  name = "lab-polly-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "polly_lambda" {

  name = "lab-polly-policy"
  role = aws_iam_role.polly_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["polly:SynthesizeSpeech", "polly:DescribeVoices"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["translate:TranslateText"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["comprehend:DetectSentiment", "comprehend:DetectEntities", "comprehend:DetectLanguage"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["rekognition:DetectLabels", "rekognition:DetectFaces", "rekognition:DetectModerationLabels"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.ml_output.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"

      }
    ]
  })
}

# ============================================================
# LEX - Chatbot Builder (same tech as Alexa)
# V2 is current (V1 deprecated)
# Use case: customer service bots, voice interfaces
# Components: Bot, Bot locale, Intent, Slot, Fulfillment (Lambda)
# ============================================================
resource "aws_iam_role" "lex" {
  name = "lab-lex-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lexv2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lex" {

  role       = aws_iam_role.lex.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonLexFullAccess"
}

resource "aws_lexv2models_bot" "lab" {

  name     = "LabSupportBot"
  role_arn = aws_iam_role.lex.arn

  data_privacy {
    child_directed = false
  }

  idle_session_ttl_in_seconds = 300

  tags = { Name = "lab-lex-bot" }
}

# ============================================================
# TRANSCRIBE - Speech-to-Text
# Use case: transcribe call recordings, subtitles, meeting notes
# Features: speaker diarization, custom vocabulary, PII redaction
# ============================================================

# Transcribe vocabulary (improve accuracy for domain terms)
resource "aws_transcribe_vocabulary" "lab" {
  vocabulary_name = "lab-vocabulary"
  language_code   = "en-US"
  phrases         = ["AWS", "SAA-C03", "terraform", "CloudFormation"]
}

# ============================================================
# CLOUDWATCH LOG GROUP for AI/ML jobs
# ============================================================
resource "aws_cloudwatch_log_group" "ml" {
  name              = "/aws/sagemaker/lab"
  retention_in_days = 7
}
