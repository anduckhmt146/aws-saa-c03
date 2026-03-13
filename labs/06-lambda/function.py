import json
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    Lambda handler - SAA-C03 Lab 06

    Key limits:
    - Max execution time: 15 minutes (900 seconds)
    - Memory: 128 MB - 10 GB
    - /tmp storage: 512 MB - 10 GB (ephemeral)
    - Concurrent executions: 1,000 per region (default)
    - Environment variables: 4 KB max

    Invocation types:
    - Synchronous: API Gateway, ALB (waits for response)
    - Asynchronous: S3, SNS, EventBridge (Lambda queues, retries 2x)
    - Event Source Mapping: SQS, Kinesis, DynamoDB Streams (Lambda polls)
    """
    logger.info(f"Event: {json.dumps(event)}")
    logger.info(f"Region: {os.environ.get('AWS_REGION')}")
    logger.info(f"Function name: {context.function_name}")
    logger.info(f"Memory limit: {context.memory_limit_in_mb} MB")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "message": "SAA Lab 06 - Lambda",
            "function": context.function_name,
            "region": os.environ.get("AWS_REGION"),
            "env_var": os.environ.get("ENVIRONMENT", "unknown")
        })
    }
