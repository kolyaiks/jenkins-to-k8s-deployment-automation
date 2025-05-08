module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = "${var.company_name}-vpc"
  cidr = "192.168.0.0/16"
  azs = [
    data.aws_availability_zones.azs.names[0],
    data.aws_availability_zones.azs.names[1]
  ]
  public_subnets = [
    "192.168.1.0/24",
    "192.168.2.0/24"
  ]
  private_subnets = [
    "192.168.11.0/24",
    "192.168.22.0/24"
  ]
  enable_nat_gateway = false
  single_nat_gateway = false
}

module "nat0" {
  source = "../modules/nat"

  name                        = "nat-instance-0"
  vpc_id                      = module.vpc.vpc_id
  public_subnet               = module.vpc.public_subnets[0]
  private_subnets_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  private_route_table_ids     = [module.vpc.private_route_table_ids[0]]
  use_spot_instance           = false
  instance_types              = ["t3.micro", "t3a.micro"]
  #  image_id                    = var.nat_image_id
}

resource "aws_eip" "nat0" {
  network_interface = module.nat0.eni_id
  tags = {
    "Name" = "nat-instance-nat-instance-0"
  }
}

module "nat1" {
  source = "../modules/nat"

  name                        = "nat-instance-1"
  vpc_id                      = module.vpc.vpc_id
  public_subnet               = module.vpc.public_subnets[1]
  private_subnets_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  private_route_table_ids     = [module.vpc.private_route_table_ids[1]]
  use_spot_instance           = false
  instance_types              = ["t3.micro", "t3a.micro"]
  #  image_id                    = var.nat_image_id
}

resource "aws_eip" "nat1" {
  network_interface = module.nat1.eni_id
  tags = {
    "Name" = "nat-instance-nat-instance-1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.company_name}-cluster"
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  #  concat(
  #    [for item in module.vpc.nat_public_ips: "${item}/32"], # Nat gateway's IPs need to be added to the allow list since node groups need to interact with EKS API endpoint to join the cluster
  #    var.cluster_endpoint_public_access_allowed_from
  #  )

  cluster_addons = {
    coredns                         = {}
    eks-pod-identity-agent          = {}
    kube-proxy                      = {}
    vpc-cni                         = {}
    aws-ebs-csi-driver              = { /*addon_version = "v1.37.0-eksbuild.1"*/ }
    amazon-cloudwatch-observability = { /*addon_version = "v2.5.0-eksbuild.1"*/ } # to stream logs from node to CloudWatch and get application logs under /aws/containerinsights/payorem-cluster/application
    snapshot-controller             = {}                                          # to avoid log message "Failed to watch *v1.VolumeSnapshotContent: failed to list *v1.VolumeSnapshotContent: the server could not find the requested resource (get volumesnapshotcontents.snapshot.storage.k8s.io"
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    instance_types = ["m6i.large", "m5.large", "m5n.large", "m5zn.large"]
  }

  eks_managed_node_groups = {
    company_node_group = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      # Once provisioned it's not possible to change via TF: https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2030
      min_size     = 1
      max_size     = 2
      desired_size = 1

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy    = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" # Needed by the aws-ebs-csi-driver
        CloudWatchAgentServerPolicy = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }

  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    # One access entry with a policy associated
    cluster_admin = {
      kubernetes_groups = []
      principal_arn     = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:user/kolyaiks_iam"

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  #  cluster_security_group_additional_rules = {
  #    vpn_to_api_endpoint = {
  #      description = "From VPN to communicate with the private API Endpoint"
  #      protocol    = "tcp"
  #      from_port   = 443
  #      to_port     = 443
  #      type        = "ingress"
  #      cidr_blocks = var.allow_access_to_eks_ip_endpoint_list
  #    }
  #  }
}
#############
## Jenkins
##############


module "https_sg" {
  source  = "../modules/security_group"
  sg_name = "https_sg"
  vpc_id  = module.vpc.vpc_id
  ingress_ports_set = [
    "443",
    "8080",
    "80"
  ]
  tags = {
    "Name" = "https_sg"
  }
}

module "ssh_sg" {
  source  = "../modules/security_group"
  sg_name = "ssh_sg"
  vpc_id  = module.vpc.vpc_id
  ingress_ports_set = [
    "22"
  ]
  ingress_cidr_set = [
    "13.57.245.209/32"
  ]
  tags = {
    "Name" = "ssh_sg"
  }
}

#======Key Pair=========================

resource "aws_key_pair" "key_pair" {
  key_name   = "${var.company_name}-key_pair"
  public_key = var.public_key_for_ec2_key_pair
}

resource "aws_instance" "jenkins" {
  ami                         = "ami-0f88e80871fd81e91"
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.key_pair.key_name
  security_groups             = [module.https_sg.id, module.ssh_sg.id]
  subnet_id                   = module.vpc.public_subnets[0]
  user_data                   = templatefile("${path.module}/userData.tpl", { kubectl_version = var.kubectl_version })
  user_data_replace_on_change = true
  associate_public_ip_address = true

  lifecycle {
    ignore_changes = [security_groups]
  }

  tags = {
    Name = "jenkins"
  }
}

#module "eips" {
#  source = "../../modules/eips"
#  ec2s   = module.ec2_instances.ec2s
#}

#module "health_checks" {
#  source   = "../../modules/route53/healthchecks"
#  eips_map = module.eips.eips
#}

#module "hosted_zone_records" {
#  source           = "../../modules/route53/hosted_zone_records"
#  hosted_zone_name = var.hosted_zone_name
#  healthchecks_map = module.health_checks.healthchecks
#}
