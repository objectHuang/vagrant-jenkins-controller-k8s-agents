# Jenkins with Existing Kubernetes Cluster

This project creates a **Jenkins Controller VM** using Vagrant that connects to an **existing Kubernetes cluster** for running Jenkins agents as pods.

## Features

- **Jenkins Controller VM** (192.168.8.171) with pre-installed plugins
- **Automatic K8s Cloud Configuration** via Jenkins Configuration as Code (JCasC)
- **Dynamic agent provisioning** - Jenkins agents run as pods in your K8s cluster
- **Pre-configured test job** to verify the setup

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host Machine                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐ │
│  │  Jenkins Controller │    │  Existing Kubernetes Cluster    │ │
│  │   192.168.8.171     │    │  (Your existing cluster)        │ │
│  │                     │    │                                 │ │
│  │  ┌───────────────┐  │    │  ┌──────────┐ ┌──────────┐     │ │
│  │  │    Jenkins    │  │◄───┼──│ Agent    │ │ Agent    │     │ │
│  │  │    Master     │  │    │  │ Pod      │ │ Pod      │     │ │
│  │  └───────────────┘  │    │  └──────────┘ └──────────┘     │ │
│  │         │           │    │                                 │ │
│  │     Port 8080       │    │  Namespace: jenkins             │ │
│  │     Port 50000      │    │  ServiceAccount: jenkins        │ │
│  └─────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **VirtualBox** (6.1 or later)
- **Vagrant** (2.3 or later)
- **Existing Kubernetes Cluster** with network access from the Jenkins VM
- **kubectl** access to your K8s cluster (to copy kubeconfig)
- **Host Machine**: At least 6GB RAM available for Jenkins VM

## Quick Start

### 1. Prepare kubeconfig from your existing K8s cluster

Copy the kubeconfig from your Kubernetes cluster:

```bash
# Create config directory
mkdir -p jenkins-config

# Copy kubeconfig from your K8s cluster (adjust the path/host as needed)
# Option 1: From local kubectl config
cp ~/.kube/config jenkins-config/kubeconfig

# Option 2: From a remote K8s master node
scp user@k8s-master:/etc/kubernetes/admin.conf jenkins-config/kubeconfig

# Update the server address if needed (replace 127.0.0.1 with actual IP)
sed -i 's/127.0.0.1/YOUR_K8S_API_IP/g' jenkins-config/kubeconfig
```

### 2. (Optional) Update K8s API Server Address

Edit the `Vagrantfile` and update the `K8S_API_SERVER` variable if your cluster uses a different address:

```ruby
K8S_API_SERVER = "https://YOUR_K8S_API_IP:6443"
```

### 3. Start Jenkins VM

```bash
vagrant up
```

This will automatically:
1. Create Jenkins controller VM
2. Install Jenkins with all required plugins
3. Connect to your K8s cluster and create jenkins namespace + RBAC
4. Generate service account token
5. Configure Kubernetes cloud connection
6. Create a test job

**Note**: Provisioning takes approximately 10-15 minutes.

### 4. Access Jenkins

Once provisioning completes:

- **URL**: http://localhost:8080 or http://192.168.8.171:8080
- **Username**: `admin`
- **Password**: `admin123`

**That's it!** Jenkins is ready to use with Kubernetes agents.

### 5. Verify the Setup

1. Log into Jenkins
2. Find the **test-k8s-agent** job
3. Click "Build Now"
4. Watch the build - it will spin up a pod in Kubernetes and execute

## What Gets Created in Your K8s Cluster

The provisioning script automatically creates the following in your K8s cluster:

- **Namespace**: `jenkins`
- **ServiceAccount**: `jenkins` (with cluster-admin-like permissions for pod management)
- **ClusterRole**: `jenkins-admin`
- **ClusterRoleBinding**: `jenkins-admin-binding`
- **Token**: Service account token (valid for 1 year)

## What's Pre-Configured in Jenkins

### Jenkins Plugins
- Kubernetes
- Configuration as Code
- Pipeline (workflow-aggregator)
- Git
- Credentials
- Blue Ocean

### Kubernetes Cloud
- **Cloud Name**: kubernetes
- **K8s API URL**: Configured from your kubeconfig
- **Namespace**: jenkins
- **TLS Verification**: Disabled (for flexibility)

### Pod Template
- **Name**: jnlp-agent
- **Labels**: `kubernetes jnlp`
- **Image**: jenkins/inbound-agent:latest
- **Service Account**: jenkins

## Configuration Options

You can customize the setup using environment variables in the Vagrantfile:

| Variable | Default | Description |
|----------|---------|-------------|
| K8S_API_SERVER | https://192.168.8.101:6443 | Kubernetes API server URL |
| JENKINS_URL | http://192.168.8.171:8080 | Jenkins URL (for agents to connect back) |
| JENKINS_TUNNEL | 192.168.8.171:50000 | Jenkins JNLP tunnel address |
| KUBECONFIG_PATH | /vagrant/jenkins-config/kubeconfig | Path to kubeconfig file |

## Manual Configuration (Optional)

If you need to reconfigure Jenkins manually or regenerate the token:

### Get New Service Account Token

