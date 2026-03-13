output "codecommit_clone_url" { value = aws_codecommit_repository.lab.clone_url_http }
output "codebuild_project_name" { value = aws_codebuild_project.lab.name }
output "codedeploy_app_name" { value = aws_codedeploy_app.lab.name }
output "pipeline_name" { value = aws_codepipeline.lab.name }
output "artifacts_bucket" { value = aws_s3_bucket.artifacts.id }
output "codeartifact_domain" { value = aws_codeartifact_domain.lab.domain }
output "codeartifact_repo" { value = aws_codeartifact_repository.lab.repository }
