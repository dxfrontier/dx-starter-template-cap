#!/bin/bash

# AMS Policy Deployment Script for CAP Applications
# This script deploys AMS policies to enable authorization in the CAP application

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
GEN_POLICIES_DIR=${GEN_POLICIES_DIR:-"../../gen/policies"}

echo -e "${BLUE}🚀 Starting AMS Policy Deployment${NC}"
echo "Application: $APP_NAME"
echo "Namespace: $NAMESPACE"
echo "Generated Policies Directory: $GEN_POLICIES_DIR"
echo ""

# Function to check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}❌ kubectl is not installed or not in PATH${NC}"
        exit 1
    fi
}

# Function to create ConfigMap from generated policies
create_configmap() {
    echo -e "${BLUE}📋 Creating AMS policies ConfigMap...${NC}"
    
    # Check if generated policies exist
    if [ ! -d "$GEN_POLICIES_DIR" ]; then
        echo -e "${RED}❌ Generated policies directory not found: $GEN_POLICIES_DIR${NC}"
        echo "Please run 'cds build' to generate policies first"
        exit 1
    fi
    
    # Create ConfigMap YAML
    cat > "$SCRIPT_DIR/ams-policies-configmap.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-ams-policies
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    component: ams-policies
data:
  package.json: |
$(cat "$GEN_POLICIES_DIR/package.json" | sed 's/^/    /')
  basePolicies.dcl: |
$(cat "$GEN_POLICIES_DIR/dcl/cap/basePolicies.dcl" | sed 's/^/    /')
  schema.dcl: |
$(cat "$GEN_POLICIES_DIR/dcl/schema.dcl" | sed 's/^/    /')
EOF
    
    echo -e "${GREEN}✅ ConfigMap created${NC}"
}

# Function to create AMS policy deployer job
create_job() {
    echo -e "${BLUE}🚀 Creating AMS policy deployer job...${NC}"
    
    # Create Job YAML
    cat > "$SCRIPT_DIR/ams-policy-deployer-job.yaml" << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${APP_NAME}-ams-policy-deployer
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    component: ams-policy-deployer
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        component: ams-policy-deployer
    spec:
      restartPolicy: OnFailure
      containers:
      - name: ams-policy-deployer
        image: node:18-alpine
        command: ["/bin/sh"]
        args:
          - -c
          - |
            echo "Starting AMS policy deployment..."

            # Create working directory in writable location
            mkdir -p /tmp/policies/dcl/cap
            cd /tmp/policies

            # Copy files from ConfigMap
            cp /policies/package.json .
            cp /policies/basePolicies.dcl dcl/cap/
            cp /policies/schema.dcl dcl/

            # Create VCAP_SERVICES environment variable (Cloud Foundry format)
            # Escape certificate and key for JSON
            CERT_ESCAPED=\$(echo "\$certificate" | sed 's/"/\\\\"/g' | sed ':a;N;\$!ba;s/\\n/\\\\n/g')
            KEY_ESCAPED=\$(echo "\$key" | sed 's/"/\\\\"/g' | sed ':a;N;\$!ba;s/\\n/\\\\n/g')

            export VCAP_SERVICES=\$(cat << EOFVCAP
            {
              "identity": [{
                "label": "identity",
                "name": "${APP_NAME}-identity",
                "plan": "application",
                "credentials": {
                  "clientid": "\$clientid",
                  "certificate": "\$CERT_ESCAPED",
                  "key": "\$KEY_ESCAPED",
                  "url": "\$url",
                  "domain": "\$domain",
                  "authorization_endpoint": "\$authorization_endpoint",
                  "authorization_client_id": "\$authorization_client_id",
                  "authorization_instance_id": "\$authorization_instance_id",
                  "authorization_bundle_url": "\$authorization_bundle_url"
                }
              }]
            }
            EOFVCAP
            )

            echo "=== VCAP_SERVICES content ==="
            echo "\$VCAP_SERVICES"
            echo "=== End VCAP_SERVICES ==="

            # Install dependencies and deploy
            npm install

            echo "Deploying AMS policies using VCAP_SERVICES..."
            npx @sap/ams deploy-dcl

            echo "AMS policy deployment completed successfully!"
        volumeMounts:
        - name: policies
          mountPath: /policies
        envFrom:
        - secretRef:
            name: ${APP_NAME}-ams-deployer-secret
        env:
        - name: NODE_TLS_REJECT_UNAUTHORIZED
          value: "0"  # For development - remove in production
      volumes:
      - name: policies
        configMap:
          name: ${APP_NAME}-ams-policies
EOF
    
    echo -e "${GREEN}✅ Job created${NC}"
}

# Function to deploy AMS policies
deploy_policies() {
    echo -e "${BLUE}🚀 Deploying AMS policies...${NC}"
    
    # Apply ConfigMap
    kubectl apply -f "$SCRIPT_DIR/ams-policies-configmap.yaml"
    
    # Check if secret exists
    if ! kubectl get secret "${APP_NAME}-ams-deployer-secret" -n "${NAMESPACE}" &> /dev/null; then
        echo -e "${YELLOW}⚠️ Secret '${APP_NAME}-ams-deployer-secret' not found${NC}"
        echo "Creating secret from identity service binding..."
        
        # Extract credentials from identity service binding
        kubectl get secret "${APP_NAME}-identity-secret" -n "${NAMESPACE}" -o jsonpath='{.data}' | \
        jq -r 'to_entries | map("\(.key)=\(.value | @base64d)") | .[]' > "${APP_NAME}-identity-creds.env"
        
        # Create secret for AMS deployer
        kubectl create secret generic "${APP_NAME}-ams-deployer-secret" \
            --from-env-file="${APP_NAME}-identity-creds.env" \
            -n "${NAMESPACE}"
        
        # Clean up temporary file
        rm "${APP_NAME}-identity-creds.env"
    fi
    
    # Apply Job
    kubectl apply -f "$SCRIPT_DIR/ams-policy-deployer-job.yaml"
    
    echo -e "${GREEN}✅ AMS policies deployed${NC}"
}

# Function to wait for job completion
wait_for_completion() {
    echo -e "${BLUE}⏳ Waiting for AMS policy deployment to complete...${NC}"
    
    # Wait for job to complete
    kubectl wait --for=condition=complete job/"${APP_NAME}-ams-policy-deployer" \
        -n "${NAMESPACE}" --timeout=300s
    
    echo -e "${GREEN}✅ AMS policy deployment completed successfully${NC}"
}

# Main execution
main() {
    check_kubectl
    create_configmap
    create_job
    deploy_policies
    wait_for_completion
    
    echo ""
    echo -e "${GREEN}🎉 AMS Policy Deployment Complete!${NC}"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --cleanup      Clean up AMS policy deployment"
        echo ""
        echo "Environment variables:"
        echo "  APP_NAME       Application name (default: bookshop)"
        echo "  NAMESPACE      Kubernetes namespace (default: default)"
        echo "  GEN_POLICIES_DIR  Path to generated policies (default: ../../gen/policies)"
        exit 0
        ;;
    --cleanup)
        echo -e "${YELLOW}🧹 Cleaning up AMS policy deployment...${NC}"
        kubectl delete job "${APP_NAME}-ams-policy-deployer" -n "${NAMESPACE}" --ignore-not-found=true
        kubectl delete configmap "${APP_NAME}-ams-policies" -n "${NAMESPACE}" --ignore-not-found=true
        echo -e "${GREEN}✅ Cleanup complete${NC}"
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
