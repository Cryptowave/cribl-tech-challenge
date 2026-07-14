"""Turn a CloudWatch "cribl service down" alarm into an SES email."""

import json
import os

import boto3

ses = boto3.client("ses")

ALARM_NAME_PREFIX = os.environ["ALARM_NAME_PREFIX"]
FROM_ADDRESS = os.environ["FROM_ADDRESS"]
TO_ADDRESS = os.environ["TO_ADDRESS"]


def instance_name(alarm):
    """Recover the instance name the alarm was raised for.

    Terraform names each alarm "<prefix><instance name>", so the name is
    already in hand. Fall back to the InstanceId dimension if an alarm ever
    reaches this topic without the expected prefix, so the email still says
    which host broke rather than dropping the detail.
    """
    name = alarm.get("AlarmName", "")
    if name.startswith(ALARM_NAME_PREFIX):
        return name[len(ALARM_NAME_PREFIX) :]

    dimensions = alarm.get("Trigger", {}).get("Dimensions", [])
    for dimension in dimensions:
        if dimension.get("name") == "InstanceId":
            return dimension.get("value")

    return name or "unknown instance"


def handler(event, _context):
    for record in event["Records"]:
        alarm = json.loads(record["Sns"]["Message"])

        # The alarms only publish on ALARM today, but an OK/INSUFFICIENT_DATA
        # action added later must not send a "service has failed" email.
        if alarm.get("NewStateValue") != "ALARM":
            continue

        name = instance_name(alarm)
        ses.send_email(
            Source=FROM_ADDRESS,
            Destination={"ToAddresses": [TO_ADDRESS]},
            Message={
                "Subject": {"Data": f"Cribl service failed on {name}"},
                "Body": {
                    "Text": {
                        "Data": (
                            "please refer to recovery workbook in repository, "
                            f"service on {name} has failed"
                        )
                    }
                },
            },
        )
