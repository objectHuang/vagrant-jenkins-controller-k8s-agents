#!/bin/bash
# Jenkins Setup Script for Existing Kubernetes Cluster
# This script configures Jenkins to use an existing K8s cluster for dynamic agents

set -e

echo "=========================================="
echo "Jenkins Configuration for Existing K8s Cluster"
echo "=========================================="

# =============================================
# Configuration - Update these for your cluster
# =============================================
K8S_API_SERVER="${K8S_API_SERVER:-https://192.168.8.101:6443}"
JENKINS_URL="${JENKINS_URL:-http://192.168.8.171:8080}"
JENKINS_TUNNEL="${JENKINS_TUNNEL:-192.168.8.171:50000}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/vagrant/jenkins-config/kubeconfig}"

echo "[INFO] K8s API Server: $K8S_API_SERVER"
echo "[INFO] Jenkins URL: $JENKINS_URL"
echo "[INFO] Kubeconfig: $KUBECONFIG_PATH"

# =============================================
# Setup kubeconfig for kubectl commands
# =============================================
echo "[INFO] Setting up kubeconfig..."

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "[ERROR] Kubeconfig not found at $KUBECONFIG_PATH"
    echo "[INFO] Please provide a valid kubeconfig file from your existing K8s cluster."
    echo "[INFO] You can copy it from your K8s control plane: "
    echo "[INFO]   scp user@k8s-master:/etc/kubernetes/admin.conf /vagrant/jenkins-config/kubeconfig"
    exit 1
fi

# Setup kubeconfig for root user to run kubectl commands
mkdir -p /root/.kube
cp "$KUBECONFIG_PATH" /root/.kube/config
chmod 600 /root/.kube/config

# Extract K8s API server from kubeconfig if not explicitly set
if [ "$K8S_API_SERVER" = "https://192.168.8.101:6443" ]; then
    DETECTED_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
    if [ -n "$DETECTED_SERVER" ]; then
        K8S_API_SERVER="$DETECTED_SERVER"
        echo "[INFO] Detected K8s API Server from kubeconfig: $K8S_API_SERVER"
    fi
fi

# =============================================
# Verify K8s cluster connectivity
# =============================================
echo "[INFO] Verifying connection to Kubernetes cluster..."
if ! kubectl cluster-info &>/dev/null; then
    echo "[ERROR] Cannot connect to Kubernetes cluster. Please check:"
    echo "  1. The K8s cluster is running"
    echo "  2. The kubeconfig file is valid"
    echo "  3. Network connectivity to the K8s API server"
    exit 1
fi

kubectl cluster-info
echo "[INFO] Successfully connected to Kubernetes cluster!"

# =============================================
# Deploy Jenkins namespace and RBAC
# =============================================
echo "[INFO] Setting up Jenkins namespace and RBAC in K8s..."

# Create Jenkins namespace
kubectl apply -f /vagrant/k8s-manifests/jenkins-namespace.yaml

# Create RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
kubectl apply -f /vagrant/k8s-manifests/jenkins-rbac.yaml

# Apply pod template if exists
if [ -f "/vagrant/k8s-manifests/jenkins-agent-pod-template.yaml" ]; then
    kubectl apply -f /vagrant/k8s-manifests/jenkins-agent-pod-template.yaml || true
fi

# Wait for resources to be ready
echo "[INFO] Waiting for ServiceAccount to be ready..."
sleep 5

# =============================================
# Generate Jenkins Service Account Token
# =============================================
echo "[INFO] Generating Jenkins service account token (valid for 1 year)..."

# Create token with 1 year expiration using TokenRequest API (K8s 1.24+)
K8S_TOKEN=$(kubectl create token jenkins -n jenkins --duration=8760h 2>/dev/null)

