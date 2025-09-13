#!/bin/bash

# --- Configuration ---
SOURCE_STORAGE_CLASS="local-replica"
TARGET_STORAGE_CLASS="new-sc"
NAMESPACE=""
# --- End Configuration ---

set -eo pipefail

migrate_pvc() {
    local SOURCE_PVC_NAME=$1
    local NAMESPACE=$2
    local TARGET_STORAGE_CLASS=$3
    local TEMP_PVC_NAME="${SOURCE_PVC_NAME}-migratetemp"

    echo "======================================================================"
    echo "➡️ Starting migration for PVC '${SOURCE_PVC_NAME}' in namespace '${NAMESPACE}'"
    echo "======================================================================"

    local PVC_INFO_JSON
    PVC_INFO_JSON=$(kubectl get pvc "${SOURCE_PVC_NAME}" -n "${NAMESPACE}" -o json)
    local PVC_SIZE
    PVC_SIZE=$(echo "$PVC_INFO_JSON" | jq -r '.spec.resources.requests.storage')
    local ACCESS_MODES
    ACCESS_MODES=$(echo "$PVC_INFO_JSON" | jq -r '.spec.accessModes | join(",")')
    
    local POD_NAME
    POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -o json | jq -r --arg pvc_name "$SOURCE_PVC_NAME" '.items[] | select(.spec.volumes[].persistentVolumeClaim.claimName == $pvc_name) | .metadata.name' | head -n1)

    local WORKLOAD_TYPE=""
    local WORKLOAD_NAME=""
    local ORIGINAL_REPLICAS=""
    local POD_SELECTOR=""

    if [ -z "$POD_NAME" ]; then
        echo "⚠️ No running pod found using this PVC. Proceeding with data-only migration."
    else
        local OWNER_INFO
        OWNER_INFO=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o json | jq -r '.metadata.ownerReferences[0] | "\(.kind)/\(.name)"' || echo "")
        if [ -n "$OWNER_INFO" ]; then
            local OWNER_KIND
            OWNER_KIND=$(echo "$OWNER_INFO" | cut -d'/' -f1)
            local OWNER_NAME
            OWNER_NAME=$(echo "$OWNER_INFO" | cut -d'/' -f2)
            if [ "$OWNER_KIND" == "ReplicaSet" ]; then
                local DEPLOYMENT_INFO
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
    
    if [ -n "$WORKLOAD_NAME" ]; then
        echo "⏬ Scaling down ${WORKLOAD_TYPE} '${WORKLOAD_NAME}'..."
        ORIGINAL_REPLICAS=$(kubectl get "${WORKLOAD_TYPE}" "${WORKLOAD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')
        kubectl scale --replicas=0 "${WORKLOAD_TYPE}"/"${WORKLOAD_NAME}" -n "${NAMESPACE}"
        echo "   Waiting for pods with selector '${POD_SELECTOR}' to terminate..."
        kubectl wait --for=delete pod -l "${POD_SELECTOR}" -n "${NAMESPACE}" --timeout=5m
        echo "   All pods terminated."
    fi
    
    echo "🚀 Hop 1: Migrating to temporary PVC '${TEMP_PVC_NAME}'..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEMP_PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes: [$(echo "$ACCESS_MODES" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]
  storageClassName: ${TARGET_STORAGE_CLASS}
  resources: { requests: { storage: ${PVC_SIZE} } }
EOF
    
    kubectl pv-migrate migrate "${SOURCE_PVC_NAME}" "${TEMP_PVC_NAME}" --source-namespace "${NAMESPACE}" --dest-namespace "${NAMESPACE}" --ignore-mounted

    echo "🔄 Recreating original PVC..."
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
  resources: { requests: { storage: ${PVC_SIZE} } }
EOF

    echo "🚀 Hop 2: Migrating back to recreated PVC '${SOURCE_PVC_NAME}'..."
    kubectl pv-migrate migrate "${TEMP_PVC_NAME}" "${SOURCE_PVC_NAME}" --source-namespace "${NAMESPACE}" --dest-namespace "${NAMESPACE}" --ignore-mounted

    echo "🧹 Cleaning up temporary PVC..."
    kubectl delete pvc "${TEMP_PVC_NAME}" -n "${NAMESPACE}"
    if [ -n "$WORKLOAD_NAME" ]; then
        echo "⏫ Scaling up ${WORKLOAD_TYPE} '${WORKLOAD_NAME}' to ${ORIGINAL_REPLICAS} replicas..."
        kubectl scale --replicas="${ORIGINAL_REPLICAS}" "${WORKLOAD_TYPE}"/"${WORKLOAD_NAME}" -n "${NAMESPACE}"
    fi
    echo "✅ Migration for '${SOURCE_PVC_NAME}' is complete!"
}

# --- Main Execution ---
NAMESPACE_FLAG=""
if [ -n "$NAMESPACE" ]; then
    NAMESPACE_FLAG="--namespace=${NAMESPACE}"
fi

echo "🔎 Finding non-CNPG PVCs with StorageClass '${SOURCE_STORAGE_CLASS}'..."
PVC_LIST=$(kubectl get pvc --all-namespaces $NAMESPACE_FLAG -o json | \
           jq -r --arg sc "$SOURCE_STORAGE_CLASS" '.items[] | 
           select(
             .spec.storageClassName == $sc and 
             (.metadata.labels | has("cnpg.io/cluster") | not)
           ) | 
           "\(.metadata.name) \(.metadata.namespace)"')

if [ -z "$PVC_LIST" ]; then
    echo "No non-CNPG PVCs found with StorageClass '${SOURCE_STORAGE_CLASS}'."
    exit 0
fi

echo "The following PVCs will be migrated from '${SOURCE_STORAGE_CLASS}' to '${TARGET_STORAGE_CLASS}':"
echo "$PVC_LIST"
echo ""
read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Migration cancelled."
    exit 1
fi

while read -r PVC_NAME PVC_NAMESPACE; do
    migrate_pvc "$PVC_NAME" "$PVC_NAMESPACE" "$TARGET_STORAGE_CLASS"
done <<< "$PVC_LIST"

echo "🎉 All migrations are complete."