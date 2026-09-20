variable "node_key" {
  description = "Stable short name of this node, used in resource names and tags."
  type        = string
}

variable "role" {
  description = "Cluster role of this node."
  type        = string

  validation {
    condition     = contains(["control-plane", "app", "observability"], var.role)
    error_message = "role must be one of control-plane, app, or observability."
  }
}

variable "project_name" {
  description = "Project name used for resource names and tags."
  type        = string
}

variable "env" {
  description = "Deployment environment name."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the node. SSM reaches the node through the internet gateway."
  type        = string
}

variable "ami_id" {
  description = "Ubuntu Server 24.04 LTS x86_64 AMI ID."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Size of the encrypted gp3 root volume in GiB."
  type        = number
}

variable "kubernetes_version" {
  description = "Kubernetes minor version used for the pkgs.k8s.io apt repository, for example v1.36."
  type        = string

  validation {
    condition     = can(regex("^v1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like v1.36."
  }
}

variable "security_group_ids" {
  description = "Security groups attached to the node."
  type        = list(string)
}

variable "iam_instance_profile" {
  description = "Shared IAM instance profile name that grants SSM access."
  type        = string
}
