#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: avd-build-pipeline-compact.sh \
	--image-name <runOutput base name> \
	--gallery <shared image gallery name> \
	[--resource-group <rg>] [--location <azure region>] \
	[--script <path to PowerShell customization>] \
	[--image-definition <sig image definition name>] \
	[--image-version <sig image version>] \
	[--vm-size <builder VM size>] \
	[--disk-size <target OS disk size in GB>]

Creates and runs an Azure Image Builder template that takes the Windows 11 25H2
Enterprise marketplace image, runs the provided PowerShell compact script, and
publishes the result into the specified Shared Image Gallery. If no
--image-version is provided, the script auto-increments the latest version in
the target Shared Image Gallery (e.g., v1.0 -> v1.1).

Disk Size Options (for ephemeral OS VMs):
  --disk-size 64   : For D2d_v5 VMs (70 GB temp storage)
  --disk-size 127  : For D4d_v5 VMs (150 GB temp storage)
  --disk-size 254  : For D8d_v5 VMs (300 GB temp storage)

When --disk-size is specified, the image definition name will have a size suffix
(e.g., win11-25h2-ent-compact-64gb) and the OS disk will be shrunk to fit.
EOF
}

ensure_arg() {
	local name="$1" value="$2"
	if [[ -z "${value}" ]]; then
		echo "Missing required argument: ${name}" >&2
		usage
		exit 1
	fi
}

image_name="win11-25h2-ent-compact"
gallery_name=""
resource_group="avd-image-builder-rg"
location=""
script_path="$(dirname "${BASH_SOURCE[0]}")/scripts/compact-avd.ps1"
image_definition="win11-25h2-ent-compact"
image_version="1.0.0"
vm_size="Standard_D4s_v5"
staging_resource_group=""
disk_size_gb=""  # Target disk size for ephemeral OS VMs

while [[ $# -gt 0 ]]; do
	case "$1" in
		--image-name) image_name="$2"; shift 2;;
		--gallery) gallery_name="$2"; shift 2;;
		--resource-group) resource_group="$2"; shift 2;;
		--location) location="$2"; shift 2;;
		--script) script_path="$2"; shift 2;;
		--image-definition) image_definition="$2"; shift 2;;
		--image-version) image_version="$2"; shift 2;;
		--vm-size) vm_size="$2"; shift 2;;
		--staging-rg) staging_resource_group="$2"; shift 2;;
		--disk-size) disk_size_gb="$2"; shift 2;;
		-h|--help) usage; exit 0;;
		*) echo "Unknown argument: $1" >&2; usage; exit 1;;
	esac
done

ensure_arg "--image-name" "$image_name"
ensure_arg "--gallery" "$gallery_name"

if [[ ! -f "$script_path" ]]; then
	echo "Customization script not found at: $script_path" >&2
	exit 1
fi

subscription_id=$(az account show --query id -o tsv)
tenant_id=$(az account show --query tenantId -o tsv)
identity_name="aib-${gallery_name}-uami"
template_base_name="aib-${image_name}-template"

# Create a unique staging resource group for this build
# Each image template requires its own staging RG
timestamp=$(date +%s)
if [[ -z "$staging_resource_group" ]]; then
	staging_resource_group="${resource_group}-staging-${timestamp}"
else
	# If user provided a staging RG, make it unique with timestamp
	staging_resource_group="${staging_resource_group}-${timestamp}"
fi

# If disk size is specified, append it to image definition name
if [[ -n "$disk_size_gb" ]]; then
	image_definition="${image_definition}-${disk_size_gb}gb"
	echo "Target disk size: ${disk_size_gb} GB - Image definition: ${image_definition}"
fi

echo "Using subscription: ${subscription_id}"
echo ""
echo "========================================================================"
echo "Checking existing resources (parallel)..."
echo "========================================================================"

# Run all checks in parallel for speed
(
	# Check if gallery exists anywhere in subscription
	existing_gallery=$(az sig list --query "[?name=='${gallery_name}'].{rg:resourceGroup,location:location}" -o tsv)
	echo "GALLERY:${existing_gallery}" > /tmp/aib-check-gallery.$$
) &

(
	# Check if resource group exists
	if az group show --name "$resource_group" >/dev/null 2>&1; then
		echo "RG_EXISTS:true" > /tmp/aib-check-rg.$$
	else
		echo "RG_EXISTS:false" > /tmp/aib-check-rg.$$
	fi
) &

