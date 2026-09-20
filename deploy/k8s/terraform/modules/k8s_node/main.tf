locals {
  resource_name = "${var.project_name}-${var.env}-k8s-${var.node_key}"

  tags = {
    Name      = local.resource_name
    Component = "kubernetes"
    Role      = var.role
    NodeName  = var.node_key
  }
}

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.iam_instance_profile

  # 대상 서브넷은 MapPublicIpOnLaunch가 false다. SSM이 인터넷 게이트웨이로 나가야 하므로
  # 퍼블릭 IP를 명시적으로 요청한다. 이 값이 없으면 부팅 후 접근과 패키지 설치가 모두 막힌다.
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
  }

  volume_tags = merge(local.tags, {
    Name = "${local.resource_name}-root"
  })

  tags = local.tags
}
