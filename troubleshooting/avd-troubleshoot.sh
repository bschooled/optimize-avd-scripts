#!/bin/bash

set -e

# ============================================================================
# AVD Session Host Troubleshooting Script
# ============================================================================
# This script helps troubleshoot AVD session hosts by enabling maintenance
# mode (local user login via Bastion) or restoring them back to production.
#
# Usage:
#   ./avd-troubleshoot.sh --vm-name <name> --resource-group <rg> --maintenance
#   ./avd-troubleshoot.sh --vm-name <name> --resource-group <rg> --restore --host-pool <pool> --host-pool-rg <rg>
#
# Maintenance Mode:
#   - Drains the session host (prevents new connections)
#   - Removes host from AVD host pool
#   - Enables local administrator account for Bastion access
#   - Configures RDP for local authentication
#   - Disables FSLogix to prevent profile conflicts
#
# Restore Mode:
#   - Re-runs configure-avd-image.ps1 to set all AVD prerequisites
#   - Re-registers host to AVD host pool with new token
#   - Re-enables FSLogix
#   - Validates session host health
#   - Enables host for new connections
# ============================================================================

# Default values
vm_name=""
resource_group=""
mode=""
host_pool_name=""
host_pool_rg=""
local_admin_user="avdadmin"
local_admin_password=""
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Required Options:
    --vm-name NAME              Name of the VM to troubleshoot
    --resource-group RG         Resource group containing the VM

Mode (one required):
    --maintenance               Put VM in maintenance mode (enable local login)
    --restore                   Restore VM to production AVD host

Restore Mode Options (required with --restore):
    --host-pool NAME            Name of the AVD host pool
    --host-pool-rg RG          Resource group containing the host pool

Optional:
    --local-admin USER          Local admin username (default: avdadmin)
    --local-admin-password PWD  Local admin password (default: auto-generated)
    --help                      Show this help message

Examples:
    # Put host in maintenance mode
    $0 --vm-name avd-host-01 --resource-group avd-rg --maintenance

    # Restore host to production
    $0 --vm-name avd-host-01 --resource-group avd-rg --restore \\
       --host-pool avd-pool-01 --host-pool-rg avd-rg

EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --vm-name)
            vm_name="$2"
            shift 2
            ;;
        --resource-group)
            resource_group="$2"
            shift 2
            ;;
        --maintenance)
            mode="maintenance"
            shift
            ;;
        --restore)
            mode="restore"
            shift
            ;;
        --host-pool)
            host_pool_name="$2"
            shift 2
            ;;
        --host-pool-rg)
            host_pool_rg="$2"
            shift 2
            ;;
        --local-admin)
            local_admin_user="$2"
            shift 2
            ;;
        --local-admin-password)
            local_admin_password="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$vm_name" || -z "$resource_group" || -z "$mode" ]]; then
    log_error "Missing required parameters"
    usage
fi

if [[ "$mode" == "restore" && (-z "$host_pool_name" || -z "$host_pool_rg") ]]; then
    log_error "Restore mode requires --host-pool and --host-pool-rg"
    usage
fi

# Generate random password if not provided
if [[ -z "$local_admin_password" && "$mode" == "maintenance" ]]; then
    local_admin_password=$(openssl rand -base64 16)
fi

log_info "========================================="
log_info "AVD Session Host Troubleshooting"
log_info "========================================="
log_info "VM: $vm_name"
log_info "Resource Group: $resource_group"
log_info "Mode: $mode"
log_info ""