(
	# Check if staging RG already exists
	if az group show --name "$staging_resource_group" >/dev/null 2>&1; then
		echo "STAGING_EXISTS:true" > /tmp/aib-check-staging.$$
	else
		echo "STAGING_EXISTS:false" > /tmp/aib-check-staging.$$
	fi
) &

(
	# List old staging RGs to clean up
	old_staging_rgs=$(az group list --query "[?tags.Purpose=='AIB staging resources' && starts_with(name, '${resource_group}-staging-')].name" -o tsv)
	echo "OLD_STAGING:${old_staging_rgs}" > /tmp/aib-check-old-staging.$$
) &

(
	# Check if gallery exists in target RG
	if az sig show --resource-group "$resource_group" --gallery-name "$gallery_name" >/dev/null 2>&1; then
		echo "GALLERY_IN_RG:true" > /tmp/aib-check-gallery-rg.$$
	else
		echo "GALLERY_IN_RG:false" > /tmp/aib-check-gallery-rg.$$
	fi
) &

(
	# Determine SKU - must be unique for publisher/offer combination
	if [[ -n "$disk_size_gb" ]]; then
		image_sku="win11-25h2-ent-${disk_size_gb}gb"
	else
		image_sku="win11-25h2-ent"
	fi
	
	# Check if image definition exists
	if az sig image-definition show --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" >/dev/null 2>&1; then
		# Get existing versions
		existing_versions=$(az sig image-version list \
			--resource-group "$resource_group" \
			--gallery-name "$gallery_name" \
			--gallery-image-definition "$image_definition" \
			--query "[].name" -o tsv 2>/dev/null || true)
		echo "IMAGE_DEF_EXISTS:true" > /tmp/aib-check-imagedef.$$
		echo "IMAGE_VERSIONS:${existing_versions}" > /tmp/aib-check-versions.$$
	else
		echo "IMAGE_DEF_EXISTS:false" > /tmp/aib-check-imagedef.$$
		echo "IMAGE_VERSIONS:" > /tmp/aib-check-versions.$$
	fi
	echo "IMAGE_SKU:${image_sku}" > /tmp/aib-check-sku.$$
) &

# Wait for all checks to complete
wait

echo "Resource checks complete. Processing results..."
echo ""

# Read all check results
gallery_info=$(cat /tmp/aib-check-gallery.$$ 2>/dev/null | cut -d: -f2-)
rg_exists=$(cat /tmp/aib-check-rg.$$ 2>/dev/null | cut -d: -f2)
staging_exists=$(cat /tmp/aib-check-staging.$$ 2>/dev/null | cut -d: -f2)
old_staging=$(cat /tmp/aib-check-old-staging.$$ 2>/dev/null | cut -d: -f2-)
gallery_in_rg=$(cat /tmp/aib-check-gallery-rg.$$ 2>/dev/null | cut -d: -f2)
image_def_exists=$(cat /tmp/aib-check-imagedef.$$ 2>/dev/null | cut -d: -f2)
image_versions=$(cat /tmp/aib-check-versions.$$ 2>/dev/null | cut -d: -f2-)
image_sku=$(cat /tmp/aib-check-sku.$$ 2>/dev/null | cut -d: -f2)

# Clean up temp files
rm -f /tmp/aib-check-*.$$

# If gallery exists elsewhere, reuse it
if [[ -n "$gallery_info" ]]; then
	read -r existing_gallery_rg existing_gallery_location <<<"$gallery_info"
	if [[ -n "$existing_gallery_rg" ]]; then
		echo "Found existing gallery ${gallery_name} in resource group ${existing_gallery_rg}; reusing it"
		resource_group="$existing_gallery_rg"
		location="$existing_gallery_location"
		# Need to re-check RG existence for the gallery's RG
		if az group show --name "$resource_group" >/dev/null 2>&1; then
			rg_exists="true"
		fi
	fi
fi

# Build list of operations to perform
echo "Preparing resource operations..."
operations=()

# Resource group operations
if [[ "$rg_exists" == "false" ]]; then
	operations+=("CREATE_RG")
	echo "  - Will create resource group: ${resource_group}"
else
	operations+=("UPDATE_RG_TAGS")
	echo "  - Resource group exists: ${resource_group}"
fi

