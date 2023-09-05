terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.12.0"
    }
  }

  backend "s3" {
   bucket         = "exosite-temporary-tfstate"
   key            = "christiansailor-interview/terraform.tfstate"
   region         = "us-west-2"
   encrypt        = true
   dynamodb_table = "tflock"
  }
}

provider "aws" {
  region = "us-west-2"
  default_tags {
    tags = {
      "Name" = "ExoSite Demo Server"
      "Owner" = "christiansailor"
      "Role" = "nginx_web_server"
      "OS" = "linux"
      "Distro" = "Amazon Linux"
    }
  }
}

resource "aws_key_pair" "christiansailor" {
  key_name   = "christiansailor"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCB4dmLNld9kWhAwvUAeoIsGjIC3nwOlqnWaG6QuUXu7QBMIoCCFyWO4zLfxhG5o1rpDsnL7+BbfuNkKVSLKyuAa8CGNTC0a3GazNf/gmH/vG5uBr/TMrG075IWdBqFiNviv+VfVgmIbcqx7Wqq8EdRaU0MpPo4LNc/LmcNinCE3hop7lHxKMb+XAXVexc0I5zqtvwkOTvEGVg6gwKbt/TiTwu8qFLV3LeKMd2GaLy4a4o+MvRYOzcxCJ5bJoMW/Xad9uH2nuIh9jnNEAWdYVtLENNeO1tMYWV8Evk9ZTc117NDUkYVnuPgHFy+ImLvjsMOBXV6Zr0OYGvgICzaCTYL christiansailor_key"
}

resource "aws_instance" "nginx_server" {
   ami           = "ami-08f636ee366a58ec8"
  instance_type  = "t4g.nano"
  subnet_id      = local.subnet_ids[0]
  key_name       = "christiansailor"
  vpc_security_group_ids = [aws_security_group.nginx_ec2_sg.id]


  provisioner "remote-exec" {
    inline = [
      "sudo yum install epel-release -y",
      "sudo yum update -y",
      "sudo dnf install nginx -y",
      "sudo systemctl start nginx",
      "sudo systemctl enable nginx"
    ]

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("~/ssh_keys/christiansailor_key.pem")
      host        = self.public_ip
    }
  }
}

resource "aws_security_group" "load_balancer_sg" {
  name        = "christian-alb-sg"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "nginx_ec2_sg" {
 name  = "christian-ec2-sgs" 
 vpc_id = local.vpc_id

 ingress {
   from_port   = 80
   to_port     = 80
   protocol    = "TCP"
   security_groups = [aws_security_group.load_balancer_sg.id]
 }

 ingress {
   from_port   = 443
   to_port     = 443
   protocol    = "TCP"
   security_groups = [aws_security_group.load_balancer_sg.id]
 }

 ingress {
   from_port   = 22
   to_port     = 22
   protocol    = "TCP"
   cidr_blocks = ["0.0.0.0/0"]
 }

  egress {
   from_port   = 0
   to_port     = 0
   protocol    = "-1"
   cidr_blocks = ["0.0.0.0/0"]
 }
}

resource "aws_lb" "alb" {
  name               = "christian-alb" 
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg.id]

  enable_deletion_protection = false 

  subnets  = [
      local.subnet_ids[0],
      local.subnet_ids[2],
      local.subnet_ids[3]
  ]
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
     type             = "forward"
     target_group_arn = aws_lb_target_group.lb_tg.arn
   }
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.exosite_cert.arn

  default_action {
     type             = "forward"
     target_group_arn = aws_lb_target_group.lb_tg.arn
   }
}

resource "aws_lb_target_group" "lb_tg" {
  name     = "http-listener-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = local.vpc_id
}

resource "aws_lb_target_group_attachment" "tg_attachment_http" {
    target_group_arn = aws_lb_target_group.lb_tg.arn
    target_id        = aws_instance.nginx_server.id
    port             = 80
}


resource "aws_acm_certificate" "exosite_cert" {
  domain_name       = local.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
  
}

resource "aws_route53_record" "cname_record_dns" {
  zone_id = local.zone_id
  name = local.domain_name
  type = "CNAME"
  ttl = "6"
  records = [aws_lb.alb.dns_name]
}

resource "aws_route53_record" "exosite_cert_dns" {
  allow_overwrite = true
  name =  tolist(aws_acm_certificate.exosite_cert.domain_validation_options)[0].resource_record_name
  records = [tolist(aws_acm_certificate.exosite_cert.domain_validation_options)[0].resource_record_value]
  type = tolist(aws_acm_certificate.exosite_cert.domain_validation_options)[0].resource_record_type
  zone_id     = local.zone_id
  ttl = 60
}

resource "aws_acm_certificate_validation" "exosite_cert_validation" {
  certificate_arn = aws_acm_certificate.exosite_cert.arn
  validation_record_fqdns = [aws_route53_record.exosite_cert_dns.fqdn]
}

locals {
  vpc_id = "vpc-0c2a36846ba20e729"
  subnet_ids = [
    "subnet-0068679226e81966f",
    "subnet-0db7119e20b440c97",
    "subnet-056f4097e702e48ac",
    "subnet-07c4289662cca87e6",
  ]
  domain_name = "christiansailor.interview.exosite.biz"
  zone_id     = "Z0900350IRBV4VB1AT02"
}
