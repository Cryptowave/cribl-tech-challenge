# `aws-networking-setup/`

The foundation layer. Everything else in the repo builds on top of the VPC and subnets this
root creates, and reads them back out via `terraform_remote_state`.

**State key:** `network/terraform.tfstate` · **Region:** `us-east-2`

## Files

| File | Purpose |
| --- | --- |
| `main.tf` | The VPC |
| `subnets.tf` | Internet gateway, route table, public subnets, route table associations |
| `variables.tf` | VPC name, VPC CIDR, subnet CIDRs |
| `outputs.tf` | `vpc_id`, `vpc_cidr_block`, `public_subnet_ids` |
| `backend.tf` | S3 backend (pre-created bucket, native lockfile) |
| `provider.tf` / `versions.tf` | Region, profile, Terraform >= 1.5, AWS provider ~> 5.0 |

## Walkthrough

### The VPC (`main.tf`)

```hcl
resource "aws_vpc" "cribl_stream" {
  cidr_block           = var.vpc_cidr        # 10.0.0.0/16
  enable_dns_support   = true
  enable_dns_hostnames = true
}
```

`10.0.0.0/16` is plenty of room and leaves the whole rest of RFC1918 free for peering later.

Both DNS flags matter here rather than being boilerplate. **`enable_dns_support`** is what
makes the VPC resolver at `.2` answer at all — without it, the instances cannot resolve
`secretsmanager.us-east-2.amazonaws.com`, and the Worker's `install.sh` (which fetches the
distributed auth token from Secrets Manager) fails on its very first call.
**`enable_dns_hostnames`** gives the instances resolvable internal DNS names.

### Internet gateway and routing (`subnets.tf`)

An IGW attached to the VPC, and a single public route table sending `0.0.0.0/0` at it:

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.cribl_stream.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cribl_stream.id
  }
}
```

That egress path is load-bearing for more than "the instances can reach the internet." SSM
Session Manager, the CloudWatch agent publishing metrics, the CodeDeploy agent pulling
revision bundles from S3, and the Cribl CDN download in `deploy-leaders/scripts/install.sh`
all depend on it. Nothing here uses VPC endpoints — with no NAT gateway and no private
subnets, the IGW route is the only way out.

### Public subnets

```hcl
data "aws_availability_zones" "available" { state = "available" }

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)   # 3
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}
```

Three `/24`s — `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24` — indexed against the AZ list so
each lands in a **different availability zone**. That is what makes it possible to spread the
Leader HA pair across AZs; the `count.index` pairing with `data.aws_availability_zones` is
the whole mechanism.

`map_public_ip_on_launch = true` means instances get a public IP automatically, which is what
lets them reach the IGW without a NAT gateway. Every subnet is then associated with the
single public route table.

## Outputs, and why they exist

```hcl
output "vpc_id"            { value = aws_vpc.cribl_stream.id }
output "vpc_cidr_block"    { value = aws_vpc.cribl_stream.cidr_block }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
```

These are the entire public API of this layer. `aws-infrastructure-init/data.tf` reads them
with a `terraform_remote_state` data source — `vpc_id` to attach the security groups,
`public_subnet_ids[0]` to place the instances. Nothing downstream references a VPC or subnet
ID literally.

## Notes and trade-offs

- **Public subnets only.** For a challenge build with the Leader UI locked down to
  `admin_cidr_blocks` this is acceptable and it saves a NAT gateway. In production the
  Workers and Leaders belong in private subnets with a NAT gateway for egress, reaching the
  UI through a bastion or an ALB.
- **All three instances currently land in `public_subnet_ids[0]`** — see
  [aws-infrastructure-init](aws-infrastructure-init.md). The subnets to spread the HA pair
  across AZs exist; the compute layer just does not use them yet.
- **The route table is shared.** One public route table for all three subnets, since they all
  want the same `0.0.0.0/0 → IGW` route.
