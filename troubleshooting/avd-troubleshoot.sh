#!/bin/bash
set -euo pipefail

# AVD Session Host Troubleshooting
# Maintenance: drain/remove from pool (optional), enable local admin + Bastion access
# Restore: reconfigure AVD prereqs, reinstall agent/bootloader, re-register host

# Defaults
vm_name=""
resource_group=""
mode=""
host_pool_name=""
host_pool_rg=""
local_admin_user="avdadmin"
local_admin_password=""
skip_pool_removal=false
debug=false
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
log_success(){ echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }

usage(){
cat <<'USAGE'
Usage: ./avd-troubleshoot.sh --vm-name <name> --resource-group <rg> (--maintenance | --restore)

Required:
  --vm-name NAME              Target VM name
  --resource-group RG         VM resource group

Modes (choose one):
  --maintenance               Enable local login/Bastion access, pull from pool
  --restore                   Re-register host to pool and re-enable AVD services

Restore requires:
  --host-pool NAME            Host pool name
  --host-pool-rg RG           Host pool resource group

Optional:
  --local-admin USER          Local admin username (default: avdadmin)
  --local-admin-password PWD  Local admin password (default: auto-generated)
  --skip-pool-removal         Skip host pool removal in maintenance
  --host-pool NAME            (Maintenance) Known host pool to skip discovery
  --host-pool-rg RG           (Maintenance) Known host pool RG to skip discovery
  --debug                     Enable bash tracing
  --help                      Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-name) vm_name="$2"; shift 2;;
    --resource-group) resource_group="$2"; shift 2;;
    --maintenance) mode="maintenance"; shift;;
    --restore) mode="restore"; shift;;
    --host-pool) host_pool_name="$2"; shift 2;;
    --host-pool-rg) host_pool_rg="$2"; shift 2;;
    --local-admin) local_admin_user="$2"; shift 2;;
    --local-admin-password) local_admin_password="$2"; shift 2;;
    --skip-pool-removal) skip_pool_removal=true; shift;;
    --debug) debug=true; shift;;
    --help) usage; exit 0;;
    *) log_error "Unknown option: $1"; usage; exit 1;;
  esac
done

[[ -z "$vm_name" || -z "$resource_group" || -z "$mode" ]] && { log_error "Missing required parameters"; usage; }
if [[ "$mode" == "restore" && ( -z "$host_pool_name" || -z "$host_pool_rg" ) ]]; then
  log_error "Restore mode requires --host-pool and --host-pool-rg"; usage;
fi
[[ "$debug" == "true" ]] && set -x

if [[ -z "$local_admin_password" && "$mode" == "maintenance" ]]; then
  local_admin_password=$(openssl rand -base64 16)
fi

ensure_desktopvirtualization_extension(){
  if ! az extension show --name desktopvirtualization >/dev/null 2>&1; then
    log_warn "Az extension 'desktopvirtualization' not found; installing..."
    az extension add --name desktopvirtualization >/dev/null 2>&1 || {
      log_error "Failed to install az desktopvirtualization extension"; exit 1;
    }
    log_success "Az extension 'desktopvirtualization' installed"
  fi
}

get_subscription_id(){
  az account show --query id -o tsv 2>/dev/null
}

