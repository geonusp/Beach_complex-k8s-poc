locals {
  resource_name = "${var.project_name}-${var.env}-k8s-${var.node_key}"

  # kubeadm이 노드 이름으로 쓰는 값이다. RFC 1123을 만족해야 하며 재생성해도 동일해야 한다.
  node_hostname = "${var.project_name}-${var.node_key}"

  cloud_init_rendered = templatefile("${path.module}/cloud-init.yml.tftpl", {
    node_hostname      = local.node_hostname
    kubernetes_version = var.kubernetes_version
  })

  # cloud-init은 gzip user data를 자동 해제한다. EC2에 전달할 gzip payload를 Base64로 만들고
  # 같은 값을 user_data_base64와 크기 검증에 함께 사용한다.
  cloud_init_base64gzip = base64gzip(local.cloud_init_rendered)

  # Base64 결과에서 "=" padding을 제거한 뒤 3/4를 곱해 EC2가 제한하는 raw byte 수를 계산한다.
  # 관측 모듈과 달리 템플릿에 unknown 값이 없어 plan 시점에 실제 크기가 확정되므로
  # placeholder probe 없이 한 번만 검증한다.
  cloud_init_bytes = floor(
    length(replace(local.cloud_init_base64gzip, "=", "")) * 3 / 4
  )

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
  user_data_base64       = local.cloud_init_base64gzip

  # 부트스트랩 내용이 바뀌면 노드를 교체한다. 설치가 부분적으로 깨진 노드를 고치는 것보다
  # 교체가 빠르고 결과가 항상 같다.
  user_data_replace_on_change = true

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

  lifecycle {
    precondition {
      condition     = local.cloud_init_bytes <= 16384
      error_message = "Rendered EC2 user data must not exceed 16 KiB."
    }
  }

  tags = local.tags
}
