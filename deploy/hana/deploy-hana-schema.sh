#!/bin/bash

# HANA Schema Deployment Script for CAP Applications
# This script deploys database schema and artifacts to HANA using HDI

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME=${APP_NAME:-bookshop}
NAMESPACE=${NAMESPACE:-default}
GEN_DB_DIR=${GEN_DB_DIR:-"../../gen/db"}
HANA_DEPLOYER_IMAGE=${HANA_DEPLOYER_IMAGE:-"ghcr.io/sim-jar/bookshop-hana-deployer:service-fix"}

echo -e "${BLUE}🚀 Starting HANA Schema Deployment${NC}"
echo "Application: $APP_NAME"
echo "Namespace: $NAMESPACE"
echo "Generated DB Directory: $GEN_DB_DIR"
echo "HANA Deployer Image: $HANA_DEPLOYER_IMAGE"
echo ""

# Function to check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}❌ kubectl is not installed or not in PATH${NC}"
        exit 1
    fi
}

# Function to verify prerequisites
verify_prerequisites() {
    echo -e "${BLUE}🔍 Verifying prerequisites...${NC}"
    
    # Check if generated DB artifacts exist
    if [ ! -d "$GEN_DB_DIR" ]; then
        echo -e "${RED}❌ Generated DB directory not found: $GEN_DB_DIR${NC}"
        echo "Please run 'cds build' to generate database artifacts first"
        exit 1
    fi
    
    # Check if HANA service binding exists
    if ! kubectl get secret "${APP_NAME}-hana-secret" -n "$NAMESPACE" &> /dev/null; then
        echo -e "${RED}❌ HANA service binding secret '${APP_NAME}-hana-secret' not found${NC}"
        echo "Please ensure the HANA service instance and binding are deployed first"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Prerequisites verified${NC}"
}

