output "vpc_id" {
  value = aws_vpc.lab.id
}

output "vpc_cidr" {

  value = aws_vpc.lab.cidr_block
}

output "public_subnet_ids" {

  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {

  value = aws_subnet.private[*].id
}

output "nat_gateway_ip" {

  value = aws_eip.nat.public_ip
}

output "web_sg_id" {

  value = aws_security_group.web.id
}

output "app_sg_id" {

  value = aws_security_group.app.id
}

output "db_sg_id" {

  value = aws_security_group.db.id
}