```bash
# SSH into Jenkins VM
vagrant ssh jenkins-controller

# Generate a new token (valid for 1 year)
sudo kubectl create token jenkins -n jenkins --duration=8760h
```

### Configure Kubernetes Cloud Manually

1. Go to **Manage Jenkins** → **Clouds** → **kubernetes**
2. Update configuration as needed:
   - **Kubernetes URL**: Your K8s API server URL
   - **Jenkins URL**: `http://192.168.8.171:8080`
   - **Jenkins Tunnel**: `192.168.8.171:50000`

### Test Pipeline Example

```groovy
pipeline {
    agent {
        label 'kubernetes'
    }
    stages {
        stage('Test') {
            steps {
                sh 'echo "Hello from Kubernetes agent!"'
                sh 'hostname'
                sh 'cat /etc/os-release'
            }
        }
    }
}
```

## VM Details

| VM Name | IP Address | Role | Resources |
|---------|------------|------|-----------|
| jenkins-controller | 192.168.8.171 | Jenkins Master | 4GB RAM, 2 CPU |

## Useful Commands

### Vagrant Commands

```bash
# Start Jenkins VM
vagrant up

# SSH into Jenkins VM
vagrant ssh jenkins-controller

# Stop Jenkins VM
vagrant halt

# Destroy Jenkins VM
vagrant destroy -f

# Reprovision (reconfigure Jenkins)
vagrant provision

# Check VM status
vagrant status
```

### Kubernetes Commands (from Jenkins VM)

```bash
# SSH into Jenkins VM
vagrant ssh jenkins-controller

# Get cluster nodes
sudo kubectl get nodes

# Get all pods in jenkins namespace
sudo kubectl get pods -n jenkins

# Generate new Jenkins service account token
sudo kubectl create token jenkins -n jenkins --duration=8760h

# Watch agent pods
sudo kubectl get pods -n jenkins -w

# View pod logs
sudo kubectl logs -f <pod-name> -n jenkins
```

### Jenkins Commands (from jenkins-controller)

```bash
# Check Jenkins status
sudo systemctl status jenkins

# Restart Jenkins
sudo systemctl restart jenkins

# View Jenkins logs
sudo journalctl -u jenkins -f
```

## Pod Templates Available

The following pod template is pre-configured:

1. **jnlp-agent**: Basic JNLP agent for running pipeline jobs

You can add more pod templates in the JCasC configuration at:
`/var/lib/jenkins/casc_configs/jenkins.yaml`

## Troubleshooting

### Jenkins Cannot Connect to Kubernetes

1. Verify kubeconfig is present:
   ```bash
   ls -la jenkins-config/kubeconfig
   ```

2. Verify network connectivity from Jenkins VM:
   ```bash
   vagrant ssh jenkins-controller
   kubectl cluster-info
   ```

3. Check if the K8s API server is accessible:
   ```bash
   curl -k https://YOUR_K8S_API_IP:6443
   ```

4. Verify RBAC permissions:
   ```bash
   kubectl auth can-i create pods -n jenkins --as=system:serviceaccount:jenkins:jenkins
   ```

### Agent Pods Not Starting

1. Check pod events:
   ```bash
   kubectl describe pod <pod-name> -n jenkins
   ```

2. Check Jenkins agent port (50000) is accessible from K8s nodes:
   ```bash
   nc -zv 192.168.8.171 50000
   ```

3. Ensure K8s nodes can reach Jenkins on port 8080 and 50000

### Token Expired

Service account tokens are generated with a 1-year expiration. To regenerate:

```bash
vagrant ssh jenkins-controller
NEW_TOKEN=$(sudo kubectl create token jenkins -n jenkins --duration=8760h)
echo $NEW_TOKEN
```

Then update the token in Jenkins: **Manage Jenkins** → **Credentials** → **k8s-service-account-token**

## Network Requirements

Ensure the following connectivity:

| From | To | Ports |
|------|-----|-------|
| Jenkins VM | K8s API | 6443/tcp |
| K8s Nodes | Jenkins VM | 8080/tcp, 50000/tcp |

## Cleanup

To remove the Jenkins VM:

```bash
vagrant destroy -f
```

Note: This does NOT remove resources created in your K8s cluster. To clean up K8s resources:

```bash
kubectl delete namespace jenkins
kubectl delete clusterrole jenkins-admin
kubectl delete clusterrolebinding jenkins-admin-binding
```

## File Structure

```
vagrant-jenkins-k8s/
├── Vagrantfile                          # Main Vagrant configuration
├── README.md                            # This file
├── scripts/
│   ├── provision-jenkins.sh             # Jenkins installation script
│   └── configure-jenkins-k8s.sh         # K8s cloud configuration script
├── k8s-manifests/
│   ├── jenkins-namespace.yaml           # Jenkins namespace
│   ├── jenkins-rbac.yaml                # RBAC for Jenkins
│   └── jenkins-agent-pod-template.yaml  # Agent pod templates
├── jenkins-config/
│   ├── kubeconfig.sample                # Sample kubeconfig template
│   └── kubeconfig                       # Your kubeconfig (create this)
└── examples/
    ├── Jenkinsfile.basic                # Basic pipeline example
    ├── Jenkinsfile.docker               # Docker pipeline example
    └── Jenkinsfile.maven                # Maven pipeline example
```

## License

MIT License