# Function to create HANA deployer job
create_deployer_job() {
    echo -e "${BLUE}🚀 Creating HANA deployer job...${NC}"

    # Create Job YAML
    cat > "$SCRIPT_DIR/hana-deployer-job.yaml" << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${APP_NAME}-hana-deployer
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    component: hana-deployer
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        component: hana-deployer
    spec:
      imagePullSecrets:
      - name: ghcr-secret
      restartPolicy: OnFailure
      initContainers:
      - name: vcap-services-generator
        image: alpine:latest
        command: ["/bin/sh"]
        args:
          - -c
          - |
            # Create VCAP_SERVICES file from HANA service binding credentials
            # Escape certificate for JSON
            CERT_ESCAPED=\$(echo "\$certificate" | sed 's/"/\\\\"/g' | sed ':a;N;\$!ba;s/\\n/\\\\n/g')

            cat > /shared/vcap_services.json << EOFVCAP
            {
              "hana": [{
                "label": "hana",
                "name": "${APP_NAME}-hana",
                "plan": "hdi-shared",
                "credentials": {
                  "database_id": "\$database_id",
                  "driver": "\$driver",
                  "hdi_password": "\$hdi_password",
                  "hdi_user": "\$hdi_user",
                  "host": "\$host",
                  "password": "\$password",
                  "port": "\$port",
                  "schema": "\$schema",
                  "url": "\$url",
                  "user": "\$user",
                  "certificate": "\$CERT_ESCAPED"
                }
              }]
            }
            EOFVCAP

            echo "VCAP_SERVICES file created successfully for HANA"
        envFrom:
        - secretRef:
            name: ${APP_NAME}-hana-secret
        volumeMounts:
        - name: vcap-services
          mountPath: /shared
      containers:
      - name: hana-deployer
        image: ${HANA_DEPLOYER_IMAGE}
        command: ["/bin/sh"]
        args:
          - -c
          - |
            export VCAP_SERVICES="\$(cat /shared/vcap_services.json)"
            echo "Starting HANA deployer with VCAP_SERVICES..."
            echo "Preparing HDI deployment artifacts..."
            cd src

            # Copy all deployment artifacts from gen to current directory (including hidden files)
            echo "Copying deployment artifacts from gen/ to current directory..."
            cp -r gen/* .
            # Explicitly copy hidden files
            cp gen/.hdiconfig . 2>/dev/null || echo "No .hdiconfig found"
            cp gen/.hdinamespace . 2>/dev/null || echo "No .hdinamespace found"

            echo "Current working directory:"
            pwd
            echo "Files in current directory after copying:"
            ls -la
            echo "Checking for .hdiconfig file:"
            ls -la .hdiconfig || echo "No .hdiconfig file found"
            echo "Content of .hdiconfig file:"
            cat .hdiconfig || echo "Cannot read .hdiconfig"
            echo "Content of .hdinamespace file:"
            cat .hdinamespace || echo "Cannot read .hdinamespace"
            echo "VCAP_SERVICES content:"
            echo "\$VCAP_SERVICES"
            echo "Running HDI deployment..."
            # Run HDI deployer directly from the src directory where artifacts are located
            echo "Running HDI deployer directly from src directory..."
            node ../node_modules/@sap/hdi-deploy/deploy.js --use-hdb
        env:
        - name: NODE_ENV
          value: "production"
        - name: EXIT
          value: "1"  # Exit after deployment
        volumeMounts:
        - name: vcap-services
          mountPath: /shared
        envFrom:
        - secretRef:
            name: ${APP_NAME}-hana-secret
        resources:
          requests:
            memory: "1Gi"
            cpu: "1000m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
      volumes:
      - name: vcap-services
        emptyDir: {}
EOF
    
    echo -e "${GREEN}✅ Job YAML created${NC}"
}

# Function to cleanup existing job
cleanup_existing_job() {
    if kubectl get job "${APP_NAME}-hana-deployer" -n "$NAMESPACE" &> /dev/null; then
        echo -e "${YELLOW}🧹 Cleaning up existing HANA deployer job...${NC}"
        kubectl delete job "${APP_NAME}-hana-deployer" -n "$NAMESPACE" --ignore-not-found=true

        # Wait for job to be deleted
        while kubectl get job "${APP_NAME}-hana-deployer" -n "$NAMESPACE" &> /dev/null; do
            echo "Waiting for job deletion..."
            sleep 2
        done
    fi
}

# Function to deploy HANA schema
deploy_schema() {
    echo -e "${BLUE}🚀 Deploying HANA schema...${NC}"

    # Apply Job
    kubectl apply -f "$SCRIPT_DIR/hana-deployer-job.yaml"

    echo -e "${GREEN}✅ HANA deployer job created${NC}"
}

# Function to wait for deployment completion
wait_for_completion() {
    echo -e "${BLUE}⏳ Waiting for HANA deployment to complete...${NC}"

    # Wait for job to complete
    if kubectl wait --for=condition=complete job/"${APP_NAME}-hana-deployer" \
        -n "${NAMESPACE}" --timeout=600s; then
        echo -e "${GREEN}✅ HANA deployment completed successfully${NC}"
    else
        echo -e "${RED}❌ HANA deployment failed or timed out${NC}"

        # Show job status and logs for debugging
        echo -e "${YELLOW}🔍 Job status:${NC}"
        kubectl describe job "${APP_NAME}-hana-deployer" -n "${NAMESPACE}"

        echo -e "${YELLOW}🔍 Job logs:${NC}"
        kubectl logs job/"${APP_NAME}-hana-deployer" -n "${NAMESPACE}" || echo "No logs available"

        exit 1
    fi
}

# Function to show deployment logs
show_logs() {
    echo -e "${BLUE}📋 Deployment logs:${NC}"
    kubectl logs job/"${APP_NAME}-hana-deployer" -n "${NAMESPACE}" || echo "No logs available"
}

# Main execution
main() {
    check_kubectl
    verify_prerequisites
    cleanup_existing_job
    create_deployer_job
    deploy_schema
    wait_for_completion
    show_logs

    echo ""
    echo -e "${GREEN}🎉 HANA Schema Deployment Complete!${NC}"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --cleanup      Clean up HANA deployment job"
        echo "  --logs         Show deployment logs"
        echo ""
        echo "Environment variables:"
        echo "  APP_NAME       Application name (default: bookshop)"
        echo "  NAMESPACE      Kubernetes namespace (default: default)"
        echo "  GEN_DB_DIR     Path to generated DB artifacts (default: ../../gen/db)"
        echo "  HANA_DEPLOYER_IMAGE  Docker image for HANA deployer"
        exit 0
        ;;
    --cleanup)
        echo -e "${YELLOW}🧹 Cleaning up HANA deployment...${NC}"
        kubectl delete job "${APP_NAME}-hana-deployer" -n "${NAMESPACE}" --ignore-not-found=true
        echo -e "${GREEN}✅ Cleanup complete${NC}"
        exit 0
        ;;
    --logs)
        echo -e "${BLUE}📋 HANA deployment logs:${NC}"
        kubectl logs job/"${APP_NAME}-hana-deployer" -n "${NAMESPACE}" || echo "No logs available"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo -e "${RED}❌ Unknown option: $1${NC}"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
