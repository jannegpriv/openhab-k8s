#!/bin/sh

# Create timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="openhab-backup-${TIMESTAMP}"

# NAS details
NAS_USER="jannenasadm"
NAS_HOST="192.168.50.25"
NAS_PATH="/volume1/openhab_backups"
OPENHAB_POD="openhab-production-0"

# Get NAS password from environment
NAS_PASS="${NAS_PASSWORD}"

# Create backup using kubectl exec
echo "Creating backup in OpenHAB pod..."
# Clean up old backups in OpenHAB pod
echo "Cleaning up old backups..."
kubectl exec -n openhab ${OPENHAB_POD} -- bash -c "rm -f /openhab/*.zip /openhab/userdata/backup/*.zip"

# Create new backup
echo "Creating backup in OpenHAB pod..."
kubectl exec -n openhab ${OPENHAB_POD} -- bash -c "set -e && \
  export OPENHAB_CONF=/openhab/conf && \
  export OPENHAB_USERDATA=/openhab/userdata && \
  export OPENHAB_BACKUPS=/openhab/userdata/backup && \
  export OPENHAB_RUNTIME=/openhab/runtime && \
  mkdir -p \$OPENHAB_BACKUPS && \
  cd \$OPENHAB_BACKUPS && \
  /openhab/runtime/bin/backup ${BACKUP_NAME}.zip && \
  chown -R openhab:openhab \$OPENHAB_BACKUPS"

# Create temporary directory
TMP_DIR=$(mktemp -d)
echo "Created temporary directory: ${TMP_DIR}"

# Copy the backup from the pod
echo "Copying backup from pod..."
kubectl cp openhab/${OPENHAB_POD}:/openhab/userdata/backup/${BACKUP_NAME}.zip ${TMP_DIR}/${BACKUP_NAME}.zip || {
    echo "Failed to copy backup from pod. Check if backup was created successfully."
    exit 1
}

# Create backup directory on NAS
echo "Creating backup directory on NAS..."
export SSHPASS="${NAS_PASS}"
sshpass -e ssh -o StrictHostKeyChecking=no -p 4711 "${NAS_USER}@${NAS_HOST}" "mkdir -p '${NAS_PATH}'" || {
    echo "Failed to create backup directory on NAS"
    rm -rf "${TMP_DIR}"
    exit 1
}

# Create SSH config to force port 4711
echo "Creating SSH config..."
SSH_CONFIG_DIR="/root/.ssh"
SSH_CONFIG_FILE="${SSH_CONFIG_DIR}/config"
mkdir -p "${SSH_CONFIG_DIR}"
chmod 700 "${SSH_CONFIG_DIR}"
cat > "${SSH_CONFIG_FILE}" << EOF
Host ${NAS_HOST}
    Port 4711
EOF
chmod 600 "${SSH_CONFIG_FILE}"
echo "Debug: SSH config created at ${SSH_CONFIG_FILE}"
ls -la "${SSH_CONFIG_FILE}"
cat "${SSH_CONFIG_FILE}"

# Copy to NAS using sshpass
echo "Copying backup to NAS..."
echo "Debug: Using sshpass version:"
sshpass -V
echo "Debug: Command variables:"
echo "TMP_DIR=${TMP_DIR}"
echo "BACKUP_NAME=${BACKUP_NAME}"
echo "NAS_USER=${NAS_USER}"
echo "NAS_HOST=${NAS_HOST}"
echo "NAS_PATH=${NAS_PATH}"
echo "Debug: Full command:"
echo "sshpass -e scp -rv -O -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -F ${SSH_CONFIG_FILE} \"${TMP_DIR}/${BACKUP_NAME}.zip\" ${NAS_USER}@${NAS_HOST}:${NAS_PATH}"
echo "Debug: Attempting to copy file using scp..."
export SSHPASS="${NAS_PASS}"
sshpass -e scp -rv -O -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -F "${SSH_CONFIG_FILE}" "${TMP_DIR}/${BACKUP_NAME}.zip" ${NAS_USER}@${NAS_HOST}:${NAS_PATH} || {
    echo "Failed to copy backup to NAS"
    echo "Debug: Testing SSH connection..."
    sshpass -e ssh -v -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -p 4711 "${NAS_USER}@${NAS_HOST}" "ls -la \"${NAS_PATH}\""
    rm -rf "${TMP_DIR}"
    exit 1
}

# Clean up temporary directory
echo "Backup completed successfully. Cleaning up..."
rm -rf "${TMP_DIR}"

# Keep only the 5 most recent backups in the pod
echo "Cleaning up old backups..."
kubectl exec -n openhab ${OPENHAB_POD} -- bash -c 'cd /openhab/userdata/backup && ls -t *.zip | tail -n +6 | xargs -r rm --'

# Keep only the 5 most recent backups on NAS
echo "Cleaning up old backups on NAS..."
sshpass -e ssh -o StrictHostKeyChecking=no -p 4711 "${NAS_USER}@${NAS_HOST}" "cd '${NAS_PATH}' && ls -t *.zip | tail -n +6 | xargs -r rm --" || {
    echo "Warning: Failed to clean up old backups on NAS"
    # Don't exit with error as the backup was successful
}

echo "Backup successfully copied to NAS: ${NAS_PATH}/${BACKUP_NAME}.zip"