# Clean up old staging RGs
if [[ -n "$old_staging" ]]; then
	current_time=$(date +%s)
	while IFS= read -r rg_name; do
		if [[ -n "$rg_name" ]]; then
			rg_timestamp=$(echo "$rg_name" | grep -oP '\d+$')
			if [[ -n "$rg_timestamp" ]]; then
				age=$((current_time - rg_timestamp))
				if [[ $age -gt 86400 ]]; then
					operations+=("DELETE_OLD_STAGING:$rg_name")
					echo "  - Will delete old staging RG: $rg_name (age: $((age / 3600)) hours)"
				fi
			fi
		fi
	done <<< "$old_staging"
fi

# Staging RG
operations+=("CREATE_STAGING")
echo "  - Will create staging resource group: ${staging_resource_group}"

# Gallery operations
if [[ "$gallery_in_rg" == "false" ]]; then
	operations+=("CREATE_GALLERY")
	echo "  - Will create gallery: ${gallery_name}"
else
	operations+=("UPDATE_GALLERY_TAGS")
	echo "  - Gallery exists: ${gallery_name}"
fi

# Image definition operations
if [[ "$image_def_exists" == "true" ]]; then
	operations+=("DELETE_IMAGE_VERSIONS")
	operations+=("DELETE_IMAGE_DEF")
	operations+=("CREATE_IMAGE_DEF")
	echo "  - Will recreate image definition: ${image_definition}"
else
	operations+=("CREATE_IMAGE_DEF")
	echo "  - Will create image definition: ${image_definition}"
fi

echo ""
echo "Executing resource operations..."
echo ""

# Execute operations in correct order
for op in "${operations[@]}"; do
	case "$op" in
		CREATE_RG)
			echo "Creating resource group ${resource_group}..."
			az group create --name "$resource_group" --location "$location" --tags SecurityControl=Ignore >/dev/null
			;;
		UPDATE_RG_TAGS)
			az group update --name "$resource_group" --set tags.SecurityControl=Ignore >/dev/null 2>&1 || true
			;;
		DELETE_OLD_STAGING:*)
			rg_name="${op#DELETE_OLD_STAGING:}"
			echo "Deleting old staging RG: ${rg_name}..."
			az group delete --name "$rg_name" --yes --no-wait 2>/dev/null || true
			;;
		CREATE_STAGING)
			echo "Creating staging resource group ${staging_resource_group}..."
			az group create --name "$staging_resource_group" --location "$location" --tags SecurityControl=Ignore Purpose="AIB staging resources" >/dev/null
			;;
		CREATE_GALLERY)
			echo "Creating shared image gallery ${gallery_name}..."
			az sig create --resource-group "$resource_group" --gallery-name "$gallery_name" --location "$location" --tags SecurityControl=Ignore >/dev/null
			;;
		UPDATE_GALLERY_TAGS)
			az sig update --resource-group "$resource_group" --gallery-name "$gallery_name" --set tags.SecurityControl=Ignore >/dev/null 2>&1 || true
			;;
		DELETE_IMAGE_VERSIONS)
			if [[ -n "$image_versions" ]]; then
				echo "Deleting existing image versions..."
				while IFS= read -r version; do
					if [[ -n "$version" ]]; then
						echo "  Deleting version ${version}..."
						az sig image-version delete \
							--resource-group "$resource_group" \
							--gallery-name "$gallery_name" \
							--gallery-image-definition "$image_definition" \
							--gallery-image-version "$version" >/dev/null 2>&1 || true
					fi
				done <<< "$image_versions"
				echo "  Waiting for version deletions to complete..."
				sleep 5
			fi
			;;
		DELETE_IMAGE_DEF)
			echo "Deleting existing image definition ${image_definition}..."
			az sig image-definition delete \
				--resource-group "$resource_group" \
				--gallery-name "$gallery_name" \
				--gallery-image-definition "$image_definition" >/dev/null 2>&1 || true
			echo "  Waiting for image definition deletion to complete..."
			for i in {1..30}; do
				if ! az sig image-definition show --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" >/dev/null 2>&1; then
					break
				fi
				sleep 2
			done
			sleep 3
			;;
		CREATE_IMAGE_DEF)
			echo "Creating image definition ${image_definition} with SKU ${image_sku}..."
			az sig image-definition create \
				--resource-group "$resource_group" \
				--gallery-name "$gallery_name" \
				--gallery-image-definition "$image_definition" \
				--publisher "MicrosoftWindowsDesktop" \
				--offer "windows-11" \
				--sku "$image_sku" \
				--os-type Windows \
				--hyper-v-generation V2 \
				--os-state Generalized \
				--tags SecurityControl=Ignore >/dev/null
			;;
	esac
