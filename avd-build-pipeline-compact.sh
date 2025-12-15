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
gallery_name="Ctechcomputegallery"
resource_group="avd-image-builder-rg"
location="westus"
script_path="./compact-avd.ps1"
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

# Set default staging resource group if not provided
if [[ -z "$staging_resource_group" ]]; then
	staging_resource_group="${resource_group}-staging"
fi

# If disk size is specified, append it to image definition name
if [[ -n "$disk_size_gb" ]]; then
	image_definition="${image_definition}-${disk_size_gb}gb"
	echo "Target disk size: ${disk_size_gb} GB - Image definition: ${image_definition}"
fi

# If a gallery with this name already exists anywhere in the subscription, reuse it.
existing_gallery=$(az sig list --query "[?name=='${gallery_name}'].{rg:resourceGroup,location:location}" -o tsv)
if [[ -n "$existing_gallery" ]]; then
	read -r existing_gallery_rg existing_gallery_location <<<"$existing_gallery"
	if [[ -n "$existing_gallery_rg" ]]; then
		echo "Found existing gallery ${gallery_name} in resource group ${existing_gallery_rg}; reusing it"
		resource_group="$existing_gallery_rg"
		location="$existing_gallery_location"
	fi
fi

echo "Using subscription: ${subscription_id}"
echo "Ensuring resource group ${resource_group} in ${location}"
if ! az group show --name "$resource_group" >/dev/null 2>&1; then
	echo "Creating resource group ${resource_group} in ${location}"
	az group create --name "$resource_group" --location "$location" --tags SecurityControl=Ignore >/dev/null
else
	echo "Resource group ${resource_group} already exists"
	az group update --name "$resource_group" --set tags.SecurityControl=Ignore >/dev/null
fi

echo "Ensuring staging resource group ${staging_resource_group} in ${location}"
if ! az group show --name "$staging_resource_group" >/dev/null 2>&1; then
	echo "Creating staging resource group ${staging_resource_group} in ${location}"
	az group create --name "$staging_resource_group" --location "$location" --tags SecurityControl=Ignore Purpose="AIB staging resources" >/dev/null
else
	echo "Staging resource group ${staging_resource_group} already exists"
	az group update --name "$staging_resource_group" --set tags.SecurityControl=Ignore tags.Purpose="AIB staging resources" >/dev/null
fi

echo "Ensuring shared image gallery ${gallery_name}"
if ! az sig show --resource-group "$resource_group" --gallery-name "$gallery_name" >/dev/null 2>&1; then
	az sig create --resource-group "$resource_group" --gallery-name "$gallery_name" --location "$location" --tags SecurityControl=Ignore >/dev/null
else
	echo "Shared image gallery ${gallery_name} already exists"
	az sig update --resource-group "$resource_group" --gallery-name "$gallery_name" --set tags.SecurityControl=Ignore >/dev/null
fi

echo "Ensuring image definition ${image_definition}"
if ! az sig image-definition show --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" >/dev/null 2>&1; then
	az sig image-definition create \
		--resource-group "$resource_group" \
		--gallery-name "$gallery_name" \
		--gallery-image-definition "$image_definition" \
		--publisher "MicrosoftWindowsDesktop" \
		--offer "windows-11" \
		--sku "win11-25h2-ent" \
		--os-type Windows \
		--hyper-v-generation V2 \
		--os-state Generalized \
		--tags SecurityControl=Ignore >/dev/null
else
	echo "Image definition ${image_definition} already exists"
	az sig image-definition update --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" --set tags.SecurityControl=Ignore >/dev/null
fi

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
shrink_script_path="$(dirname "$script_path")/shrink-os-disk.ps1"
shrink_script_b64=""
if [[ -n "$disk_size_gb" && -f "$shrink_script_path" ]]; then
	shrink_script_b64=$(base64 -w0 "$shrink_script_path")
fi

inline_commands=$(SCRIPT_B64="$script_b64" SHRINK_SCRIPT_B64="$shrink_script_b64" DISK_SIZE_GB="$disk_size_gb" python3 - <<'PY'
import json, os
script_b64 = os.environ["SCRIPT_B64"]
shrink_script_b64 = os.environ["SHRINK_SCRIPT_B64"]
disk_size_gb = os.environ["DISK_SIZE_GB"]

commands = [
	r"New-Item -ItemType Directory -Force -Path C:\\Deployer | Out-Null",
	r"[IO.File]::WriteAllBytes('C:\\Deployer\\compact-avd.ps1',[Convert]::FromBase64String('" + script_b64 + r"'))",
	r"powershell -ExecutionPolicy Bypass -File C:\\Deployer\\compact-avd.ps1"
]

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
if [[ -z "$image_version" ]]; then
	existing_versions=$(az sig image-version list --resource-group "$resource_group" --gallery-name "$gallery_name" --gallery-image-definition "$image_definition" --query "[].name" -o tsv)
	if [[ -z "$existing_versions" ]]; then
		image_version="1.0"
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
	fi
	if [[ -n "$latest" ]]; then
		echo "Auto-incrementing image version from ${latest} -> ${image_version}"
	else
		echo "No existing versions found; starting at ${image_version}"
	fi
else
	# If requested version exists, move to next minor unless user explicitly wants that exact version
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
# If disk_size_gb is specified, add buffer for build operations (use 20GB more than target)
# Otherwise use default 128GB
if [[ -n "$disk_size_gb" ]]; then
	build_disk_size=$((disk_size_gb + 20))
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

echo "Running image build (this can take a while)"
az image builder run \
	--resource-group "$resource_group" \
	--name "$template_name" 2>/dev/null || \
az resource invoke-action \
	--resource-group "$resource_group" \
	--name "$template_name" \
	--resource-type Microsoft.VirtualMachineImages/imageTemplates \
	--action Run \
	--query name -o tsv

echo "Submitted build. Track status with: az image builder show -g ${resource_group} -n ${template_name} --query lastRunStatus"
