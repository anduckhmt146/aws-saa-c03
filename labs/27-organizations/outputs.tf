output "organization_id" {
  value = aws_organizations_organization.main.id
}
output "organization_arn" {
  value = aws_organizations_organization.main.arn
}
output "master_account_id" {
  value = aws_organizations_organization.main.master_account_id
}
output "production_ou_id" {
  value = aws_organizations_organizational_unit.production.id
}
output "development_ou_id" {
  value = aws_organizations_organizational_unit.development.id
}
output "security_ou_id" {
  value = aws_organizations_organizational_unit.security.id
}
output "deny_leaving_org_policy_arn" {
  value = aws_organizations_policy.deny_leaving_organization.arn
}

output "control_tower_context" {
  description = <<-EOT
    Control Tower context and architecture reference for SAA-C03.
    Control Tower builds on Organizations to provide:
      - Landing Zone: Management + Log Archive + Audit accounts baseline
      - Account Factory: automated account provisioning (vending machine)
      - Guardrails: preventive (SCPs) + detective (Config rules) controls
      - Dashboard: org-wide compliance visibility
    SAA-C03 exam: "automate multi-account best practices" = Control Tower
    "account vending machine" = Account Factory
    "preventive guardrail" = SCP  |  "detective guardrail" = Config rule
  EOT
  value = {
    org_id                    = aws_organizations_organization.main.id
    management_account        = aws_organizations_organization.main.master_account_id
    guardrail_type_preventive = "SCP-based — blocks actions before they happen"
    guardrail_type_detective  = "Config-based — detects non-compliant resources"
    log_archive_account       = "Centralized CloudTrail + Config delivery"
    audit_account             = "Read-only cross-account security access"
  }
}