done

echo ""
echo "Resource provisioning complete."
echo ""

echo "Ensuring user-assigned managed identity ${identity_name}"
identity_id=$(az identity show --name "$identity_name" --resource-group "$resource_group" --query id -o tsv 2>/dev/null || true)
if [[ -z "$identity_id" ]]; then
	identity_id=$(az identity create --name "$identity_name" --resource-group "$resource_group" --location "$location" --tags SecurityControl=Ignore --query id -o tsv)
else
	echo "User-assigned identity ${identity_name} already exists"
	az resource update --ids "$identity_id" --set tags.SecurityControl=Ignore >/dev/null
fi
identity_principal=$(az identity show --ids "$identity_id" --query principalId -o tsv)

echo "Granting Contributor on gallery and resource groups to the identity"
if [[ $(az role assignment list --assignee "$identity_principal" --scope "/subscriptions/${subscription_id}/resourceGroups/${resource_group}" --role Contributor --query "length(@)" -o tsv) == "0" ]]; then
	az role assignment create --assignee "$identity_principal" --role Contributor --scope "/subscriptions/${subscription_id}/resourceGroups/${resource_group}" >/dev/null
else
	echo "Contributor role on resource group already assigned"
fi
if [[ $(az role assignment list --assignee "$identity_principal" --scope "/subscriptions/${subscription_id}/resourceGroups/${staging_resource_group}" --role Contributor --query "length(@)" -o tsv) == "0" ]]; then
	az role assignment create --assignee "$identity_principal" --role Contributor --scope "/subscriptions/${subscription_id}/resourceGroups/${staging_resource_group}" >/dev/null
else
	echo "Contributor role on staging resource group already assigned"
fi
if [[ $(az role assignment list --assignee "$identity_principal" --scope "/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Compute/galleries/${gallery_name}" --role Contributor --query "length(@)" -o tsv) == "0" ]]; then
	az role assignment create --assignee "$identity_principal" --role Contributor --scope "/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Compute/galleries/${gallery_name}" >/dev/null
else
	echo "Contributor role on gallery already assigned"
fi

# Inline the PowerShell customizers to avoid storage/SAS entirely
script_b64=$(base64 -w0 "$script_path")

# AVD configuration script (always in scripts/ folder alongside compact-avd.ps1)
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
avd_config_path="$SCRIPT_DIR/scripts/configure-avd-image.ps1"
avd_config_b64=""
if [[ -f "$avd_config_path" ]]; then
	avd_config_b64=$(base64 -w0 "$avd_config_path")
fi

# Disk shrinking script
shrink_script_path="$SCRIPT_DIR/scripts/shrink-os-disk.ps1"
shrink_script_b64=""
if [[ -n "$disk_size_gb" && -f "$shrink_script_path" ]]; then
	shrink_script_b64=$(base64 -w0 "$shrink_script_path")
fi

inline_commands=$(SCRIPT_B64="$script_b64" AVD_CONFIG_B64="$avd_config_b64" SHRINK_SCRIPT_B64="$shrink_script_b64" DISK_SIZE_GB="$disk_size_gb" python3 - <<'PY'
import json, os
script_b64 = os.environ["SCRIPT_B64"]
avd_config_b64 = os.environ["AVD_CONFIG_B64"]
shrink_script_b64 = os.environ["SHRINK_SCRIPT_B64"]
disk_size_gb = os.environ["DISK_SIZE_GB"]

commands = [
	r"New-Item -ItemType Directory -Force -Path C:\\Deployer | Out-Null",
	r"[IO.File]::WriteAllBytes('C:\\Deployer\\compact-avd.ps1',[Convert]::FromBase64String('" + script_b64 + r"'))",
	r"powershell -ExecutionPolicy Bypass -File C:\\Deployer\\compact-avd.ps1"
]

# Add AVD configuration if script exists
if avd_config_b64:
	commands.extend([
		r"[IO.File]::WriteAllBytes('C:\\Deployer\\configure-avd-image.ps1',[Convert]::FromBase64String('" + avd_config_b64 + r"'))",
		r"powershell -ExecutionPolicy Bypass -File C:\\Deployer\\configure-avd-image.ps1"
	])

# Add disk shrinking if size specified
if disk_size_gb and shrink_script_b64:
	commands.extend([
		r"[IO.File]::WriteAllBytes('C:\\Deployer\\shrink-os-disk.ps1',[Convert]::FromBase64String('" + shrink_script_b64 + r"'))",
		r"powershell -ExecutionPolicy Bypass -File C:\\Deployer\\shrink-os-disk.ps1 -TargetSizeGB " + disk_size_gb
	])

print(",\n\t\t\t\t".join(json.dumps(cmd) for cmd in commands))
PY
)

