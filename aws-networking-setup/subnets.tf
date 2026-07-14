data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_internet_gateway" "cribl_stream" {
  vpc_id = aws_vpc.cribl_stream.id

  tags = {
    Name = "${var.vpc_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.cribl_stream.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cribl_stream.id
  }

  tags = {
    Name = "${var.vpc_name}-public-rt"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.cribl_stream.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "stream-app-${count.index + 1}"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
