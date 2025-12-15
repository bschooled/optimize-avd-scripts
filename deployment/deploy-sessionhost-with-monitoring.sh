#!/bin/bash

# ============================================================================
# Deploy AVD Session Host with Monitoring
# ============================================================================
# This script demonstrates how to deploy an AVD session host and configure
# it with Azure Monitor Agent and Data Collection Rule for AVD Insights.
#
# Prerequisites:
#   - AVD infrastructure deployed (host pool, workspace, monitoring)
#   - Registration token from host pool
#   - Subnet for session hosts
#   - Custom image (optional) or marketplace image
# ============================================================================

set -e

# Configuration
RESOURCE_GROUP="avd-dev-rg"
LOCATION="westus"
HOST_POOL_NAME="avd-dev-hp"
VM_NAME="avd-dev-sh-001"
VM_SIZE="Standard_D4s_v5"
ADMIN_USERNAME="avdadmin"
SUBNET_ID="/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
DATA_COLLECTION_RULE_ID="/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/avd-dev-dcr"

# Optional: Use custom image
# IMAGE_ID="/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>/versions/<version>"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_info "Deploying AVD Session Host with Monitoring"
log_info "============================================"
log_info ""

# Step 1: Get host pool registration token
log_info "Step 1: Obtaining host pool registration token..."
REGISTRATION_TOKEN=$(az desktopvirtualization hostpool show \
    --name "$HOST_POOL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query 'registrationInfo.token' -o tsv)

if [[ -z "$REGISTRATION_TOKEN" ]]; then
    log_info "  No valid token found, generating new one..."
    EXPIRATION=$(date -u -d "+6 hours" '+%Y-%m-%dT%H:%M:%S.000Z')
    
    az desktopvirtualization hostpool update \
        --name "$HOST_POOL_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --registration-info expiration-time="$EXPIRATION" registration-token-operation="Update" \
        --query 'registrationInfo.token' -o tsv > /tmp/token.txt
    
    REGISTRATION_TOKEN=$(cat /tmp/token.txt)
    rm /tmp/token.txt
fi

log_success "Registration token obtained"

# Step 2: Create session host VM
log_info ""
log_info "Step 2: Creating session host VM..."

# Generate admin password
ADMIN_PASSWORD=$(openssl rand -base64 16)

# Create VM with managed identity for monitoring
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --location "$LOCATION" \
    --size "$VM_SIZE" \
    --image "MicrosoftWindowsDesktop:windows-11:win11-25h2-avd:latest" \
    --admin-username "$ADMIN_USERNAME" \
    --admin-password "$ADMIN_PASSWORD" \
    --subnet "$SUBNET_ID" \
    --public-ip-address "" \
    --assign-identity '[system]' \
    --nsg "" \
    --license-type Windows_Client \
    --os-disk-caching ReadWrite \
    --storage-sku StandardSSD_LRS \
    --tags "Environment=dev" "Workload=AVD" "HostPool=$HOST_POOL_NAME"

log_success "VM created: $VM_NAME"

# Step 3: Install AVD Agent
log_info ""
log_info "Step 3: Installing AVD Agent..."

INSTALL_SCRIPT=$(cat << 'PSEOF'
param(
    [string]$RegistrationToken
)

$ErrorActionPreference = 'Stop'

Write-Output "Downloading AVD Agent..."
$agentPath = "C:\Windows\Temp\RDAgent.msi"
Invoke-WebRequest -Uri "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv" -OutFile $agentPath -UseBasicParsing

Write-Output "Downloading AVD Boot Loader..."
$bootloaderPath = "C:\Windows\Temp\RDBootloader.msi"
Invoke-WebRequest -Uri "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH" -OutFile $bootloaderPath -UseBasicParsing

Write-Output "Installing AVD Agent..."
Start-Process msiexec.exe -ArgumentList "/i `"$agentPath`" REGISTRATIONTOKEN=$RegistrationToken /qn /norestart" -Wait -NoNewWindow

Write-Output "Waiting for agent to initialize..."
Start-Sleep -Seconds 10

Write-Output "Installing AVD Boot Loader..."
Start-Process msiexec.exe -ArgumentList "/i `"$bootloaderPath`" /qn /norestart" -Wait -NoNewWindow

Write-Output "AVD Agent installation complete"
PSEOF
)

az vm run-command invoke \
    --name "$VM_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --command-id RunPowerShellScript \
    --scripts "$INSTALL_SCRIPT" \
    --parameters "RegistrationToken=$REGISTRATION_TOKEN" \
    --query 'value[0].message' -o tsv

log_success "AVD Agent installed"

# Step 4: Deploy Azure Monitor Agent and DCR association
log_info ""
log_info "Step 4: Deploying Azure Monitor Agent..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/sessionhost-monitoring.bicep" \
    --parameters \
        vmName="$VM_NAME" \
        location="$LOCATION" \
        dataCollectionRuleId="$DATA_COLLECTION_RULE_ID" \
        enableMonitoring=true \
        tags='{"Environment":"dev","Workload":"AVD"}' \
    --query 'properties.outputs' -o table

log_success "Azure Monitor Agent deployed and DCR associated"

# Step 5: Verify session host registration
log_info ""
log_info "Step 5: Verifying session host registration..."

sleep 15

VM_FQDN=$(az vm show --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" --query "osProfile.computerName" -o tsv)

SESSION_HOST=$(az desktopvirtualization sessionhost list \
    --host-pool-name "$HOST_POOL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?contains(name, '$VM_FQDN')].{name:name,status:status,updateState:updateState}" -o json)

if [[ "$(echo "$SESSION_HOST" | jq '. | length')" -gt 0 ]]; then
    log_success "Session host registered successfully"
    echo "$SESSION_HOST" | jq '.'
else
    log_info "Session host not yet registered (may take a few minutes)"
fi

log_info ""
log_info "============================================"
log_success "Deployment Complete"
log_info "============================================"
log_info "VM Name: $VM_NAME"
log_info "Host Pool: $HOST_POOL_NAME"
log_info "Admin Username: $ADMIN_USERNAME"
log_info "Admin Password: $ADMIN_PASSWORD"
log_info ""
log_info "Monitoring:"
log_info "  - Azure Monitor Agent: Enabled"
log_info "  - Data Collection Rule: Associated"
log_info "  - AVD Insights: Active"
log_info ""
log_info "View monitoring data:"
log_info "  az monitor log-analytics query \\"
log_info "    --workspace <workspace-id> \\"
log_info "    --analytics-query 'Perf | where Computer contains \"$VM_FQDN\" | take 10'"
log_info "============================================"

exit 0
