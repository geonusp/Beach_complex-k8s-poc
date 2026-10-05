variable "aws_region" {
  description = "AWS region for the dev Kubernetes cluster infrastructure."
  type        = string
}

variable "project_name" {
  description = "Project name used for resource names and tags."
  type        = string
  default     = "beach-complex"
}

variable "env" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of dev, staging, or prod."
  }
}

variable "vpc_id" {
  description = "VPC that hosts the cluster nodes."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID."
  }
}

variable "ami_id" {
  description = "Pinned Ubuntu Server 24.04 LTS x86_64 AMI ID for the us-east-1 dev cluster."
  type        = string
  default     = "ami-0045d7fc2ad003464"

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must be a valid AMI ID."
  }
}

variable "operator_cidr" {
  description = "Source CIDR allowed to reach the Kubernetes API on 6443. Set to null to keep the API closed and use SSM port forwarding instead."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.operator_cidr == null || can(cidrnetmask(coalesce(var.operator_cidr, "0.0.0.0/32")))
    error_message = "operator_cidr must be a valid IPv4 CIDR block."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version installed on every node."
  type        = string

  validation {
    condition     = can(regex("^v1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like v1.36."
  }
}

variable "nodes" {
  description = "Cluster nodes keyed by short name."

  type = map(object({
    role                = string
    subnet_id           = string
    instance_type       = string
    root_volume_size_gb = number
  }))

  validation {
    condition     = length(var.nodes) > 0
    error_message = "nodes must contain at least one entry."
  }

  validation {
    condition = alltrue([
      for node in values(var.nodes) :
      contains(["control-plane", "app", "observability"], node.role)
    ])
    error_message = "Each node role must be one of control-plane, app, or observability."
  }

  validation {
    condition = length([
      for node in values(var.nodes) : node if node.role == "control-plane"
    ]) == 1
    error_message = "nodes must contain exactly one control-plane node. kubeadm HA is out of scope."
  }

  validation {
    condition = alltrue([
      for node in values(var.nodes) : can(regex("^subnet-[0-9a-f]+$", node.subnet_id))
    ])
    error_message = "Each node must use a valid subnet ID."
  }

  validation {
    condition = alltrue([
      for node in values(var.nodes) : node.root_volume_size_gb >= 20
    ])
    error_message = "Each root volume must be at least 20 GiB. Container images fill 20 GiB quickly."
  }
}
