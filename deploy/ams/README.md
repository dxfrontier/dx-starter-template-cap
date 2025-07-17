# AMS Policy Deployment

This directory contains the deployment scripts and configuration for deploying AMS (Authorization Management Service) policies to Kubernetes/Kyma for CAP applications.

## Overview

The AMS policy deployment consists of:
- **ConfigMap**: Contains the generated DCL policies and package.json
- **Job**: Deploys the policies to the AMS service
- **Deployment Script**: Automates the entire process

## Prerequisites

1. **Generated Policies**: Run `cds build` in your CAP project to generate policies in `gen/policies/`
2. **Identity Service**: The identity service instance and binding must be deployed
3. **kubectl**: Configured to access your Kubernetes cluster
4. **jq**: Required for JSON processing (install with `apt-get install jq` or `brew install jq`)

## Files

- `deploy-ams-policies.sh` - Main deployment script
- `ams-policies-configmap.yaml` - Generated ConfigMap (created by script)
- `ams-policy-deployer-job.yaml` - Generated Job (created by script)

## Usage

### Basic Deployment

```bash
# Deploy AMS policies with default settings
./deploy-ams-policies.sh
```

### Custom Configuration

```bash
# Deploy with custom application name and namespace
APP_NAME=myapp NAMESPACE=production ./deploy-ams-policies.sh

# Deploy with custom policies directory
GEN_POLICIES_DIR=/path/to/policies ./deploy-ams-policies.sh
```

### Environment Variables

- `APP_NAME` - Application name (default: `bookshop`)
- `NAMESPACE` - Kubernetes namespace (default: `default`)
- `GEN_POLICIES_DIR` - Path to generated policies directory (default: `../../gen/policies`)

### Cleanup

```bash
# Remove deployed AMS policies
./deploy-ams-policies.sh --cleanup
```

### Help

```bash
# Show usage information
./deploy-ams-policies.sh --help
```

## How It Works

1. **Policy Generation**: The script reads DCL policies from `gen/policies/dcl/`
2. **ConfigMap Creation**: Creates a ConfigMap with:
   - `package.json` - Dependencies for AMS deployment
   - `basePolicies.dcl` - Generated base policies
   - `schema.dcl` - Generated schema definitions
3. **Secret Management**: Creates or reuses a secret with identity service credentials
4. **Job Deployment**: Runs a Kubernetes job that:
   - Copies policies from ConfigMap to working directory
   - Creates VCAP_SERVICES environment variable
   - Installs dependencies and deploys policies using `@sap/ams deploy-dcl`

## Generated Files

The script generates the following files dynamically:

### ams-policies-configmap.yaml
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-ams-policies
  namespace: ${NAMESPACE}
data:
  package.json: |
    # Content from gen/policies/package.json
  basePolicies.dcl: |
    # Content from gen/policies/dcl/cap/basePolicies.dcl
  schema.dcl: |
    # Content from gen/policies/dcl/schema.dcl
```

### ams-policy-deployer-job.yaml
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ${APP_NAME}-ams-policy-deployer
spec:
  template:
    spec:
      containers:
      - name: ams-policy-deployer
        image: node:18-alpine
        # Script that deploys policies using @sap/ams
```

## Troubleshooting

### Common Issues

1. **Generated policies not found**
   ```
   ❌ Generated policies directory not found: ../../gen/policies
   ```
   **Solution**: Run `cds build` in your CAP project root

2. **Identity service secret not found**
   ```
   ❌ Identity service binding secret 'bookshop-identity-secret' not found
   ```
   **Solution**: Deploy the identity service instance and binding first

3. **Job fails with authentication error**
   **Solution**: Check that the identity service credentials are correct and the service is properly bound

### Debugging

1. **Check job logs**:
   ```bash
   kubectl logs job/${APP_NAME}-ams-policy-deployer
   ```

2. **Check job status**:
   ```bash
   kubectl describe job ${APP_NAME}-ams-policy-deployer
   ```

3. **Check ConfigMap content**:
   ```bash
   kubectl get configmap ${APP_NAME}-ams-policies -o yaml
   ```

## Integration with Main Deployment

This AMS deployment can be integrated into your main deployment script:

```bash
#!/bin/bash

# 1. Deploy infrastructure (services, bindings)
kubectl apply -f k8s/services/

# 2. Deploy AMS policies
cd deploy/ams && ./deploy-ams-policies.sh && cd ../..

# 3. Deploy application
kubectl apply -f k8s/deployment.yaml
```

## Security Notes

- The deployment job uses `NODE_TLS_REJECT_UNAUTHORIZED=0` for development
- Remove this setting in production environments
- Ensure proper RBAC is configured for the deployment job
- Secrets are automatically cleaned up after use
