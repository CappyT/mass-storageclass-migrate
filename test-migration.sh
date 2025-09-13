#!/bin/bash

# THIS SCRIPT IS MEANT TO TEST A SINGLE PVC MIGRATION ON SAMPLE DATA. PLEASE USE THIS BEFORE MIGRATING YOUR DATA

# --- Configuration ---
SOURCE_PVC_NAME="data-gitea"
NAMESPACE="default"
TARGET_STORAGE_CLASS="local-replica2"
# --- End Configuration ---

set -eo pipefail

TEMP_PVC_NAME="${SOURCE_PVC_NAME}-migratetemp"

echo "➡️ Starting migration for PVC '${SOURCE_PVC_NAME}' in namespace '${NAMESPACE}' to StorageClass '${TARGET_STORAGE_CLASS}'"

# --- 1. Get PVC Info & Identify Workload ---
echo "🔍 Gathering details for PVC '${SOURCE_PVC_NAME}'..."
PVC_INFO_JSON=$(kubectl get pvc "${SOURCE_PVC_NAME}" -n "${NAMESPACE}" -o json)
if [ -z "$PVC_INFO_JSON" ]; then
    echo "❌ ERROR: PVC '${SOURCE_PVC_NAME}' not found."
    exit 1
fi

PVC_SIZE=$(echo "$PVC_INFO_JSON" | jq -r '.spec.resources.requests.storage')
ACCESS_MODES=$(echo "$PVC_INFO_JSON" | jq -r '.spec.accessModes | join(",")')

echo "🔍 Identifying workload..."
POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -o json | jq -r --arg pvc_name "$SOURCE_PVC_NAME" '.items[] | select(.spec.volumes[].persistentVolumeClaim.claimName == $pvc_name) | .metadata.name' | head -n1)

WORKLOAD_TYPE=""
WORKLOAD_NAME=""
ORIGINAL_REPLICAS=""
POD_SELECTOR=""

if [ -z "$POD_NAME" ]; then
    echo "⚠️ No running pod found using this PVC. Proceeding with data-only migration."
else
    OWNER_INFO=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o json | jq -r '.metadata.ownerReferences[0] | "\(.kind)/\(.name)"' || echo "")
    if [ -n "$OWNER_INFO" ]; then
        OWNER_KIND=$(echo "$OWNER_INFO" | cut -d'/' -f1)
        OWNER_NAME=$(echo "$OWNER_INFO" | cut -d'/' -f2)
        if [ "$OWNER_KIND" == "ReplicaSet" ]; then
            DEPLOYMENT_INFO=$(kubectl get replicaset "${OWNER_NAME}" -n "${NAMESPACE}" -o json | jq -r '.metadata.ownerReferences[0] | "\(.kind)/\(.name)"')
            WORKLOAD_TYPE=$(echo "$DEPLOYMENT_INFO" | cut -d'/' -f1)
            WORKLOAD_NAME=$(echo "$DEPLOYMENT_INFO" | cut -d'/' -f2)
        else
            WORKLOAD_TYPE=$OWNER_KIND
            WORKLOAD_NAME=$OWNER_NAME
        fi
        echo "✅ Found workload: ${WORKLOAD_TYPE}/${WORKLOAD_NAME}"
        
        POD_SELECTOR=$(kubectl get "${WORKLOAD_TYPE}" "${WORKLOAD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        echo "   Pods are managed by selector: '${POD_SELECTOR}'"
    fi
fi

# --- 2. Scale Down Workload ---
if [ -n "$WORKLOAD_NAME" ]; then
    echo "⏬ Scaling down ${WORKLOAD_TYPE} '${WORKLOAD_NAME}'..."
    ORIGINAL_REPLICAS=$(kubectl get "${WORKLOAD_TYPE}" "${WORKLOAD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')
    kubectl scale --replicas=0 "${WORKLOAD_TYPE}"/"${WORKLOAD_NAME}" -n "${NAMESPACE}"
    
    echo "   Waiting for pods with selector '${POD_SELECTOR}' to terminate..."
    kubectl wait --for=delete pod -l "${POD_SELECTOR}" -n "${NAMESPACE}" --timeout=5m
    echo "   All pods terminated."
fi

# --- 3. First Hop: Source -> Temp ---
echo "🚀 Starting Hop 1: Migrating data to temporary PVC."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEMP_PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes: [$(echo "$ACCESS_MODES" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]
  storageClassName: ${TARGET_STORAGE_CLASS}
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF

echo "   Running pv-migrate..."
kubectl pv-migrate migrate "${SOURCE_PVC_NAME}" "${TEMP_PVC_NAME}" \
  --source-namespace "${NAMESPACE}" \
  --dest-namespace "${NAMESPACE}" \
  --ignore-mounted

# --- 4. Recreate Original PVC ---
echo "🔄 Recreating original PVC with new StorageClass."
kubectl delete pvc "${SOURCE_PVC_NAME}" -n "${NAMESPACE}" --wait=true
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SOURCE_PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes: [$(echo "$ACCESS_MODES" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]
  storageClassName: ${TARGET_STORAGE_CLASS}
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF

# --- 5. Second Hop: Temp -> New Original ---
echo "🚀 Starting Hop 2: Migrating data back to the recreated original PVC."
kubectl pv-migrate migrate "${TEMP_PVC_NAME}" "${SOURCE_PVC_NAME}" \
  --source-namespace "${NAMESPACE}" \
  --dest-namespace "${NAMESPACE}" \
  --ignore-mounted

# --- 6. Cleanup & Scale Up ---
echo "🧹 Cleaning up temporary PVC '${TEMP_PVC_NAME}'..."
kubectl delete pvc "${TEMP_PVC_NAME}" -n "${NAMESPACE}"
if [ -n "$WORKLOAD_NAME" ]; then
    echo "⏫ Scaling up ${WORKLOAD_TYPE} '${WORKLOAD_NAME}' to ${ORIGINAL_REPLICAS} replicas..."
    kubectl scale --replicas="${ORIGINAL_REPLICAS}" "${WORKLOAD_TYPE}"/"${WORKLOAD_NAME}" -n "${NAMESPACE}"
fi

echo "✅ Migration for '${SOURCE_PVC_NAME}' is complete!"