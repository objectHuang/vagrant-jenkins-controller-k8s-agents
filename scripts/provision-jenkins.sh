#!/bin/bash
# Jenkins Controller/Master Provisioning Script
# This script installs and configures Jenkins on Ubuntu 22.04
# Uses Jenkins Configuration as Code (JCasC) for automatic setup

set -e

echo "=========================================="
echo "Starting Jenkins Controller Provisioning"
echo "=========================================="

# Update system packages
echo "[INFO] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install required dependencies
echo "[INFO] Installing dependencies..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    wget \
    git \
    openjdk-17-jdk \
    python3 \
    python3-pip \
    jq

# Set JAVA_HOME
echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /etc/profile.d/java.sh
echo "export PATH=\$PATH:\$JAVA_HOME/bin" >> /etc/profile.d/java.sh
source /etc/profile.d/java.sh

# Add Jenkins repository and key
echo "[INFO] Adding Jenkins repository..."
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

# Install Jenkins
echo "[INFO] Installing Jenkins..."
apt-get update -y
apt-get install -y jenkins

# Stop Jenkins to configure it
systemctl stop jenkins

# Configure Jenkins
echo "[INFO] Configuring Jenkins..."

# Create Jenkins configuration directories
mkdir -p /var/lib/jenkins
mkdir -p /var/lib/jenkins/init.groovy.d
mkdir -p /var/lib/jenkins/casc_configs

# Install kubectl for communicating with K8s cluster
echo "[INFO] Installing kubectl..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
apt-get update -y
apt-get install -y kubectl

# Install Docker (optional, for building images)
echo "[INFO] Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

# Add jenkins user to docker group
usermod -aG docker jenkins

# Create directory for kubeconfig
mkdir -p /var/lib/jenkins/.kube
chown -R jenkins:jenkins /var/lib/jenkins/.kube

# Add hosts entries for K8s nodes
echo "[INFO] Adding K8s nodes to /etc/hosts..."
cat >> /etc/hosts << 'EOF'
192.168.8.101 k8s-node1
192.168.8.102 k8s-node2
192.168.8.103 k8s-node3
EOF

# Configure firewall
echo "[INFO] Configuring firewall..."
ufw allow 8080/tcp || true
ufw allow 22/tcp || true
ufw allow 50000/tcp || true  # Jenkins agent port

# ========================================
# JENKINS PLUGIN PRE-INSTALLATION
# ========================================
echo "[INFO] Pre-installing Jenkins plugins..."

# Create plugins directory
mkdir -p /var/lib/jenkins/plugins
cd /var/lib/jenkins/plugins

# Download Jenkins plugin manager CLI
JENKINS_PLUGIN_MANAGER_VERSION="2.13.0"
curl -fsSL -o jenkins-plugin-manager.jar \
    "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${JENKINS_PLUGIN_MANAGER_VERSION}/jenkins-plugin-manager-${JENKINS_PLUGIN_MANAGER_VERSION}.jar"

# Create plugins list file
cat > /tmp/plugins.txt << 'EOF'
kubernetes
configuration-as-code
credentials
credentials-binding
git
workflow-aggregator
pipeline-stage-view
blueocean
ssh-credentials
plain-credentials
job-dsl
EOF

# Get Jenkins WAR file path
JENKINS_WAR=$(find /usr/share/jenkins -name "jenkins.war" 2>/dev/null | head -1)
if [ -z "$JENKINS_WAR" ]; then
    JENKINS_WAR="/usr/share/java/jenkins.war"
fi

# Install plugins using plugin manager
echo "[INFO] Installing plugins with jenkins-plugin-manager..."
java -jar jenkins-plugin-manager.jar \
    --war "$JENKINS_WAR" \
    --plugin-download-directory /var/lib/jenkins/plugins \
    --plugin-file /tmp/plugins.txt \
    --verbose || echo "[WARN] Some plugins may have failed, continuing..."

# Clean up
rm -f jenkins-plugin-manager.jar /tmp/plugins.txt

# ========================================
# JENKINS CONFIGURATION AS CODE (JCasC)
# ========================================
echo "[INFO] Setting up Jenkins Configuration as Code..."

# Create Groovy init script to skip setup wizard and configure basic settings
cat > /var/lib/jenkins/init.groovy.d/basic-security.groovy << 'GROOVY'
#!groovy

import jenkins.model.*
import hudson.security.*
import jenkins.security.s2m.AdminWhitelistRule

def instance = Jenkins.getInstance()

// Create admin user
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount("admin", "admin123")
instance.setSecurityRealm(hudsonRealm)

// Set authorization strategy
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// Enable JNLP agent port
instance.setSlaveAgentPort(50000)

// Save
instance.save()

println "Basic security configured!"
GROOVY

# Configure Jenkins startup options
cat > /etc/default/jenkins << 'EOF'
# Jenkins configuration
JENKINS_HOME=/var/lib/jenkins
JENKINS_USER=jenkins
JENKINS_PORT=8080
JENKINS_ARGS="--httpListenAddress=0.0.0.0"
EOF

# Create systemd override for Jenkins with JCasC
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf << 'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs"
EOF

# Set proper ownership
chown -R jenkins:jenkins /var/lib/jenkins

# Enable services (but don't start Jenkins yet - wait for K8s)
echo "[INFO] Enabling services..."
systemctl daemon-reload
systemctl enable jenkins
systemctl enable docker
systemctl start docker

# Don't start Jenkins yet - it will be configured after K8s is ready
echo "[INFO] Jenkins installation complete. Will be started after K8s cluster is ready."

echo "=========================================="
echo "Jenkins Controller Provisioning Complete!"
echo "=========================================="
echo ""
echo "Jenkins is installed but NOT started yet."
echo "It will be started after K8s cluster is ready."
echo ""
echo "Access Jenkins at: http://192.168.8.171:8080"
echo "Admin credentials: admin / admin123"
echo "=========================================="
