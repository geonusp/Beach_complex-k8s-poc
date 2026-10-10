locals {
  name_prefix = "${var.project_name}-${var.env}-k8s"

  # Control Plane에만 추가로 붙는 API 접근 SG. operator_cidr가 없으면 만들지 않는다.
  api_security_group_ids = aws_security_group.control_plane_api[*].id
}

data "aws_caller_identity" "current" {}

# The experiment bucket is ephemeral and is removed with the dev cluster.
resource "aws_s3_bucket" "experiment_results" {
  bucket_prefix = "${local.name_prefix}-results-"
  force_destroy = true

  tags = {
    Name      = "${local.name_prefix}-results"
    Component = "kubernetes-experiment"
  }
}

resource "aws_s3_bucket_public_access_block" "experiment_results" {
  bucket                  = aws_s3_bucket.experiment_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "experiment_results" {
  bucket = aws_s3_bucket.experiment_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 클러스터 노드가 공유하는 Security Group.
# 노드 사이 통신은 self 참조로 전부 허용한다. kubeadm이 요구하는 포트(6443, 2379-2380,
# 10250, 10256, 10257, 10259, 30000-32767)에 더해 Cilium의 VXLAN 8472/UDP와 health 4240,
# ICMP까지 필요하고, CNI 구성이 바뀔 때마다 규칙을 고쳐야 하기 때문이다.
# 클러스터 내부 경계는 NetworkPolicy가 담당하고 이 SG는 외부 경계만 맡는다.
resource "aws_security_group" "cluster" {
  name_prefix = "${local.name_prefix}-cluster-"
  description = "Shared network access for ${local.name_prefix} nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name      = "${local.name_prefix}-cluster"
    Component = "kubernetes"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  description                  = "All traffic between cluster nodes"
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "Outbound access for package installation and SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# 운영자가 로컬에서 kubectl을 쓰기 위한 통로. SSM 포트 포워딩만 쓸 경우 operator_cidr를
# null로 두면 이 SG 자체가 생성되지 않는다.
resource "aws_security_group" "control_plane_api" {
  count = var.operator_cidr == null ? 0 : 1

  name_prefix = "${local.name_prefix}-api-"
  description = "Kubernetes API access for ${local.name_prefix} control plane"
  vpc_id      = var.vpc_id

  tags = {
    Name      = "${local.name_prefix}-api"
    Component = "kubernetes"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_api" {
  count = var.operator_cidr == null ? 0 : 1

  security_group_id = aws_security_group.control_plane_api[0].id
  description       = "kube-apiserver from the operator network"
  cidr_ipv4         = var.operator_cidr
  from_port         = 6443
  ip_protocol       = "tcp"
  to_port           = 6443
}

# 노드 IAM Role. SSH를 열지 않으므로 SSM Session Manager가 유일한 접근 경로다.
# 권한은 관리형 정책 하나로 제한한다.
resource "aws_iam_role" "node" {
  name = "${local.name_prefix}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name      = "${local.name_prefix}-node-role"
    Component = "kubernetes"
  }
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "node_ghcr_parameter_read" {
  name = "${local.name_prefix}-ghcr-parameter-read"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ghcr_token_parameter_name}"
    }]
  })
}

resource "aws_iam_role_policy" "node_ssm_output_s3" {
  name = "${local.name_prefix}-ssm-output-s3"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetBucketLocation",
        "s3:PutObject"
      ]
      Resource = [
        aws_s3_bucket.experiment_results.arn,
        "${aws_s3_bucket.experiment_results.arn}/rollout/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name_prefix}-node-profile"
  role = aws_iam_role.node.name

  tags = {
    Name      = "${local.name_prefix}-node-profile"
    Component = "kubernetes"
  }
}

module "node" {
  for_each = var.nodes

  source = "../../modules/k8s_node"

  node_key             = each.key
  role                 = each.value.role
  project_name         = var.project_name
  env                  = var.env
  subnet_id            = each.value.subnet_id
  ami_id               = var.ami_id
  instance_type        = each.value.instance_type
  kubernetes_version   = var.kubernetes_version
  root_volume_size_gb  = each.value.root_volume_size_gb
  iam_instance_profile = aws_iam_instance_profile.node.name

  security_group_ids = concat(
    [aws_security_group.cluster.id],
    each.value.role == "control-plane" ? local.api_security_group_ids : []
  )
}
