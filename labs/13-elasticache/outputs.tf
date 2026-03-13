output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}
output "redis_reader_endpoint" {
  value = aws_elasticache_replication_group.redis.reader_endpoint_address
}
output "memcached_endpoint" {
  value = aws_elasticache_cluster.memcached.cluster_address
}
output "redis_port" { value = 6379 }
output "memcached_port" { value = 11211 }