find_and_remove_host(){
  if [[ "$skip_pool_removal" == "true" ]]; then
    log_warn "Skipping host pool removal (--skip-pool-removal)"; return 0; fi

  log_info "Step 1: Checking session host status..."
  log_info "  Getting VM FQDN..."
  vm_fqdn=$(timeout 10 az vm show --name "$vm_name" --resource-group "$resource_group" --query "osProfile.computerName" -o tsv 2>/dev/null || echo "")
  if [[ -z "$vm_fqdn" ]]; then
    log_warn "  Could not determine VM FQDN - skipping host pool removal"; return 0; fi
  log_info "  VM FQDN: $vm_fqdn"

  if [[ -n "$host_pool_name" && -n "$host_pool_rg" ]]; then
    log_info "  Using provided host pool: $host_pool_name ($host_pool_rg)"
    host_pools=$(printf '[{"name":"%s","rg":"%s"}]' "$host_pool_name" "$host_pool_rg")
  else
    log_info "  Searching for host pool membership (may take a moment)..."
    host_pools=$(timeout 30 az desktopvirtualization hostpool list --query "[].{name:name,rg:resourceGroup}" -o json 2>&1)
    host_pools_status=$?
    log_info "  hostpool list exit code: $host_pools_status"
    log_info "  hostpool list raw output: $host_pools"
  fi

  if [[ -z "$host_pools" ]] || ! echo "$host_pools" | jq empty 2>/dev/null; then
    log_warn "  Could not list host pools (timeout/error/invalid response). Skipping removal."; return 0; fi

  pool_count=$(echo "$host_pools" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$pool_count" == "0" ]]; then
    log_warn "  No host pools found. Skipping removal."; return 0; fi
  log_info "  Found $pool_count host pools to check"

  found_pool=false
  pool_index=0
  while IFS= read -r pool_info; do
    pool_index=$((pool_index+1))
    pool_name=$(echo "$pool_info" | jq -r '.name' 2>/dev/null || echo "")
    pool_rg=$(echo "$pool_info" | jq -r '.rg' 2>/dev/null || echo "")
    if [[ -z "$pool_name" || -z "$pool_rg" ]]; then log_warn "  Skipping invalid pool entry"; continue; fi
    log_info "  Checking pool $pool_index/$pool_count: $pool_name"

    session_host_names=("${vm_fqdn}" "${vm_fqdn}.${pool_name}" "${vm_name}.${pool_name}")
    for sh_name in "${session_host_names[@]}"; do
      log_info "    Trying: $sh_name"
      subscription_id=$(get_subscription_id)
      session_host_url="/subscriptions/${subscription_id}/resourceGroups/${pool_rg}/providers/Microsoft.DesktopVirtualization/hostPools/${pool_name}/sessionHosts/${sh_name}?api-version=2023-09-05"
      session_host_info=$(timeout 10 az rest --method get --url "$session_host_url" 2>&1)
      sh_status=$?
      log_info "    sessionhost show exit code: $sh_status"
      log_info "    sessionhost show raw output: $session_host_info"
      if [[ -z "$session_host_info" ]] || ! echo "$session_host_info" | jq empty 2>/dev/null; then continue; fi

      found_pool=true
      session_host=$(echo "$session_host_info" | jq -r '.name' 2>/dev/null || echo "")
      host_status=$(echo "$session_host_info" | jq -r '.properties.status // "Unknown"' 2>/dev/null || echo "Unknown")
      allow_new=$(echo "$session_host_info" | jq -r '.properties.allowNewSession // false' 2>/dev/null || echo "false")
      update_state=$(echo "$session_host_info" | jq -r '.properties.updateState // "Unknown"' 2>/dev/null || echo "Unknown")

      log_success "Found session host in pool: $pool_name"
      log_info "  Session Host Name: $session_host"
      log_info "  Status: $host_status"
      log_info "  Allow New Sessions: $allow_new"
      log_info "  Update State: $update_state"

      if [[ "$host_status" == "Available" || "$host_status" == "NeedsAssistance" ]]; then
        if [[ "$allow_new" == "true" ]]; then
          log_info "  Draining session host (preventing new connections)..."
          drain_body='{"properties":{"allowNewSession":false}}'
          drain_out=$(timeout 15 az rest --method patch --url "$session_host_url" --body "$drain_body" 2>&1)
          drain_status=$?
          log_info "  drain exit code: $drain_status"
          log_info "  drain raw output: $drain_out"
          [[ $drain_status -ne 0 ]] && log_warn "  Could not drain session host" || log_success "  Session host drained"
        else
          log_info "  Session host already not accepting new sessions"
        fi
      else
        log_warn "  Host is $host_status - skipping drain (may not respond)"
      fi

      log_info "  Removing session host from pool..."
      del_out=$(timeout 15 az rest --method delete --url "$session_host_url" 2>&1)
      del_status=$?
      log_info "  delete exit code: $del_status"
      log_info "  delete raw output: $del_out"
      [[ $del_status -ne 0 ]] && log_warn "  Could not remove session host (may already be removed)" || log_success "  Session host removed from pool: $pool_name"

      echo "$pool_name" > "/tmp/${vm_name}_hostpool.txt"
      echo "$pool_rg" > "/tmp/${vm_name}_hostpool_rg.txt"
      return 0
    done
  done < <(echo "$host_pools" | jq -c '.[]' 2>/dev/null || echo "")

  if [[ "$found_pool" == "false" ]]; then
    log_warn "VM not found in any host pool - may already be removed or never registered"
  fi
}

if [[ "$mode" == "maintenance" ]]; then
  log_info "Entering MAINTENANCE MODE..."
  ensure_desktopvirtualization_extension
  find_and_remove_host

  log_info ""
  log_info "Step 2: Configuring local administrator account..."

  maintenance_script=$(cat << 'MAINT_PS'
param(
    [string]$LocalAdminUser = "avdadmin",
    [string]$LocalAdminPassword
)

Write-Output "Configuring maintenance mode..."

$sec = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force
$user = Get-LocalUser -Name $LocalAdminUser -ErrorAction SilentlyContinue
if ($null -eq $user) {
    Write-Output "Creating local admin user: $LocalAdminUser"
    New-LocalUser -Name $LocalAdminUser -Password $sec -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop
    Add-LocalGroupMember -Group "Administrators" -Member $LocalAdminUser -ErrorAction Stop
} else {
    Write-Output "Resetting password for existing user: $LocalAdminUser"
    Set-LocalUser -Name $LocalAdminUser -Password $sec -ErrorAction Stop
}
Enable-LocalUser -Name $LocalAdminUser -ErrorAction SilentlyContinue

Write-Output "Configuring RDP for local authentication..."
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0 -Force

Write-Output "Ensuring local logon is allowed..."
secedit /export /cfg C:\Windows\Temp\secpol.cfg | Out-Null
(Get-Content C:\Windows\Temp\secpol.cfg) -replace 'SeDenyInteractiveLogonRight = (.*)', 'SeDenyInteractiveLogonRight =' | Set-Content C:\Windows\Temp\secpol.cfg
secedit /configure /db C:\Windows\security\local.sdb /cfg C:\Windows\Temp\secpol.cfg /areas USER_RIGHTS | Out-Null

Write-Output "Enabling Windows Firewall Remote Desktop rules..."
Get-NetFirewallRule -DisplayGroup "Remote Desktop" | Enable-NetFirewallRule | Out-Null

Write-Output "Restarting Remote Desktop Services..."
Restart-Service -Name TermService -Force -ErrorAction SilentlyContinue

Write-Output "Disabling FSLogix (maintenance)..."
$fsKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
if (Test-Path $fsKey) {
    Set-ItemProperty -Path $fsKey -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

Write-Output "Stopping AVD services..."
'RDAgentBootLoader','RDAgent' | ForEach-Object {
    Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
    Set-Service -Name $_ -StartupType Manual -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output "========================================="
Write-Output "Maintenance mode configured successfully"
Write-Output "========================================="
Write-Output "Local Admin User: $($LocalAdminUser)"
Write-Output "RDP: Enabled; NLA disabled"
Write-Output "FSLogix: Disabled"
Write-Output "AVD Services: Stopped"
Write-Output ""
Write-Output "You can now connect via Azure Bastion using local credentials"
MAINT_PS
  )

  log_info "  Executing maintenance configuration..."
  az vm run-command invoke \
    --name "$vm_name" \
    --resource-group "$resource_group" \
    --command-id RunPowerShellScript \
    --scripts "$maintenance_script" \
    --parameters "LocalAdminUser=$local_admin_user" "LocalAdminPassword=$local_admin_password" \
    --query 'value[0].message' -o tsv

  log_success "Maintenance mode configuration complete"
  log_info ""
  log_info "========================================="
  log_info "MAINTENANCE MODE ACTIVE"
  log_info "========================================="
  log_info "VM: $vm_name"
  log_info "Local Admin User: $local_admin_user"
  log_info "Local Admin Password: $local_admin_password"
  log_warn "IMPORTANT: Save the password above - it won't be shown again!"
  log_info ""
  log_info "To connect via Bastion: Portal > VM > Connect > Bastion > RDP > username/password above"
  log_info "When finished, restore with:"
  if [[ -f "/tmp/${vm_name}_hostpool.txt" ]]; then
    stored_pool=$(cat "/tmp/${vm_name}_hostpool.txt"); stored_pool_rg=$(cat "/tmp/${vm_name}_hostpool_rg.txt")
    log_info "  $0 --vm-name $vm_name --resource-group $resource_group --restore --host-pool $stored_pool --host-pool-rg $stored_pool_rg"
  else
    log_info "  $0 --vm-name $vm_name --resource-group $resource_group --restore --host-pool <pool> --host-pool-rg <rg>"
  fi

elif [[ "$mode" == "restore" ]]; then
  log_info "Entering RESTORE MODE..."
  ensure_desktopvirtualization_extension

  log_info "Step 1: Obtaining AVD host pool registration token..."
  expiration_time=$(date -u -d "+24 hours" '+%Y-%m-%dT%H:%M:%S.000Z')
  registration_info=$(az desktopvirtualization hostpool update \
      --name "$host_pool_name" \
      --resource-group "$host_pool_rg" \
      --registration-info expiration-time="$expiration_time" registration-token-operation="Update" \
      --query 'registrationInfo' -o json)
  registration_token=$(echo "$registration_info" | jq -r '.token')
  if [[ -z "$registration_token" || "$registration_token" == "null" ]]; then log_error "Failed to obtain registration token"; exit 1; fi
  log_success "Registration token obtained"

  log_info "Step 2: Detecting host pool configuration..."
  host_pool_type=$(az desktopvirtualization hostpool show --name "$host_pool_name" --resource-group "$host_pool_rg" --query 'hostPoolType' -o tsv)
  session_type="SingleSession"; [[ "$host_pool_type" == "Pooled" ]] && session_type="MultiSession"
  log_info "  Session type: $session_type"

  log_info "Step 3: Running AVD configuration script..."
  config_script_path="$script_dir/configure-avd-image.ps1"
  [[ ! -f "$config_script_path" ]] && { log_error "Configuration script not found: $config_script_path"; exit 1; }
  config_script_content=$(cat "$config_script_path")
  az vm run-command invoke \
    --name "$vm_name" --resource-group "$resource_group" \
    --command-id RunPowerShellScript \
    --scripts "$config_script_content" \
    --parameters "SessionType=$session_type" \
    --query 'value[0].message' -o tsv

  log_info "Step 4: Installing AVD Agent with registration token..."
  install_script=$(cat << 'INSTALL_PS'
param(
    [string]$RegistrationToken
)
Write-Output "Installing AVD components..."
$agentPath = "C:\Windows\Temp\RDAgent.msi"
$bootloaderPath = "C:\Windows\Temp\RDBootloader.msi"
if (-not (Test-Path $agentPath)) { Write-Output "ERROR: $agentPath missing"; exit 1 }
if (-not (Test-Path $bootloaderPath)) { Write-Output "ERROR: $bootloaderPath missing"; exit 1 }
$agentArgs = "/i `"$agentPath`" REGISTRATIONTOKEN=$RegistrationToken /qn /norestart"
Start-Process msiexec.exe -ArgumentList $agentArgs -Wait -NoNewWindow
Start-Sleep -Seconds 10
$bootloaderArgs = "/i `"$bootloaderPath`" /qn /norestart"
Start-Process msiexec.exe -ArgumentList $bootloaderArgs -Wait -NoNewWindow
Start-Sleep -Seconds 10
$rdAgent = Get-Service -Name 'RDAgent' -ErrorAction SilentlyContinue
$rdBootloader = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue
if ($rdAgent -and $rdAgent.Status -eq 'Running') { Write-Output "RDAgent service: Running" } else { Write-Output "WARNING: RDAgent not running" }
if ($rdBootloader -and $rdBootloader.Status -eq 'Running') { Write-Output "RDAgentBootLoader service: Running" } else { Write-Output "WARNING: RDAgentBootLoader not running" }
Write-Output "Re-enabling FSLogix..."
$fsKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
if (Test-Path $fsKey) { Set-ItemProperty -Path $fsKey -Name 'Enabled' -Value 1 -Type DWord -Force }
Write-Output "AVD Agent installation complete"
INSTALL_PS
  )

  az vm run-command invoke \
    --name "$vm_name" --resource-group "$resource_group" \
    --command-id RunPowerShellScript \
    --scripts "$install_script" \
    --parameters "RegistrationToken=$registration_token" \
    --query 'value[0].message' -o tsv

  log_info "Step 5: Verifying session host registration..."
  sleep 15
  vm_fqdn=$(az vm show --name "$vm_name" --resource-group "$resource_group" --query "osProfile.computerName" -o tsv)
  subscription_id=$(get_subscription_id)
  max_attempts=12; attempt=0; session_host_found=false
  while [[ $attempt -lt $max_attempts ]]; do
    list_url="/subscriptions/${subscription_id}/resourceGroups/${host_pool_rg}/providers/Microsoft.DesktopVirtualization/hostPools/${host_pool_name}/sessionHosts?api-version=2023-09-05"
    session_host=$(az rest --method get --url "$list_url" --query "value[?contains(name, '$vm_fqdn')].{name:name,status:properties.status}" -o json 2>/dev/null || echo "[]")
    if [[ "$(echo "$session_host" | jq '. | length')" -gt 0 ]]; then
      session_host_found=true
      session_host_name=$(echo "$session_host" | jq -r '.[0].name')
      session_host_status=$(echo "$session_host" | jq -r '.[0].status')
      log_success "Session host registered: $session_host_name"
      log_info "  Status: $session_host_status"
      break
    fi
    attempt=$((attempt+1))
    log_info "  Waiting for registration... (attempt $attempt/$max_attempts)"
    sleep 10
  done
  if [[ "$session_host_found" == "false" ]]; then log_error "Session host not found after registration"; exit 1; fi

  log_info "Step 6: Enabling session host for new connections..."
  enable_url="/subscriptions/${subscription_id}/resourceGroups/${host_pool_rg}/providers/Microsoft.DesktopVirtualization/hostPools/${host_pool_name}/sessionHosts/${session_host_name}?api-version=2023-09-05"
  enable_body='{"properties":{"allowNewSession":true}}'
  az rest --method patch --url "$enable_url" --body "$enable_body" 2>/dev/null || log_warn "Could not enable new sessions"

  rm -f "/tmp/${vm_name}_hostpool.txt" "/tmp/${vm_name}_hostpool_rg.txt" 2>/dev/null
  log_info ""
  log_info "========================================="
  log_info "RESTORE COMPLETE"
  log_info "========================================="
  log_info "Host: $vm_name"
  log_info "Pool: $host_pool_name ($host_pool_rg)"
else
  log_error "Unknown mode: $mode"
  usage
  exit 1
fi
