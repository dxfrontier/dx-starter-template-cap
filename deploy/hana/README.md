# HANA Schema Deployment

This directory contains the deployment scripts and configuration for deploying database schema and artifacts to SAP HANA using HDI (HANA Deployment Infrastructure) for CAP applications.

## Overview

The HANA schema deployment consists of:
- **Job**: Runs the HDI deployer to deploy database artifacts
- **Deployment Script**: Automates the entire process
- **Generated Artifacts**: Uses CDS-generated database artifacts

## Prerequisites

1. **Generated Database Artifacts**: Run `cds build` in your CAP project to generate artifacts in `gen/db/`
2. **HANA Service**: The HANA service instance and binding must be deployed
3. **kubectl**: Configured to access your Kubernetes cluster
4. **Docker Image**: HANA deployer image must be available (with HDI deploy tools)
5. **Image Pull Secret**: `ghcr-secret` must be configured for private registries

## Files

- `deploy-hana-schema.sh` - Main deployment script
- `hana-deployer-job.yaml` - Generated Job (created by script)

## Usage

### Basic Deployment

```bash
# Deploy HANA schema with default settings
./deploy-hana-schema.sh
```

### Custom Configuration

```bash
# Deploy with custom application name and namespace
APP_NAME=myapp NAMESPACE=production ./deploy-hana-schema.sh

# Deploy with custom database artifacts directory
GEN_DB_DIR=/path/to/gen/db ./deploy-hana-schema.sh

# Deploy with custom HANA deployer image
HANA_DEPLOYER_IMAGE=my-registry/hana-deployer:latest ./deploy-hana-schema.sh
```

### Environment Variables

- `APP_NAME` - Application name (default: `bookshop`)
- `NAMESPACE` - Kubernetes namespace (default: `default`)
- `GEN_DB_DIR` - Path to generated database artifacts (default: `../../gen/db`)
- `HANA_DEPLOYER_IMAGE` - Docker image for HANA deployer

### Cleanup

```bash
# Remove deployment job
./deploy-hana-schema.sh --cleanup
```

### View Logs

```bash
# Show deployment logs
./deploy-hana-schema.sh --logs
```

### Help

```bash
# Show usage information
./deploy-hana-schema.sh --help
```

## How It Works

1. **Artifact Verification**: The script checks for generated database artifacts in `gen/db/`
2. **Service Verification**: Ensures HANA service binding secret exists
3. **Job Creation**: Creates a Kubernetes job that:
   - Uses an init container to generate VCAP_SERVICES from service binding
   - Uses a HANA deployer image with HDI tools
   - Copies generated artifacts to the deployment directory
   - Runs HDI deployment using `@sap/hdi-deploy`
   - Automatically retries on failure (backoffLimit: 3)
4. **Monitoring**: Waits for job completion and shows logs

## Generated Files

The script generates the following file dynamically:

### hana-deployer-job.yaml
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ${APP_NAME}-hana-deployer
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 3
  template:
    spec:
      initContainers:
      - name: vcap-services-generator
        # Generates VCAP_SERVICES from service binding
      containers:
      - name: hana-deployer
        image: ${HANA_DEPLOYER_IMAGE}
        # Script that deploys database artifacts using HDI
        envFrom:
        - secretRef:
            name: ${APP_NAME}-hana-secret
```

## HANA Deployer Image

The deployment requires a Docker image that contains:
- Node.js runtime
- `@sap/hdi-deploy` package
- Generated database artifacts (copied during deployment)

Example Dockerfile for HANA deployer:
```dockerfile
FROM node:18-alpine
WORKDIR /usr/src/app
COPY package*.json ./
RUN npm ci --omit=dev
COPY gen/ gen/
EXPOSE 4004
```

## Database Artifacts

The deployment expects the following structure in `gen/db/`:
```
gen/db/
├── .hdiconfig          # HDI configuration
├── .hdinamespace       # HDI namespace (optional)
├── src/
│   ├── *.hdbcds        # CDS table definitions
│   ├── *.hdbview       # View definitions
│   └── data/           # CSV data files
└── package.json        # Dependencies
```

## Troubleshooting

### Common Issues

1. **Generated artifacts not found**
   ```
   ❌ Generated DB directory not found: ../../gen/db
   ```
   **Solution**: Run `cds build` in your CAP project root

2. **HANA service secret not found**
   ```
   ❌ HANA service binding secret 'bookshop-hana-secret' not found
   ```
   **Solution**: Deploy the HANA service instance and binding first

3. **Image pull errors**
   ```
   Failed to pull image "ghcr.io/..."
   ```
   **Solution**: Ensure `ghcr-secret` is properly configured

4. **HDI deployment fails**
   **Solution**: Check HANA credentials and database connectivity

### Debugging

1. **Check job logs**:
   ```bash
   kubectl logs job/${APP_NAME}-hana-deployer
   ```

2. **Check job status**:
   ```bash
   kubectl describe job ${APP_NAME}-hana-deployer
   ```

3. **Check HANA service binding**:
   ```bash
   kubectl get secret ${APP_NAME}-hana-secret -o yaml
   ```

4. **Verify generated artifacts**:
   ```bash
   ls -la gen/db/
   ```

## Integration with Main Deployment

This HANA deployment can be integrated into your main deployment script:

```bash
#!/bin/bash

# 1. Deploy infrastructure (services, bindings)
kubectl apply -f k8s/services/

# 2. Deploy HANA schema
cd deploy/hana && ./deploy-hana-schema.sh && cd ../..

# 3. Deploy AMS policies
cd deploy/ams && ./deploy-ams-policies.sh && cd ../..

# 4. Deploy application
kubectl apply -f k8s/deployment.yaml
```

## Security Notes

- HANA credentials are passed via Kubernetes secrets
- The deployment job has access to the HANA database
- Ensure proper RBAC is configured for the deployment job
- Use resource limits to prevent resource exhaustion
- The job automatically retries on failure and cleans up after completion

## Performance Considerations

- The deployment job requests 1Gi memory and 1 CPU core
- Limits are set to 2Gi memory and 2 CPU cores
- Adjust resource requests/limits based on your database size
- Large databases may require longer timeout values
- Jobs have automatic retry capability (backoffLimit: 3)
