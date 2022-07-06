# Control AKS Egress Traffic

## Background

AKS clusters have outbound dependencies in order to properly operate. For example, base system container images come from the Microsoft Container Registry, which is an outbound FQDN that does not have a static IP address and therefore cannot be controlled through NSGs.

By default, AKS Clusters have unrestricted outbound internet access. To limit this outbound access, the use of a Network Virtual Appliance like Azure Firewall can allow the specific FQDNs required by AKS running from within your private virtual network.

The following [list of network rules](https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic) specifies the FQDNs needed by AKS to function properly. Take note of the cloud you are operating within and the add-ons used by your cluster to ensure you have the proper FQDNs.

## Env File

> Fill in your values and create a `.env` file in your local directory. From there, run `set -a; source .env; set +a` so the shell has the values provided.

```bash
PREFIX="aks-fw"
RG="${PREFIX}-rg"
LOC="eastus"
PLUGIN=kubenet
AKSNAME="${PREFIX}"
VNET_NAME="${PREFIX}-vnet"
AKSSUBNET_NAME="aks-subnet"
AKS_MI_NAME="${PREFIX}-user-assigned-mi"
# DO NOT CHANGE FWSUBNET_NAME - This is currently a requirement for Azure Firewall.
FWSUBNET_NAME="AzureFirewallSubnet"
FWNAME="${PREFIX}-fw"
FWPUBLICIP_NAME="${PREFIX}-fwpublicip"
FWIPCONFIG_NAME="${PREFIX}-fwconfig"
FWROUTE_TABLE_NAME="${PREFIX}-fwrt"
FWROUTE_NAME="${PREFIX}-fwrn"
FWROUTE_NAME_INTERNET="${PREFIX}-fwinternet"
LWNAME="${PREFIX}-lw"
```

## Deploy

> Run `deploy.sh` to deploy the architecture