###
#
#   First Run set -a; source .env; set +a prior to running the script below
#
###

# Create Resource Group
az group create --name $RG --location $LOC

### VNET

# Dedicated virtual network with AKS subnet
az network vnet create \
    --resource-group $RG \
    --name $VNET_NAME \
    --location $LOC \
    --address-prefixes 10.200.0.0/16 \
    --subnet-name $AKSSUBNET_NAME \
    --subnet-prefix 10.200.1.0/24

# Dedicated subnet for Azure Firewall (Firewall name cannot be changed)
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $FWSUBNET_NAME \
    --address-prefix 10.200.2.0/24

### FIREWALL

# Create Public IP for FW
az network public-ip create -g $RG -n $FWPUBLICIP_NAME -l $LOC --sku "Standard"

# Install Azure Firewall preview CLI extension
az extension add --name azure-firewall

# Deploy Azure Firewall
az network firewall create -g $RG -n $FWNAME -l $LOC --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FWNAME -n $FWIPCONFIG_NAME --public-ip-address $FWPUBLICIP_NAME --vnet-name $VNET_NAME

# Capture Firewall IP Address for Later Use
FWPUBLIC_IP=$(az network public-ip show -g $RG -n $FWPUBLICIP_NAME --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FWNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# Create UDR and send internet to Firewall
az network route-table create -g $RG -l $LOC --name $FWROUTE_TABLE_NAME
az network route-table route create -g $RG --name $FWROUTE_NAME --route-table-name $FWROUTE_TABLE_NAME --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP
# az network route-table route create -g $RG --name $FWROUTE_NAME_INTERNET --route-table-name $FWROUTE_TABLE_NAME --address-prefix $FWPUBLIC_IP/32 --next-hop-type Internet

# Add FW Network Rules
az network firewall network-rule create -g $RG -f $FWNAME --collection-name 'aksfwnr' -n 'apiudp' --protocols 'UDP' --source-addresses '*' --destination-addresses "AzureCloud.$LOC" --destination-ports 1194 --action allow --priority 100
az network firewall network-rule create -g $RG -f $FWNAME --collection-name 'aksfwnr' -n 'apitcp' --protocols 'TCP' --source-addresses '*' --destination-addresses "AzureCloud.$LOC" --destination-ports 9000
az network firewall network-rule create -g $RG -f $FWNAME --collection-name 'aksfwnr' -n 'time' --protocols 'UDP' --source-addresses '*' --destination-fqdns 'ntp.ubuntu.com' --destination-ports 123

# Add FW Application Rules
az network firewall application-rule create -g $RG -f $FWNAME --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'https=443' --fqdn-tags "AzureKubernetesService" --action allow --priority 100

# Associate route table with next hop to Firewall to the AKS subnet
az network vnet subnet update -g $RG --vnet-name $VNET_NAME --name $AKSSUBNET_NAME --route-table $FWROUTE_TABLE_NAME

### Log Analytics Workspace 

# Add Diagnostic Logs to Firewall to Monitor Network Traffic
az monitor log-analytics workspace create -g $RG -n $LWNAME

# Get IDs for Log Analytics and Firewall
LW_ID=$(az monitor log-analytics workspace show -g $RG -n $LWNAME -o tsv --query id)
FW_ID=$(az network firewall show -g $RG -n $FWNAME -o tsv --query id)

# Setup logging for Firewall
az monitor diagnostic-settings create -n 'toLogAnalytics' \
   --resource $FW_ID \
   --workspace $LW_ID \
   --logs '[{"category":"AzureFirewallApplicationRule","Enabled":true}, {"category":"AzureFirewallNetworkRule","Enabled":true}, {"category":"AzureFirewallDnsProxy","Enabled":true}]' \
   --metrics '[{"category": "AllMetrics","enabled": true}]'

### Deploy AKS

# Create User Assigned Managed Identity for Cluster Identity
az identity create --name $AKS_MI_NAME --resource-group $RG

# Get RG Value and MI IDs
VNET_ID=$(az network vnet show -g $RG -n $VNET_NAME --query id -o tsv)
MI_ID=$(az identity show -n $AKS_MI_NAME -g $RG --query id -o tsv)
MI_PRINCIPAL_ID=$(az identity show -n $AKS_MI_NAME -g $RG --query principalId -o tsv)

# Assign Network Contributor against VNET
az role assignment create --assignee $MI_PRINCIPAL_ID --role "Network Contributor" --scope $VNET_ID

# Get Subnet ID
SUBNETID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME --name $AKSSUBNET_NAME --query id -o tsv)

# Deploy AKS
az aks create -g $RG -n $AKSNAME -l $LOC \
  --node-count 3 --generate-ssh-keys \
  --network-plugin $PLUGIN \
  --outbound-type userDefinedRouting \
  --load-balancer-sku standard \
  --enable-private-cluster --private-dns-zone system --disable-public-fqdn \
  --vnet-subnet-id $SUBNETID \
  --enable-managed-identity \
  --assign-identity $MI_ID