# Running Azure Functions as Containers on AKS

# Concepts:

1. Runtime - This is the base image that executes your code. It includes the logic to trigger, log, and manage function executions.

2. Scale Controller - The scale controller monitors the rate of events targeting your function and proactively scales the number of instances. In your own cluster, this would be implemented with [KEDA](https://keda.sh/)

# References and Tooling Documentation

1. [Azure Functions Base Images](https://hub.docker.com/_/microsoft-azure-functions-base)

2. [Azure Function Core Tools Documentation](https://docs.microsoft.com/en-us/azure/azure-functions/functions-core-tools-reference?tabs=v2)

3. [Create a Function on Linux Using a Custom Container](https://docs.microsoft.com/en-us/azure/azure-functions/functions-create-function-linux-custom-image?tabs=in-process%2Cbash%2Cazure-cli&pivots=programming-language-python)

# Example of Deploying HTTP-Based Function App to Kubernetes

## Step 1: Containerizing the Azure Function

The following will go through an example of containerizing an Azure Function and running the container locally (using Python as an example).

> Take note that the `src` directory is included here as a reference - feel free to delete or move that as you work through the steps below which will generate your own folder and the relevant files needed for deployment.

Pre-Reqs:
1. Az CLI
2. Docker
3. Python 3 and Virtual Env
4. Az Func Core Tools CLI

```bash
# Create src directory
mkdir src && cd src

# Create a Virtual Environment
python3 -m venv .venv
source .venv/bin/activate

# Initialize function app
func init --worker-runtime python --docker --platform kubernetes

# Create function within function app
func new --name HttpExample --template "HTTP trigger" --authlevel anonymous

# Test the function locally
func start

# Build the docker image locally - assumes container engine installed locally
docker build -t python-function:v1 .

# Run container locally to test
# Navigate to http://localhost:8080/api/HttpExample - generic url is http://localhost:8089/api/<FUNCTION-NAME>
docker run -p 8080:80 python-function:v1
```

## Step 2: Deploying to AKS

As a next step, the containerized function will be deployed to AKS.

Pre-Reqs:
1. kubectl

```bash
# To deploy your function, you will need a storage account similar to hosting on Azure natively
# Take note that the storage account can remain private to your VNET by using a private endpoint

# Define env vars
export RG_NAME=demo-function-aks
export LOCATION=eastus
export STG_ACCT_NAME=azfuncaks072922        # name must be globally unique
export STG_SKU=Standard_LRS

# Create Resource Group
az group create --name $RG_NAME --location $LOCATION

# Create Storage Account
az storage account create --name $STG_ACCT_NAME --location $LOCATION --resource-group $RG_NAME --sku $STG_SKU

# Get connection string and set as property in local.settings.json
az storage account show-connection-string --resource-group $RG_NAME --name $STG_ACCT_NAME --query connectionString --output tsv
# Set the string as the AzureWebJobsStorage property in local.settings.json
```

Next, deploy a basic AKS cluster, push the image to ACR, and apply templates to deploy the function app

```bash
# Set AKS and ACR env vars
export AKS_NAME=aks-cluster
export ACR_NAME=acrfunc0729 # globally unique 
export NODE_COUNT=2

# Create ACR
az acr create -n $ACR_NAME -g $RG_NAME --sku basic

# Create AKS
az aks create -g $RG_NAME -n $AKS_NAME --node-count=$NODE_COUNT --attach-acr $ACR_NAME --enable-addons monitoring

# Build and push image in ACR
az acr build -r $ACR_NAME --resource-group $RG_NAME -t python-function:v1 .

# Get ACR Login Server
export ACR_SERVER=$(az acr show -n $ACR_NAME -g $RG_NAME -o tsv --query loginServer)

# Login to ACR & Generate K8s Template
az acr login -n $ACR_NAME
func kubernetes deploy --write-configs --name httpfunctionapp --no-docker --image-name $ACR_SERVER/python-function:v1

# Login to AKS and deploy the function
az aks get-credentials -n $AKS_NAME -g $RG_NAME
kubectl create ns function-app
kubectl apply -f functions.yaml -n function-app

# View the function's external-ip
kubectl get svc -n function-app

# Test the function
curl http://<EXTERNAL-IP>/api/httpexample # generic url format is http://<EXTERNAL-IP>/api/<FUNCTION-NAME>
```

# Potential Next Steps

From here, you could go further and apply different function templates - for example, building a function triggered by messages in event hub. This is also where [KEDA](https://keda.sh/) could be applied for further scaling.

Check out the following [documentation](https://docs.microsoft.com/en-us/azure/azure-functions/functions-kubernetes-keda#supported-triggers-in-keda) to see the supported triggers that KEDA supports. Additional development and customization can be done for unique needs and requirements.