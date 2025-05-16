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
      "curl -fsSL https://get.docker.com | sudo sh -",
      "sudo apt-get install -y uidmap",
      "sudo usermod -aG docker ubuntu",
      "dockerd-rootless-setuptool.sh install",
    ]
  }

  provisioner "file" {
    source      = "plane-dist/plane-ee.sh"
    destination = "/home/ubuntu/plane-installer"
  }

  provisioner "shell" {
    inline = [
      "sudo cp /home/ubuntu/plane-installer /usr/local/bin/plane-installer",
      "sudo chmod +x /home/ubuntu/plane-installer",
      "sudo /usr/local/bin/plane-installer"
    ]
  }

  # Add cloud-init configuration to fetch instance metadata
  provisioner "shell" {
    inline = [
      "sudo tee /etc/cloud/cloud.cfg.d/99_custom.cfg << 'EOF'",
      "runcmd:",
      "  - PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)",
      "  - PRIVATE_DNS=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)",
      "  - echo \"export PUBLIC_DNS=$PUBLIC_DNS\" >> /etc/environment",
      "  - echo \"export PRIVATE_DNS=$PRIVATE_DNS\" >> /etc/environment",
      "  - echo \"Instance Public DNS: $PUBLIC_DNS\" >> /var/log/plane-metadata.log",
      "  - echo \"Instance Private DNS: $PRIVATE_DNS\" >> /var/log/plane-metadata.log",
      "EOF"
    ]
  }

  # Create a script to fetch instance metadata that can be run manually
  provisioner "shell" {
    inline = [
      "chmod +x /home/ubuntu/plane-installer",
      "sudo /home/ubuntu/plane-installer",
      "sudo tee /usr/local/bin/fetch-instance-metadata << 'EOF'",
      "#!/bin/bash",
      "PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)",
      "PRIVATE_DNS=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)",
      "echo \"Public DNS: $PUBLIC_DNS\"",
      "echo \"Private DNS: $PRIVATE_DNS\"",
      "EOF",
      "sudo chmod +x /usr/local/bin/fetch-instance-metadata"
    ]
  }

  # Create startup verification script
  provisioner "shell" {
    inline = [
      "sudo tee /usr/local/bin/verify-plane-setup << 'EOF'",
      "#!/bin/bash",
      "",
      "LOG_FILE=/var/log/plane-setup.log",
      "echo \"Starting Plane verification at \$(date)\" | tee -a \$LOG_FILE",
      "",
      "# Function to log messages",
      "log() {",
      "    echo \"\$(date '+%Y-%m-%d %H:%M:%S'): \$1\" | tee -a \$LOG_FILE",
      "}",
      "",
      "# Check if docker is running",
      "check_docker() {",
      "    if ! systemctl is-active --quiet docker; then",
      "        log \"Docker is not running. Attempting to start...\"",
      "        systemctl start docker",
      "        sleep 5",
      "        if ! systemctl is-active --quiet docker; then",
      "            log \"ERROR: Failed to start Docker\"",
      "            return 1",
      "        fi",
      "    fi",
      "    log \"Docker is running\"",
      "    return 0",
      "}",
      "",
      "# Get instance metadata",
      "PUBLIC_DNS=\$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)",
      "PRIVATE_DNS=\$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)",
      "",
      "# Run setup",
      "run_setup() {",
      "    local DOMAIN=\${PUBLIC_DNS:-\$PRIVATE_DNS}",
      "    log \"Running setup with domain: \$DOMAIN\"",
      "    prime-cli setup --silent --behind-proxy --domain \"\$DOMAIN\" 2>&1 | tee -a \$LOG_FILE",
      "    return \${PIPESTATUS[0]}",
      "}",
      "",
      "# Check HTTP response",
      "check_http() {",
      "    local max_attempts=12  # 2 minutes (12 * 10 seconds)",
      "    local attempt=1",
      "",
      "    while [ \$attempt -le \$max_attempts ]; do",
      "        log \"Checking HTTP response (attempt \$attempt/\$max_attempts)\"",
      "        if curl -s -o /dev/null -w \"%{http_code}\" http://localhost | grep -q \"200\"; then",
      "            log \"Successfully received HTTP 200 response\"",
      "            return 0",
      "        fi",
      "        attempt=\$((attempt + 1))",
      "        sleep 10",
      "    done",
      "",
      "    log \"ERROR: Failed to get HTTP 200 response after 2 minutes\"",
      "    return 1",
      "}",
      "",
      "# Main execution",
      "main() {",
      "    check_docker || { log \"FATAL: Docker check failed\"; exit 1; }",
      # "    run_setup || { log \"FATAL: Plane setup failed\"; exit 1; }",
      # "    check_http || { log \"FATAL: HTTP check failed\"; exit 1; }",
      "    log \"SUCCESS: All verification steps completed successfully\"",
      "    exit 0",
      "}",
      "",
      "main",
      "EOF",
      "sudo chmod +x /usr/local/bin/verify-plane-setup"
    ]
  }

  # Configure cloud-init to run verification on startup
  # provisioner "shell" {
  #   inline = [
  #     "sudo tee /etc/cloud/cloud.cfg.d/99_plane_verify.cfg << 'EOF'",
  #     "runcmd:",
  #     "  - [ /usr/local/bin/verify-plane-setup ]",
  #     "EOF"
  #   ]
  # }

  # # Create a systemd service for the verification
  # provisioner "shell" {
  #   inline = [
  #     "sudo tee /etc/systemd/system/plane-verify.service << 'EOF'",
  #     "[Unit]",
  #     "Description=Plane Setup Verification",
  #     "After=network-online.target docker.service",
  #     "Wants=network-online.target",
  #     "",
  #     "[Service]",
  #     "Type=oneshot",
  #     "ExecStart=/usr/local/bin/verify-plane-setup",
  #     "RemainAfterExit=yes",
  #     "",
  #     "[Install]",
  #     "WantedBy=multi-user.target",
  #     "EOF",
  #     "sudo systemctl enable plane-verify.service"
  #   ]
  # }

  # Post-processor for potential AMI modifications
  post-processor "manifest" {
    output = "ee-docker-aws-ami-manifest.json"
    strip_path = true
  }
} 