# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrant configuration for Jenkins with Existing Kubernetes Cluster
# - 1 Jenkins Controller/Master VM
# - Connects to an existing Kubernetes cluster for Jenkins agents
# 
# Prerequisites:
# 1. An existing Kubernetes cluster
# 2. kubeconfig file placed at: jenkins-config/kubeconfig
# 
# After 'vagrant up', Jenkins is automatically configured with:
# - Kubernetes cloud connection
# - Service account token credentials
# - Pod template for Jenkins agents
#
# Access Jenkins at: http://192.168.8.171:8080
# Credentials: admin / admin123

# ============================================
# Configuration - Update for your environment
# ============================================
NETWORK_PREFIX = "192.168.8"
JENKINS_IP = "#{NETWORK_PREFIX}.171"

# Kubernetes cluster settings (update if your cluster uses different values)
K8S_API_SERVER = "https://192.168.8.101:6443"

# Box configuration
BOX_IMAGE = "ubuntu/jammy64"  # Ubuntu 22.04 LTS

Vagrant.configure("2") do |config|
  
  # Common configuration for all VMs
  config.vm.box = BOX_IMAGE
  config.vm.box_check_update = false
  
  # SSH configuration
  config.ssh.insert_key = false

  # ============================================
  # Jenkins Controller/Master VM
  # ============================================
  config.vm.define "jenkins-controller" do |jenkins|
    jenkins.vm.hostname = "jenkins-controller"
    jenkins.vm.network "private_network", ip: JENKINS_IP
    
    # Port forwarding for Jenkins Web UI
    jenkins.vm.network "forwarded_port", guest: 8080, host: 8080, host_ip: "127.0.0.1"
    
    jenkins.vm.provider "virtualbox" do |vb|
      vb.name = "jenkins-controller"
      vb.memory = 4096
      vb.cpus = 2
      vb.gui = false
      
      # Performance optimizations
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      vb.customize ["modifyvm", :id, "--ioapic", "on"]
    end
    
    # Provision Jenkins Controller (installs Jenkins and plugins)
    jenkins.vm.provision "shell", path: "scripts/provision-jenkins.sh"
    
    # Configure Jenkins with K8s credentials
    jenkins.vm.provision "shell", 
      path: "scripts/configure-jenkins-k8s.sh",
      env: {
        "K8S_API_SERVER" => K8S_API_SERVER,
        "JENKINS_URL" => "http://#{JENKINS_IP}:8080",
        "JENKINS_TUNNEL" => "#{JENKINS_IP}:50000",
        "KUBECONFIG_PATH" => "/vagrant/jenkins-config/kubeconfig"
      }
  end

end
