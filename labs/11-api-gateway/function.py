import json


def handler(event, context):
    http_method = event.get("httpMethod", "GET")
    path = event.get("path", "/")
    body = json.loads(event.get("body") or "{}")

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps({
            "message": "SAA Lab 11 - API Gateway",
            "method": http_method,
            "path": path,
            "received": body
        })
    }