if [ -z "$K8S_TOKEN" ]; then
    # Fallback: try to get token from the secret (older K8s versions)
    echo "[INFO] Trying to get token from secret (older K8s method)..."
    K8S_TOKEN=$(kubectl get secret jenkins-token -n jenkins -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
fi

if [ -z "$K8S_TOKEN" ]; then
    echo "[ERROR] Failed to generate service account token!"
    exit 1
fi

echo "[INFO] Token generated successfully (length: ${#K8S_TOKEN})"

# Save token and CA cert for reference
mkdir -p /vagrant/jenkins-config
echo "$K8S_TOKEN" > /vagrant/jenkins-config/jenkins-token.txt
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /vagrant/jenkins-config/ca.crt 2>/dev/null || true

# =============================================
# Generate Jenkins Configuration as Code (JCasC)
# =============================================
echo "[INFO] Generating Jenkins Configuration as Code file..."

# Extract host and port from K8S_API_SERVER
K8S_HOST=$(echo "$K8S_API_SERVER" | sed 's|https://||' | cut -d':' -f1)

cat > /var/lib/jenkins/casc_configs/jenkins.yaml << EOFYAML
jenkins:
  systemMessage: "Jenkins configured automatically with Kubernetes Cloud - Ready to use!"
  numExecutors: 0
  mode: EXCLUSIVE
  
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "admin"
          password: "admin123"
  
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false

  slaveAgentPort: 50000

  clouds:
    - kubernetes:
        name: "kubernetes"
        serverUrl: "${K8S_API_SERVER}"
        skipTlsVerify: true
        namespace: "jenkins"
        jenkinsUrl: "${JENKINS_URL}"
        jenkinsTunnel: "${JENKINS_TUNNEL}"
        credentialsId: "k8s-service-account-token"
        containerCapStr: "10"
        maxRequestsPerHostStr: "32"
        retentionTimeout: 5
        connectTimeout: 5
        readTimeout: 15
        templates:
          - name: "jnlp-agent"
            namespace: "jenkins"
            label: "kubernetes jnlp"
            nodeUsageMode: NORMAL
            serviceAccount: "jenkins"
            containers:
              - name: "jnlp"
                image: "jenkins/inbound-agent:latest"
                workingDir: "/home/jenkins/agent"
                ttyEnabled: true
                resourceRequestCpu: "200m"
                resourceRequestMemory: "256Mi"
                resourceLimitCpu: "500m"
                resourceLimitMemory: "512Mi"
            yamlMergeStrategy: "override"
            podRetention: "never"

credentials:
  system:
    domainCredentials:
      - credentials:
          - string:
              scope: GLOBAL
              id: "k8s-service-account-token"
              description: "Kubernetes Service Account Token"
              secret: "${K8S_TOKEN}"

unclassified:
  location:
    url: "${JENKINS_URL}/"
    adminAddress: "admin@localhost"

jobs:
  - script: |
      pipelineJob('test-k8s-agent') {
        description('Test pipeline to verify Kubernetes agents are working')
        definition {
          cps {
            script('''
              pipeline {
                  agent {
                      label 'kubernetes'
                  }
                  stages {
                      stage('Hello') {
                          steps {
                              echo 'Hello from Kubernetes Agent!'
                              sh 'hostname'
                              sh 'cat /etc/os-release'
                          }
                      }
                      stage('Environment') {
                          steps {
                              sh 'env | sort'
                          }
                      }
                  }
              }
            '''.stripIndent())
            sandbox(true)
          }
        }
      }
EOFYAML

# Set proper ownership
chown jenkins:jenkins /var/lib/jenkins/casc_configs/jenkins.yaml

# Copy kubeconfig for Jenkins user
echo "[INFO] Setting up kubeconfig for Jenkins user..."
mkdir -p /var/lib/jenkins/.kube
cp "$KUBECONFIG_PATH" /var/lib/jenkins/.kube/config
chown -R jenkins:jenkins /var/lib/jenkins/.kube
chmod 600 /var/lib/jenkins/.kube/config

# Start Jenkins
echo "[INFO] Starting Jenkins..."
systemctl start jenkins

# Wait for Jenkins to start
echo "[INFO] Waiting for Jenkins to be ready..."
for i in {1..60}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "403" ]; then
        echo "[INFO] Jenkins is responding! (HTTP $HTTP_CODE)"
        break
    fi
    echo "Waiting for Jenkins... attempt $i/60 (HTTP $HTTP_CODE)"
    sleep 5
done

# Give Jenkins more time to fully initialize and load plugins
echo "[INFO] Waiting for Jenkins to fully initialize plugins..."
sleep 60

# Check Jenkins status
echo "[INFO] Checking Jenkins status..."
systemctl status jenkins --no-pager || true

# Get K8s cluster info for summary
K8S_HOST=$(echo "$K8S_API_SERVER" | sed 's|https://||' | cut -d':' -f1)
JENKINS_HOST=$(echo "$JENKINS_URL" | sed 's|http://||' | cut -d':' -f1)

echo "=========================================="
echo "Jenkins Setup Complete!"
echo "=========================================="
echo ""
echo "Jenkins URL: $JENKINS_URL"
echo "             http://localhost:8080 (via port forwarding)"
echo ""
echo "Credentials:"
echo "  Username: admin"
echo "  Password: admin123"
echo ""
echo "Kubernetes Cloud: Configured automatically"
echo "  - Cloud name: kubernetes"
echo "  - K8s API: $K8S_API_SERVER"
echo "  - Namespace: jenkins"
echo "  - Pod Template: jnlp-agent (labels: kubernetes, jnlp)"
echo ""
echo "Test Job: 'test-k8s-agent' has been created"
echo "  Run it to verify K8s agents are working!"
echo ""
echo "=========================================="
