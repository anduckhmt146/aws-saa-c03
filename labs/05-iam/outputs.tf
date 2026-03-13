output "iam_user_arn" {
  value = aws_iam_user.lab.arn
}

output "ec2_role_arn" {

  value = aws_iam_role.ec2_role.arn
}

output "lambda_role_arn" {

  value = aws_iam_role.lambda_role.arn
}

output "kms_key_id" {

  value = aws_kms_key.lab.key_id
}

output "kms_key_arn" {

  value = aws_kms_key.lab.arn
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}
output "permission_boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
output "access_analyzer_arn" {
  value = aws_accessanalyzer_analyzer.lab.arn
}
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.lab.id
}
output "cognito_user_pool_endpoint" {
  value = aws_cognito_user_pool.lab.endpoint
}
output "cognito_identity_pool_id" {
  value = aws_cognito_identity_pool.lab.id
}
output "developer_role_arn" {
  value = aws_iam_role.developer.arn
}

output "sso_read_only_permission_set_arn" {
  description = <<-EOT
    ARN of the IAM Identity Center ReadOnly permission set.
    SAA-C03: A Permission Set is a reusable IAM policy bundle deployed
    across one or more AWS accounts via account assignments.
    Think of it as a "role template" that Identity Center instantiates
    as IAM roles in each target account automatically.
    Exam: "centrally manage access to multiple accounts" = IAM Identity Center.
  EOT
  value       = aws_ssoadmin_permission_set.read_only.arn
}

output "sso_developer_permission_set_arn" {
  description = <<-EOT
    ARN of the Developer permission set (S3, DynamoDB, Lambda, CloudWatch).
    SAA-C03: Permission Sets can combine AWS managed policies AND inline policies.
    Session duration (PT8H = 8 hours) controls how long the SSO session lasts.
    After expiry: user must re-authenticate at the Identity Center portal.
    Exam: "session duration for SSO" = Permission Set session_duration (max 12h).
  EOT
  value       = aws_ssoadmin_permission_set.developer.arn
}

output "sso_developers_group_id" {
  description = <<-EOT
    Identity store group ID for the Developers group.
    SAA-C03: Groups in Identity Center map to SCIM groups from external IdPs.
    When Okta/Azure AD is the identity source, groups sync automatically via SCIM.
    Assign permission sets to GROUPS (not users) for scalable access management.
  EOT
  value       = aws_identitystore_group.developers.group_id
}
