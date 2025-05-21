packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# Variables for AWS credentials
variable "aws_access_key" {
  type    = string
  default = "aws-access-key"
}

variable "aws_secret_key" {
  type    = string
  default = "aws-secret-access-key"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "ami_name_prefix" {
  type    = string
  default = "plane"
}

variable "vpc_cidr" {
  type    = string
  default = "10.22.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.22.1.0/24"
}

variable "base_image_owner" {
  type    = string
  default = "099720109477"
}

variable "ami_regions" {
  type    = list(string)
  default = ["us-east-1"]
}

variable "prime_host" {
  type    = string
  default = "https://prime.plane.so"
}

# Local variables for reuse
locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

# Source block defining the base image and configuration
source "amazon-ebs" "plane_aws_ami" {
  access_key    = var.aws_access_key
  secret_key    = var.aws_secret_key
  region        = var.aws_region
  ami_name      = "${var.ami_name_prefix}-${local.timestamp}"
  instance_type = "t3a.medium"
  encrypt_boot  = false
  ami_regions   = var.ami_regions

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size          = 15
    volume_type          = "gp3"
    delete_on_termination = true
    encrypted            = false
  }

  vpc_filter {
    filters = {
      "cidr": var.vpc_cidr
    }
  }

  subnet_filter {
    filters = {
      "cidr": var.subnet_cidr
    }
  }

  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = [var.base_image_owner]
  }
  
  ssh_username = "ubuntu"
  
  tags = {
    Name        = "${var.ami_name_prefix}-${local.timestamp}"
    Environment = "Production"
    Builder     = "Packer"
  }

  snapshot_tags = {
    Name        = "${var.ami_name_prefix}-${local.timestamp}"
    Environment = "Production"
    Builder     = "Packer"
  }
}

# Build block defining what to install and configure
build {
  name = "${var.ami_name_prefix}-${local.timestamp}"
  sources = [
    "source.amazon-ebs.plane_aws_ami"
  ]


  # Copy application files
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "TERM=xterm-256color"
    ]
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y cloud-init",
      "curl -fsSL https://get.docker.com | sudo sh -",
      "sudo apt-get install -y uidmap",
      "sudo usermod -aG docker ubuntu",
      "dockerd-rootless-setuptool.sh install",
      "mkdir -p /home/ubuntu/cloud-init",
    ]
  }

  # set prime host to instance environment variable
  provisioner "shell" {
    inline = [
      "sudo bash -c 'echo PRIME_HOST=${var.prime_host} >> /etc/environment'"
    ]
  }

  provisioner "file" {
    source      = "plane-dist/"
    destination = "/home/ubuntu/cloud-init"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "TERM=xterm-256color",
      "PRIME_HOST=${var.prime_host}"
    ]
    inline = [
      "sudo mv /home/ubuntu/cloud-init/99_plane.cfg /etc/cloud/cloud.cfg.d/99_plane.cfg",
      "sudo mv /home/ubuntu/cloud-init/verify-plane-setup /usr/local/bin/verify-plane-setup",
      "sudo chmod +x /usr/local/bin/verify-plane-setup",
      "sudo mv /home/ubuntu/cloud-init/plane-verify.service /etc/systemd/system/plane-verify.service",
      "sudo /usr/local/bin/verify-plane-setup --prime-host=${var.prime_host}",
      "sudo prime-cli uninstall -s",
      "sudo rm /etc/update-motd.d/99-plane-status",
      "sudo rm /var/lib/cloud/instance/plane-setup-complete",
      "sudo rm /var/lib/cloud/instance/plane-setup-status",
      # "sudo systemctl enable plane-verify.service",
      # "sudo systemctl start plane-verify.service"
    ]
  }


  # Post-processor for potential AMI modifications
  post-processor "manifest" {
    output = "ee-docker-aws-ami-manifest.json"
    strip_path = true
  }
} 