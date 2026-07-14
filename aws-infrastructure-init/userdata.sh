#!/bin/bash
set -euxo pipefail

dnf install -y amazon-cloudwatch-agent git

id -u cribl >/dev/null 2>&1 || useradd -r -m -s /sbin/nologin cribl

# procstat counts processes whose full command line matches the pattern, and
# publishes procstat_lookup_pid_count - 0 when cribl.service is down. That
# metric is what notification-configuration/ alarms on.
#
# procstat tags its lookup metric with pattern/pidfinder dimensions on top of
# InstanceId, which would force any alarm to name all three exactly. The
# aggregation_dimensions rollup also publishes each metric keyed on InstanceId
# alone, so the alarms only have to match the one dimension they care about.
cat <<'EOF' > /opt/aws/amazon-cloudwatch-agent/etc/config.json
{
  "metrics": {
    "namespace": "CriblStream",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent"]
      },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"]
      },
      "procstat": [
        {
          "pattern": "/opt/cribl/bin/cribl",
          "measurement": ["pid_count"],
          "metrics_collection_interval": 60
        }
      ]
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

systemctl enable amazon-cloudwatch-agent
