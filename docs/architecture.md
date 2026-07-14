# Infrastructure diagram

Everything below lives in **us-east-2**, in a single AWS account. Three diagrams: the runtime
infrastructure, the delivery pipeline, and the alerting path.

## Runtime infrastructure

```mermaid
flowchart TB
    admin["Admin<br/>(admin_cidr_blocks)"]

    subgraph aws["AWS · us-east-2"]
        subgraph vpc["VPC cribl-stream · 10.0.0.0/16 (DNS support + hostnames)"]
            igw["Internet gateway<br/>public route table: 0.0.0.0/0 → IGW"]

            subgraph az1["AZ a · subnet stream-app-1 · 10.0.1.0/24 (public)"]
                lp["EC2 leader-primary<br/>t3.medium · AL2023 · 100 GB gp3<br/>Role=leader"]
                lpa["EC2 leader-passive<br/>t3.medium · AL2023 · 100 GB gp3<br/>Role=leader"]
                wk["EC2 worker<br/>t3.medium · AL2023 · 100 GB gp3<br/>Role=worker"]
            end

            subgraph az2["AZ b · subnet stream-app-2 · 10.0.2.0/24 (public, unused)"]
                spare2[" "]
            end

            subgraph az3["AZ c · subnet stream-app-3 · 10.0.3.0/24 (public, unused)"]
                spare3[" "]
            end
        end

        sm["Secrets Manager<br/>cribl-stream/distributed-auth-token<br/>(random_password, 32 chars)"]
        ssm["SSM<br/>Session Manager + AWS-ConfigureAWSPackage<br/>(keeps CodeDeploy agent current)"]
        cw["CloudWatch<br/>namespace CriblStream<br/>CPU / memory / disk / procstat pid_count"]
    end

    admin -->|"HTTPS 9000 (UI)"| igw
    igw --> lp
    igw --> lpa

    wk -->|"TCP 4200 control channel<br/>TCP 9000 API"| lp
    lp <-->|"TCP 4200 leader-to-leader (SG self)"| lpa

    lp -.->|"instance role: secretsmanager:GetSecretValue"| sm
    lpa -.-> sm
    wk -.->|"reads token at deploy time"| sm

    lp -.-> ssm
    lpa -.-> ssm
    wk -.-> ssm

    lp -.->|"CloudWatch agent"| cw
    lpa -.-> cw
    wk -.-> cw

    style spare2 fill:none,stroke:none
    style spare3 fill:none,stroke:none
```

All three instances land in `public_subnet_ids[0]` — subnet 1, one AZ. The other two subnets
exist for a future spread but nothing is placed in them today (see
[Known limitations](README.md#known-limitations)).

Security groups reference each other rather than CIDRs: the Leader SG opens 9000 to
`admin_cidr_blocks` and to the Worker SG, 4200 to the Worker SG, and 4200 to itself (`self`)
for leader-to-leader. The Worker SG has no ingress at all — egress only.

## Delivery pipeline

Two structurally identical pipelines, one per role, each with its own S3 artifact bucket,
CodeDeploy application, and deployment group scoped by `ec2_tag_filter` on the `Role` tag.

```mermaid
flowchart LR
    op["Operator<br/>./deploy.sh"]

    subgraph leaders["aws-code-deploy-leaders"]
        s3l["S3 artifact bucket<br/>versioned · SSE · public access blocked"]
        cdl["CodeDeploy app + deployment group<br/>ec2_tag_filter Role=leader<br/>OneAtATime · auto-rollback"]
    end

    subgraph workers["aws-code-deploy-workers"]
        s3w["S3 artifact bucket"]
        cdw["CodeDeploy app + deployment group<br/>ec2_tag_filter Role=worker"]
    end

    lp["leader-primary<br/>leader-passive"]
    wk["worker"]
    cdn["Cribl CDN<br/>cribl-x.y.z-linux.tgz"]

    op -->|"zip + upload revision"| s3l
    op -->|"zip + upload revision"| s3w
    op -->|"create-deployment"| cdl
    op -->|"create-deployment"| cdw

    s3l --> cdl
    s3w --> cdw

    cdl -->|"appspec hooks: stop → install → start → validate"| lp
    cdw -->|"appspec hooks"| wk

    lp -->|"download tarball<br/>cribl boot-start → systemd"| cdn
    wk -->|"curl https://LEADER_IP:9000/init/install-worker.sh<br/>(token from Secrets Manager)<br/>installs + registers into 'default' group"| lp
```

The Worker never pulls from the CDN. It curls the Leader's own worker-onboarding endpoint,
which installs Cribl and registers the node in one shot — which is why the Leader IP is baked
into `deploy-workers/scripts/install.sh` today.

## Alerting path

```mermaid
flowchart LR
    subgraph inst["EC2 instances"]
        agent["CloudWatch agent<br/>procstat on /opt/cribl/bin/cribl"]
    end

    metric["CloudWatch metric<br/>CriblStream / procstat_lookup_pid_count<br/>dimension: InstanceId"]

    alarms["3 alarms (one per instance)<br/>Minimum &lt; 1 · 60s period · 2 datapoints<br/>treat_missing_data = breaching"]

    sns["SNS topic<br/>cribl-stream-service-down"]
    lam["Lambda cribl-stream-service-down-notify<br/>python3.12 · resolves instance from alarm name"]
    ses["SES<br/>domain identity + Easy DKIM"]
    inbox["alerts@merleinfanger.com → recipient"]

    agent --> metric --> alarms --> sns --> lam --> ses --> inbox
```

`treat_missing_data = "breaching"` is the load-bearing setting: a powered-off or wedged host
stops publishing the metric entirely, and would otherwise sit in `INSUFFICIENT_DATA` forever
instead of alarming.