# ============================================================================
# Maintenance Mode
# ============================================================================
if [[ "$mode" == "maintenance" ]]; then
    log_info "Entering MAINTENANCE MODE..."
    log_info ""
    
    # Step 1: Check session host status and remove from pool
    log_info "Step 1: Checking session host status..."
    
    # Get VM's FQDN to find session host
    vm_fqdn=$(az vm show --name "$vm_name" --resource-group "$resource_group" --query "osProfile.computerName" -o tsv 2>/dev/null || echo "")
    
    if [[ -n "$vm_fqdn" ]]; then
        # Find host pool membership
        host_pools=$(az desktopvirtualization hostpool list --query "[].{name:name,rg:resourceGroup}" -o json)
        found_pool=false
        
        while IFS= read -r pool_info; do
            pool_name=$(echo "$pool_info" | jq -r '.name')
            pool_rg=$(echo "$pool_info" | jq -r '.rg')
            
            # Check if VM is in this host pool and get its status
            session_host_info=$(az desktopvirtualization sessionhost show \
                --host-pool-name "$pool_name" \
                --resource-group "$pool_rg" \
                --name "${vm_fqdn}.${pool_name}" \
                --query "{name:name,status:status,allowNewSession:allowNewSession,updateState:updateState}" \
                -o json 2>/dev/null || echo "")
            
            if [[ -n "$session_host_info" && "$session_host_info" != "null" ]]; then
                found_pool=true
                session_host=$(echo "$session_host_info" | jq -r '.name')
                host_status=$(echo "$session_host_info" | jq -r '.status // "Unknown"')
                allow_new=$(echo "$session_host_info" | jq -r '.allowNewSession // false')
                update_state=$(echo "$session_host_info" | jq -r '.updateState // "Unknown"')
                
                log_success "Found session host in pool: $pool_name"
                log_info "  Status: $host_status"
                log_info "  Allow New Sessions: $allow_new"
                log_info "  Update State: $update_state"
                
                # Check if host is healthy enough to drain
                if [[ "$host_status" == "Available" || "$host_status" == "NeedsAssistance" ]]; then
                    if [[ "$allow_new" == "true" ]]; then
                        log_info "  Draining session host (preventing new connections)..."
                        az desktopvirtualization sessionhost update \
                            --host-pool-name "$pool_name" \
                            --resource-group "$pool_rg" \
                            --name "$session_host" \
                            --allow-new-session false 2>/dev/null || log_warn "  Could not drain session host"
                        log_success "  Session host drained"
                    else
                        log_info "  Session host already not accepting new sessions"
                    fi
                else
                    log_warn "  Host is $host_status - skipping drain (may not respond)"
                fi
                
                # Remove from host pool
                log_info "  Removing session host from pool..."
                az desktopvirtualization sessionhost delete \
                    --host-pool-name "$pool_name" \
                    --resource-group "$pool_rg" \
                    --name "$session_host" \
                    --yes 2>/dev/null || log_warn "  Could not remove session host (may already be removed)"
                
                log_success "  Session host removed from pool: $pool_name"
                
                # Store pool info for later restoration
                echo "$pool_name" > "/tmp/${vm_name}_hostpool.txt"
                echo "$pool_rg" > "/tmp/${vm_name}_hostpool_rg.txt"
                
                break
            fi
        done < <(echo "$host_pools" | jq -c '.[]')
        
        if [[ "$found_pool" == "false" ]]; then
            log_warn "VM not found in any host pool - may already be removed"
        fi
    else
        log_warn "Could not determine VM FQDN - skipping host pool removal"
    fi
    
    # Step 2: Enable local administrator account via Run Command
    log_info ""
    log_info "Step 2: Configuring local administrator account..."
    
    maintenance_script=$(cat << 'PSEOF'
# Enable local administrator account for Bastion access
param(
    [string]$LocalAdminUser = "avdadmin",
    [string]$LocalAdminPassword
)

Write-Output "Configuring maintenance mode..."

# Create local admin user if it doesn't exist
$user = Get-LocalUser -Name $LocalAdminUser -ErrorAction SilentlyContinue
if ($null -eq $user) {
    Write-Output "Creating local admin user: $LocalAdminUser"
    $securePassword = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force
    New-LocalUser -Name $LocalAdminUser -Password $securePassword -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop
    Add-LocalGroupMember -Group "Administrators" -Member $LocalAdminUser -ErrorAction Stop
    Write-Output "Local admin user created"
} else {
    Write-Output "Resetting password for existing user: $LocalAdminUser"
    $securePassword = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force
    Set-LocalUser -Name $LocalAdminUser -Password $securePassword -ErrorAction Stop
    Write-Output "Password reset"
}

# Enable local admin account
Enable-LocalUser -Name $LocalAdminUser -ErrorAction SilentlyContinue

# Configure RDP to allow local authentication
Write-Output "Configuring RDP for local authentication..."
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0 -Force

# Disable FSLogix to prevent profile conflicts during maintenance
Write-Output "Disabling FSLogix..."
$fsKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
if (Test-Path $fsKey) {
    Set-ItemProperty -Path $fsKey -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Output "FSLogix disabled"
} else {
    Write-Output "FSLogix not installed"
}

# Stop AVD services to prevent conflicts
Write-Output "Stopping AVD services..."
Stop-Service -Name 'RDAgentBootLoader' -Force -ErrorAction SilentlyContinue
Stop-Service -Name 'RDAgent' -Force -ErrorAction SilentlyContinue

# Set services to manual start
Set-Service -Name 'RDAgentBootLoader' -StartupType Manual -ErrorAction SilentlyContinue
Set-Service -Name 'RDAgent' -StartupType Manual -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "========================================="
Write-Output "Maintenance mode configured successfully"
Write-Output "========================================="
Write-Output "Local Admin User: $LocalAdminUser"
Write-Output "RDP: Configured for local authentication"
Write-Output "FSLogix: Disabled"
Write-Output "AVD Services: Stopped"
Write-Output ""
Write-Output "You can now connect via Azure Bastion using local credentials"
PSEOF
)
    
    # Execute maintenance script
    log_info "  Executing maintenance configuration..."
    az vm run-command invoke \
        --name "$vm_name" \
        --resource-group "$resource_group" \
        --command-id RunPowerShellScript \
        --scripts "$maintenance_script" \
        --parameters "LocalAdminUser=$local_admin_user" "LocalAdminPassword=$local_admin_password" \
        --query 'value[0].message' -o tsv
    
    log_success "Maintenance mode configuration complete"
    
    # Display connection info
    log_info ""
    log_info "========================================="
    log_info "MAINTENANCE MODE ACTIVE"
    log_info "========================================="
    log_info "VM: $vm_name"
    log_info "Local Admin User: $local_admin_user"
    log_info "Local Admin Password: $local_admin_password"
    log_info ""
    log_warn "IMPORTANT: Save the password above - it won't be shown again!"
    log_info ""
    log_info "To connect via Bastion:"
    log_info "  1. Go to Azure Portal"
    log_info "  2. Navigate to the VM: $vm_name"
    log_info "  3. Click 'Connect' > 'Bastion'"
    log_info "  4. Use Authentication Type: 'Password'"
    log_info "  5. Username: $local_admin_user"
    log_info "  6. Password: (shown above)"
    log_info ""
    log_info "When finished troubleshooting, restore with:"
    log_info "  $0 --vm-name $vm_name --resource-group $resource_group --restore \\"
    
    if [[ -f "/tmp/${vm_name}_hostpool.txt" ]]; then
        stored_pool=$(cat "/tmp/${vm_name}_hostpool.txt")
        stored_pool_rg=$(cat "/tmp/${vm_name}_hostpool_rg.txt")
        log_info "    --host-pool $stored_pool --host-pool-rg $stored_pool_rg"
    else
        log_info "    --host-pool <pool-name> --host-pool-rg <pool-rg>"
    fi
    log_info "========================================="

