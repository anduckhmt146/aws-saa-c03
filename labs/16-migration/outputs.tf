output "dms_instance_arn" { value = aws_dms_replication_instance.lab.replication_instance_arn }
output "datasync_s3_location_arn" { value = aws_datasync_location_s3.dest.arn }
output "transfer_server_endpoint" { value = aws_transfer_server.lab.endpoint }
output "transfer_server_id" { value = aws_transfer_server.lab.id }
output "backup_vault_name" { value = aws_backup_vault.lab.name }
output "backup_plan_id" { value = aws_backup_plan.lab.id }
output "datasync_bucket" { value = aws_s3_bucket.datasync_dest.id }

output "mgn_replication_template_arn" {
  description = <<-EOT
    ARN of the MGN Replication Configuration Template.
    SAA-C03: MGN (Application Migration Service) = lift-and-shift (re-host).
    Workflow: install agent → continuous replication → test launch → cutover.
    Minimal downtime: final sync is seconds/minutes (not hours like rsync).
    Free to use: pay only for EC2/EBS in the staging area.
    Exam: "migrate physical servers with minimal downtime" = MGN (not DMS, not SMS).
  EOT
  value       = aws_mgn_replication_configuration_template.main.arn
}
