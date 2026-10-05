# 부트스트랩 스크립트는 IP가 아니라 instance ID로 노드를 지정한다. 클러스터를 재생성하면
# IP는 바뀌지만 절차는 그대로 동작해야 하기 때문이다.
output "node_instance_ids" {
  description = "Instance ID of each node, keyed by node name. Used as the SSM target."
  value       = { for key, node in module.node : key => node.instance_id }
}

output "node_private_ips" {
  description = "Private IPv4 address of each node, keyed by node name."
  value       = { for key, node in module.node : key => node.private_ip }
}

output "control_plane_private_ip" {
  description = "Private IPv4 address of the control plane node, used as kubeadm apiserver advertise address."
  value = one([
    for key, node in var.nodes : module.node[key].private_ip if node.role == "control-plane"
  ])
}

output "cluster_security_group_id" {
  description = "Security group shared by every cluster node."
  value       = aws_security_group.cluster.id
}

output "control_plane_instance_id" {
  description = "Instance ID of the control plane node. Bootstrap scripts target it with SSM."
  value = one([
    for key, node in var.nodes : module.node[key].instance_id if node.role == "control-plane"
  ])
}

output "worker_instance_ids" {
  description = "Instance ID of each worker node, keyed by node name."
  value = {
    for key, node in var.nodes : key => module.node[key].instance_id if node.role != "control-plane"
  }
}

output "node_hostnames" {
  description = "Hostname of each node, keyed by node name. Used as the kubeadm node name."
  value       = { for key, node in module.node : key => node.hostname }
}

output "node_roles" {
  description = "Cluster role of each node, keyed by node name. Used when labelling nodes."
  value       = { for key, node in var.nodes : key => node.role }
}