# ============================================================================
# Restore Mode
# ============================================================================
elif [[ "$mode" == "restore" ]]; then
    log_info "Entering RESTORE MODE..."
    log_info ""
    
    # Step 1: Get registration token
    log_info "Step 1: Obtaining AVD host pool registration token..."
    
    # Generate new registration token (valid for 24 hours)
    expiration_time=$(date -u -d "+24 hours" '+%Y-%m-%dT%H:%M:%S.000Z')
    
    log_info "  Generating registration token (expires: $expiration_time)..."
    registration_info=$(az desktopvirtualization hostpool update \
        --name "$host_pool_name" \
        --resource-group "$host_pool_rg" \
        --registration-info expiration-time="$expiration_time" registration-token-operation="Update" \
        --query 'registrationInfo' -o json)
    
    registration_token=$(echo "$registration_info" | jq -r '.token')
    
    if [[ -z "$registration_token" || "$registration_token" == "null" ]]; then
        log_error "Failed to obtain registration token"
        exit 1
    fi
    
    log_success "Registration token obtained"
    
    # Step 2: Get host pool session type (SingleSession or MultiSession)
    log_info ""
    log_info "Step 2: Detecting host pool configuration..."
    
    host_pool_type=$(az desktopvirtualization hostpool show \
        --name "$host_pool_name" \
        --resource-group "$host_pool_rg" \
        --query 'hostPoolType' -o tsv)
    
    log_info "  Host pool type: $host_pool_type"
    
    # Determine session type for configure script
    if [[ "$host_pool_type" == "Pooled" ]]; then
        session_type="MultiSession"
    else
        session_type="SingleSession"
    fi
    
    log_info "  Session type: $session_type"
    
    # Step 3: Upload and execute configure-avd-image.ps1
    log_info ""
    log_info "Step 3: Running AVD configuration script..."
    
    config_script_path="$script_dir/configure-avd-image.ps1"
    
    if [[ ! -f "$config_script_path" ]]; then
        log_error "Configuration script not found: $config_script_path"
        exit 1
    fi
    
    log_info "  Uploading configure-avd-image.ps1..."
    config_script_content=$(cat "$config_script_path")
    
    log_info "  Executing configuration script..."
    config_output=$(az vm run-command invoke \
        --name "$vm_name" \
        --resource-group "$resource_group" \
        --command-id RunPowerShellScript \
        --scripts "$config_script_content" \
        --parameters "SessionType=$session_type" \
        --query 'value[0].message' -o tsv)
    
    echo "$config_output"
    
    # Step 4: Install AVD Agent and Boot Loader with registration token
    log_info ""
    log_info "Step 4: Installing AVD Agent with registration token..."
    
    install_script=$(cat << 'PSEOF'
param(
    [string]$RegistrationToken
)

Write-Output "Installing AVD components..."

# Paths to installers (downloaded by configure-avd-image.ps1)
$agentPath = "C:\Windows\Temp\RDAgent.msi"
$bootloaderPath = "C:\Windows\Temp\RDBootloader.msi"

# Verify files exist
if (-not (Test-Path $agentPath)) {
    Write-Output "ERROR: AVD Agent installer not found at $agentPath"
    exit 1
}

if (-not (Test-Path $bootloaderPath)) {
    Write-Output "ERROR: AVD Bootloader installer not found at $bootloaderPath"
    exit 1
}

# Install AVD Agent with registration token
Write-Output "Installing AVD Agent..."
$agentArgs = "/i `"$agentPath`" REGISTRATIONTOKEN=$RegistrationToken /qn /norestart"
Start-Process msiexec.exe -ArgumentList $agentArgs -Wait -NoNewWindow

# Wait for agent to initialize
Start-Sleep -Seconds 10

# Install Boot Loader
Write-Output "Installing AVD Boot Loader..."
$bootloaderArgs = "/i `"$bootloaderPath`" /qn /norestart"
Start-Process msiexec.exe -ArgumentList $bootloaderArgs -Wait -NoNewWindow

# Wait for services to start
Start-Sleep -Seconds 10

# Verify services are running
$rdAgent = Get-Service -Name 'RDAgent' -ErrorAction SilentlyContinue
$rdBootloader = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue

if ($rdAgent -and $rdAgent.Status -eq 'Running') {
    Write-Output "RDAgent service: Running"
} else {
    Write-Output "WARNING: RDAgent service not running"
}

if ($rdBootloader -and $rdBootloader.Status -eq 'Running') {
    Write-Output "RDAgentBootLoader service: Running"
} else {
    Write-Output "WARNING: RDAgentBootLoader service not running"
}

# Re-enable FSLogix
Write-Output "Re-enabling FSLogix..."
$fsKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
if (Test-Path $fsKey) {
    Set-ItemProperty -Path $fsKey -Name 'Enabled' -Value 1 -Type DWord -Force
    Write-Output "FSLogix re-enabled"
}

Write-Output ""
Write-Output "========================================="
Write-Output "AVD Agent installation complete"
Write-Output "========================================="
PSEOF
)
    
    log_info "  Installing AVD Agent and Boot Loader..."
    install_output=$(az vm run-command invoke \
        --name "$vm_name" \
        --resource-group "$resource_group" \
        --command-id RunPowerShellScript \
        --scripts "$install_script" \
        --parameters "RegistrationToken=$registration_token" \
        --query 'value[0].message' -o tsv)
    
    echo "$install_output"
    
    # Step 5: Verify session host registration
    log_info ""
    log_info "Step 5: Verifying session host registration..."
    
    sleep 15  # Wait for registration to complete
    
    vm_fqdn=$(az vm show --name "$vm_name" --resource-group "$resource_group" --query "osProfile.computerName" -o tsv)
    
    log_info "  Checking for session host: $vm_fqdn"
    
    max_attempts=12
    attempt=0
    session_host_found=false
    
    while [[ $attempt -lt $max_attempts ]]; do
        session_host=$(az desktopvirtualization sessionhost list \
            --host-pool-name "$host_pool_name" \
            --resource-group "$host_pool_rg" \
            --query "[?contains(name, '$vm_fqdn')].{name:name,status:status}" -o json 2>/dev/null || echo "[]")
        
        if [[ "$(echo "$session_host" | jq '. | length')" -gt 0 ]]; then
            session_host_found=true
            session_host_name=$(echo "$session_host" | jq -r '.[0].name')
            session_host_status=$(echo "$session_host" | jq -r '.[0].status')
            
            log_success "Session host registered: $session_host_name"
            log_info "  Status: $session_host_status"
            break
        fi
        
        attempt=$((attempt + 1))
        log_info "  Waiting for registration... (attempt $attempt/$max_attempts)"
        sleep 10
    done
    
    if [[ "$session_host_found" == "false" ]]; then
        log_error "Session host not found after registration"
        log_warn "Check VM logs and AVD Agent installation"
        exit 1
    fi
    
    # Step 6: Enable session host for new connections
    log_info ""
    log_info "Step 6: Enabling session host for new connections..."
    
    az desktopvirtualization sessionhost update \
        --host-pool-name "$host_pool_name" \
        --resource-group "$host_pool_rg" \
        --name "$session_host_name" \
        --allow-new-session true 2>/dev/null || log_warn "Could not enable new sessions"
    
    log_success "Session host enabled"
    
    # Step 7: Clean up stored host pool info
    rm -f "/tmp/${vm_name}_hostpool.txt" "/tmp/${vm_name}_hostpool_rg.txt" 2>/dev/null
    
    # Final summary
    log_info ""
    log_info "========================================="
    log_info "RESTORE COMPLETE"
    log_info "========================================="
    log_success "VM restored to production AVD host"
    log_info "VM: $vm_name"
    log_info "Host Pool: $host_pool_name"
    log_info "Session Type: $session_type"
    log_info "Status: Available for new connections"
    log_info ""
    log_info "Verify health with:"
    log_info "  az desktopvirtualization sessionhost show \\"
    log_info "    --host-pool-name $host_pool_name \\"
    log_info "    --resource-group $host_pool_rg \\"
    log_info "    --name $session_host_name"
    log_info "========================================="
fi

exit 0
