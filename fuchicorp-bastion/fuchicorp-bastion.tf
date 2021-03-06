provider "google" {
  credentials = "${file("./fuchicorp-service-account.json")}"
  project     = "${var.google_project_id}"
  zone        = "${var.zone}"
}

resource "google_compute_instance" "vm_instance" {
  name         = "${var.instance_name}"
  machine_type = "${var.machine_type}"

  boot_disk {
    initialize_params {
      size = "${var.instance_disk_zie}" 
      image = "centos-cloud/centos-7"
    }

  }

  network_interface {
    network       = "default"
    access_config = {}
  }

  metadata {
    sshKeys = "${var.gce_ssh_user}:${file(var.gce_ssh_pub_key_file)}"
  }

  metadata_startup_script = <<EOF
  #!/bin/bash
  export GIT_TOKEN="${var.git_common_token}"
  echo 'export GIT_TOKEN="${var.git_common_token}"' >> /root/.bashrc
  sleep 10
  yum install python-pip git jq wget unzip vim centos-release-scl scl-utils-build -y
  yum install  python33 gcc python3 -y
  sudo yum check-update
  sudo yum install -y yum-utils device-mapper-persistent-data lvm2
  sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo yum install docker-ce-17.12.1.ce
  sudo systemctl start docker
  sudo systemctl enable docker
  sudo chmod 777 /var/run/docker.sock

  git clone -b master https://github.com/fuchicorp/common_scripts.git "/common_scripts"
  python3 -m pip install -r "/common_scripts/bastion-scripts/requirements.txt"
  cd /common_scripts/bastion-scripts/ && python3 sync-users.py

  curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.13.0/bin/linux/amd64/kubectl
  mv kubectl /usr/bin
  chmod +x /usr/bin/kubectl
  
  sudo yum install bind-utils -y


  wget https://releases.hashicorp.com/terraform/0.11.14/terraform_0.11.14_linux_amd64.zip --no-check-certificate
  unzip  terraform_0.11.14_linux_amd64.zip
  mv terraform /usr/bin
  chmod +x /usr/bin/terraform

  wget https://get.helm.sh/helm-v2.11.0-linux-amd64.tar.gz
  tar -xvzf helm-v2.11.0-linux-amd64.tar.gz
  mv linux-amd64/helm /usr/bin/helm

  curl https://sdk.cloud.google.com | bash && exec -l $SHELL

  echo "30 * * * * source /root/.bashrc && cd /common_scripts/bastion-scripts/ && python3 sync-users.py" >> /sync-crontab
  crontab /sync-crontab

EOF
}

resource "null_resource" "local_generate_kube_config" {
  depends_on = ["google_compute_instance.vm_instance"]
  provisioner "local-exec" {
    command = <<EOF
    #!/bin/bash
    until ping -c1 ${google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip} >/dev/null 2>&1; do echo "Tring to connect bastion host"; sleep 2; done
    wget https://raw.githubusercontent.com/fuchicorp/common_scripts/master/set-environments/kubernetes/set-kube-config.sh 
    ENDPOINT=$(kubectl get endpoints kubernetes | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
    bash set-kube-config.sh $ENDPOINT
    ssh ${var.gce_ssh_user}@${google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip} sudo mkdir /fuchicorp | echo 'Folder exist'
    scp -r  "admin_config"   ${var.gce_ssh_user}@${google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip}:~/
    scp -r  "view_config"   ${var.gce_ssh_user}@${google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip}:~/
    ssh ${var.gce_ssh_user}@${google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip} sudo mv -f ~/*config /fuchicorp/
    rm -rf set-kube-config*
EOF
  }
}

resource "google_dns_record_set" "fuchicorp" {
  managed_zone = "${var.managed_zone}"
  name         = "bastion.fuchicorp.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["${google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip}"]
}
