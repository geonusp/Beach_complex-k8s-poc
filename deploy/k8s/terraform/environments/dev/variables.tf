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