gallery_image_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Compute/galleries/${gallery_name}/images/${image_definition}"
identity_resource="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${identity_name}"

# Determine image version: user-provided or auto-increment the latest existing
# Note: Since we delete/recreate image definitions, there won't be existing versions
# We start fresh at 1.0 for each build
if [[ -z "$image_version" ]]; then
	existing_versions=$(az sig image-version list --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" --query "[].name" -o tsv 2>/dev/null || true)
	if [[ -z "$existing_versions" ]]; then
		image_version="1.0"
		echo "No existing versions found; starting at ${image_version}"
	else
		latest=$(printf "%s\n" ${existing_versions} | sort -V | tail -n1)
		IFS='.' read -r major minor patch <<<"${latest}"
		major=${major:-1}; minor=${minor:-0}; patch=${patch:-}
		if [[ -z "$patch" ]]; then
			minor=$((minor + 1))
			image_version="${major}.${minor}"
		else
			patch=$((patch + 1))
			image_version="${major}.${minor}.${patch}"
		fi
		echo "Auto-incrementing image version from ${latest} -> ${image_version}"
	fi
else
	# User specified a version - use it as-is since we deleted any existing versions
	echo "Using specified image version: ${image_version}"
	# Check if it still exists (shouldn't since we deleted the definition)
	if az sig image-version show --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" --gallery-image-version "$image_version" >/dev/null 2>&1; then
		IFS='.' read -r major minor patch <<<"${image_version}"
		major=${major:-1}; minor=${minor:-0}; patch=${patch:-}
		if [[ -z "$patch" ]]; then
			minor=$((minor + 1))
			image_version="${major}.${minor}"
		else
			patch=$((patch + 1))
			image_version="${major}.${minor}.${patch}"
		fi
		echo "Requested version already exists; bumping to ${image_version}"
	fi
fi

# Image Builder does not support updating templates; find and delete any existing template with the base name
echo "Checking for existing image templates matching ${template_base_name}"
existing_templates=$(az resource list \
	--resource-group "$resource_group" \
	--resource-type Microsoft.VirtualMachineImages/imageTemplates \
	--query "[?starts_with(name, '${template_base_name}')].name" -o tsv 2>/dev/null || true)

if [[ -n "$existing_templates" ]]; then
	while IFS= read -r tmpl; do
		if [[ -n "$tmpl" ]]; then
			echo "Deleting existing image template ${tmpl}"
			az resource delete \
				--resource-group "$resource_group" \
				--name "$tmpl" \
				--resource-type Microsoft.VirtualMachineImages/imageTemplates 2>/dev/null || true
		fi
	done <<<"$existing_templates"
	
	# Poll until all templates are truly gone
	echo "Waiting for template deletion to complete..."
	for i in {1..30}; do
		remaining=$(az resource list --resource-group "$resource_group" --resource-type Microsoft.VirtualMachineImages/imageTemplates --query "[?starts_with(name, '${template_base_name}')].name" -o tsv 2>/dev/null | wc -l)
		if [[ "$remaining" -eq 0 ]]; then
			echo "Template deletion confirmed"
			break
		fi
		sleep 2
	done
	sleep 3
fi

# Generate a unique template name with incremental suffix
template_suffix=1
template_name="${template_base_name}-${template_suffix}"
while az resource show --resource-group "$resource_group" --name "$template_name" --resource-type Microsoft.VirtualMachineImages/imageTemplates >/dev/null 2>&1; do
	template_suffix=$((template_suffix + 1))
	template_name="${template_base_name}-${template_suffix}"
done
echo "Using template name: ${template_name}"

template_file="$(mktemp)"

# Determine osDiskSizeGB for AIB build VM
# The source marketplace image is 127 GB, so we must start with at least that size
# If target is smaller than 127 GB, we'll start at 127 GB and shrink it during customization
# If target is 127 GB or larger, use the target size directly
if [[ -n "$disk_size_gb" ]]; then
	if [[ $disk_size_gb -lt 127 ]]; then
		build_disk_size=127
		echo "Note: Source image is 127 GB, starting with 127 GB and will shrink to ${disk_size_gb} GB during build"
	else
		build_disk_size=$disk_size_gb
	fi
else
	build_disk_size=128
fi

cat >"${template_file}" <<EOF
{
	"location": "${location}",
	"identity": {
		"type": "UserAssigned",
		"userAssignedIdentities": {
			"${identity_resource}": {}
		}
	},
	"properties": {
		"buildTimeoutInMinutes": 240,
		"vmProfile": {
			"vmSize": "${vm_size}",
			"osDiskSizeGB": ${build_disk_size},
			"vnetConfig": null,
			"userAssignedIdentities": [
				"${identity_resource}"
			]
		},
		"stagingResourceGroup": "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${staging_resource_group}",
		"source": {
			"type": "PlatformImage",
			"publisher": "MicrosoftWindowsDesktop",
			"offer": "office-365",
			"sku": "win11-25h2-avd-m365",
			"version": "latest"
		},
		"customize": [
			{
				"type": "PowerShell",
				"name": "compact-settings",
				"inline": [
					${inline_commands}
				]
			}
		],
		"distribute": [
			{
				"type": "SharedImage",
				"galleryImageId": "${gallery_image_id}",
				"runOutputName": "${image_version}",
				"replicationRegions": ["${location}"],
				"artifactTags": {
					"source": "avd-build-pipeline-compact",
					"image": "${image_name}",
					"version": "${image_version}"
				}
			}
		]
	},
	"tags": {
		"SecurityControl": "Ignore",
		"builtBy": "avd-build-pipeline-compact",
		"sourceImage": "win11-25h2-avd-m365"
	}
}
EOF

echo "Creating image template ${template_name}"
az image builder create \
	--resource-group "$resource_group" \
	--name "$template_name" \
	--location "$location" \
	--identity "$identity_resource" \
	--image-source publisher=MicrosoftWindowsDesktop offer=office-365 sku=win11-25h2-avd-m365 version=latest \
	--scripts "${inline_commands}" \
	--managed-image-destinations "${image_definition}=${location}" \
	--vm-size "$vm_size" \
	--os-disk-size 128 \
	--build-timeout 240 \
	--tags SecurityControl=Ignore builtBy=avd-build-pipeline-compact sourceImage=win11-25h2-avd-m365 2>/dev/null || \
az resource create \
	--resource-group "$resource_group" \
	--name "$template_name" \
	--resource-type Microsoft.VirtualMachineImages/imageTemplates \
	--is-full-object \
	--properties @"${template_file}" \
	--api-version 2024-02-01

# Tag the image template after create
az resource update \
	--resource-group "$resource_group" \
	--name "$template_name" \
	--resource-type Microsoft.VirtualMachineImages/imageTemplates \
	--set tags.SecurityControl=Ignore tags.builtBy=avd-build-pipeline-compact tags.sourceImage=win11-25h2-avd-m365 >/dev/null 2>&1 || true

echo ""
echo "========================================================================"
echo "Starting image build (asynchronously - build runs in background)"
echo "========================================================================"
echo ""

# Start the build without waiting
az image builder run \
	--resource-group "$resource_group" \
	--name "$template_name" \
	--no-wait 2>/dev/null || \
az resource invoke-action \
	--resource-group "$resource_group" \
	--name "$template_name" \
	--resource-type Microsoft.VirtualMachineImages/imageTemplates \
	--action Run \
	--no-wait \
	--query name -o tsv >/dev/null

echo "Image build has been started in the background."
echo ""
echo "Image Details:"
echo "  - Image Definition: ${image_definition}"
echo "  - Target Version: ${image_version}"
echo "  - Template Name: ${template_name}"
echo "  - Resource Group: ${resource_group}"
echo "  - Gallery: ${gallery_name}"
if [[ -n "$disk_size_gb" ]]; then
	echo "  - Target Disk Size: ${disk_size_gb} GB"
fi
echo ""
echo "To check build status, run:"
echo "  az image builder show -g ${resource_group} -n ${template_name} --query lastRunStatus"
echo ""
echo "To check build logs (once template shows status), use:"
echo "  az image builder show-runs -g ${resource_group} -n ${template_name}"
echo ""
echo "To monitor in real-time:"
echo "  watch -n 10 \"az image builder show -g ${resource_group} -n ${template_name} --query '{status:lastRunStatus.runState,message:lastRunStatus.message}' -o table\""
echo ""
echo "Build typically takes 30-45 minutes. The image will appear in the gallery when complete."
echo "========================================================================"
