SHELL := /bin/bash
SCRIPT := ./create-lab-roles.sh
REGION ?= us-east-1

.PHONY: help setup cleanup reset list tag-all resources unset session

help:
	@echo "Usage:"
	@echo "  make setup          Create all 50 IAM lab roles (run once)"
	@echo "  make cleanup        Delete all lab roles"
	@echo "  make reset          Delete and recreate all roles (cleanup + setup)"
	@echo "  make list           List all roles and their status"
	@echo "  make tag-all        Tag all existing roles with Environment=lab"
	@echo "  make resources      List all tagged lab resources in AWS"
	@echo "  make unset          Clear assumed-role session credentials"
	@echo "  make session LAB=<name>  Print the source command for a lab session"
	@echo ""
	@echo "Examples:"
	@echo "  make setup"
	@echo "  make reset"
	@echo "  source \$$(make -s session LAB=01-ec2)"
	@echo "  eval \"\$$(make -s session LAB=01-ec2)\""

setup:
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; \
	$(SCRIPT) setup

cleanup:
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; \
	$(SCRIPT) cleanup

reset: cleanup setup

list:
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; \
	$(SCRIPT) list

tag-all:
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; \
	$(SCRIPT) tag-all

resources:
	aws resourcegroupstaggingapi get-resources \
	  --region $(REGION) \
	  --tag-filters Key=Environment,Values=lab \
	  --query 'ResourceTagMappingList[].ResourceARN' \
	  --output text

unset:
	@echo "Run this in your shell:"
	@echo "  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"

session:
	@if [ -z "$(LAB)" ]; then \
	  echo "Usage: make session LAB=<lab-name>  (e.g. LAB=01-ec2)"; \
	  exit 1; \
	fi
	@echo "source $(SCRIPT) session $(LAB)"
