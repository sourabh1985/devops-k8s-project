provider "aws" {
  region = "ap-south-1"
}

resource "aws_security_group" "sg" {
  name = "k8s-sg"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "server" {
  ami           = "ami-09ed39e30153c3bf9"
  instance_type = "t3.small"
  key_name      = "ssva_mumbai_keypair"
  vpc_security_group_ids = [aws_security_group.sg.id]

  user_data = file("install.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp2"
  }

  tags = {
    Name = "k3s-server"
  }
}
