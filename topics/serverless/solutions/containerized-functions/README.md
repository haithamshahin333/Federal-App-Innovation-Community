# Running Azure Functions as Containers on AKS

# Concepts:

There are two pieces to implementing a serverless paradaigm within your Kubernetes cluster:

1. Azure Functions Runtime - This is the base image that executes your code. It includes the logic to trigger, log, and manage function executions. The list of [Azure Functions Base Images](https://hub.docker.com/_/microsoft-azure-functions-base) are documented. The CLI will help you generate the Dockerfile as you work through the example below.

2. Scale Controller - The scale controller monitors the rate of events targeting your function and proactively scales the number of instances. In your own cluster, this would be implemented with [KEDA](https://keda.sh/)

# Example of Deploying HTTP-Based Function App to Kubernetes

## Step 1: Containerizing the Azure Function

The following will go through an example of containerizing an Azure Function and running the container locally (using Python as an example).

> Take note that the `src` directory is included here as a reference - feel free to delete or move that as you work through the steps below which will generate your own folder and the relevant files needed for deployment.

Pre-Reqs:
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- Local Container Engine (Docker, Podman, etc.)
- Python 3 and Virtual Env
- [Azure Function Core Tools CLI](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=v4%2Cwindows%2Ccsharp%2Cportal%2Cbash)

1. First, we will build a functions project and get the function running locally:

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
```

> You should now be able to test your function on localhost:7071/api/httpexample. You can provide a query string such as ?name=testuser to test. (http://localhost:7071/api/httpexample?name=testuser)

2. Next we will build the container and run the function:

```bash
# Review the Dockerfile that the cli generated for you
# Take note of the base image - you can update this to mcr.microsoft.com/azure-functions/python:4-python3.8 for v4 runtime
cat Dockerfile

# Build the docker image locally - assumes container engine installed locally
docker build -t python-function:v4 .

# Run container locally to test
# Navigate to http://localhost:8080/api/HttpExample - generic url is http://localhost:8089/api/<FUNCTION-NAME>
docker run -p 8080:80 python-function:v4
```

> You should see that by hitting http://localhost:8080/api/httpexample?name=testuser that you get the same result. You can view the requests coming through live in the container logs if streaming to stdout

## Step 2: Deploying to AKS

As a next step, the containerized function will be deployed to AKS.

Pre-Reqs:
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

1. Deploy a Storage Account:

> Callout: Your azure function when deployed will rely on a Storage Account in Azure. Here are the storage services that your function app relies on: [storage considerations for functions](https://docs.microsoft.com/en-us/azure/azure-functions/storage-considerations?tabs=azure-cli).

> In a production scenario, you can enable a private endpoint for the storage account so that the function communicates privately to it. Should you be running from an on-premise kubernetes cluster, this would also enable you to communicate privately over VPN or Express Route.

```bash
# To deploy your function, you will need a storage account similar to hosting on Azure
# Take note that the storage account can remain private to your VNET by using a private endpoint

# Define env vars
export RG_NAME=demo-function-aks
export LOCATION=eastus
export STG_ACCT_NAME=azfuncaks080522        # name must be globally unique
export STG_SKU=Standard_LRS

# Create Resource Group
az group create --name $RG_NAME --location $LOCATION

# Create Storage Account
az storage account create --name $STG_ACCT_NAME --location $LOCATION --resource-group $RG_NAME --sku $STG_SKU

# Get connection string and set as property in local.settings.json
az storage account show-connection-string --resource-group $RG_NAME --name $STG_ACCT_NAME --query connectionString --output tsv
```

2. Set the `AzureWebJobsStorage` property in `local.settings.json` to the connection string returned from the last command.

> As an example, your file should look like the following:

```json
{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "AzureWebJobsStorage": "DefaultEndpointsProtocol=..." //APPLY YOUR CONNECTION STRING HERE
  }
}
```

3. Next, deploy a basic AKS cluster, push the image to ACR, and apply templates to deploy the function app

> This is a basic AKS Cluster, not recommended for production scenarios but good for the purpose of the test being conducted here.

> As an aside, notice how we are using ACR Tasks to run a docker build as opposed to pushing the image we built locally. This is a great way to build images in Azure.

```bash
# Set AKS and ACR env vars
export AKS_NAME=aks-cluster
export ACR_NAME=acrfunc0805 # globally unique 
export NODE_COUNT=2

# Create ACR
az acr create -n $ACR_NAME -g $RG_NAME --sku basic

# Create AKS
az aks create -g $RG_NAME -n $AKS_NAME --node-count=$NODE_COUNT --attach-acr $ACR_NAME --enable-addons monitoring

# Build and push image in ACR
az acr build -r $ACR_NAME --resource-group $RG_NAME -t python-function:v4 .

# Get ACR Login Server
export ACR_SERVER=$(az acr show -n $ACR_NAME -g $RG_NAME -o tsv --query loginServer)

# Login to ACR
az acr login -n $ACR_NAME

# Generate the kubernetes manifest to deploy the function
func kubernetes deploy --write-configs --name httpfunctionapp --no-docker --image-name $ACR_SERVER/python-function:v4

# Review the manifest - notice how values were taken from local.settings.json
cat functions.yaml

# Login to AKS and deploy the function
az aks get-credentials -n $AKS_NAME -g $RG_NAME

# Deploy the function
kubectl create ns function-app
kubectl apply -f functions.yaml -n function-app

# View the function's external-ip
kubectl get svc -n function-app

# Test the function
curl http://<EXTERNAL-IP>/api/httpexample # generic url format is http://<EXTERNAL-IP>/api/<FUNCTION-NAME>
```

## Step 3: Deploy KEDA

Let's create a new function that will leverage [KEDA](https://keda.sh/docs/2.7/deploy/) for scaling. The HTTP Trigger doesn't natively support scaling with KEDA, but there are way to do this through using other scaler objects such as prometheus. Here is an example of [scaling HTTP Triggered functions with prometheus and KEDA](https://dev.to/anirudhgarg_99/scale-up-and-down-a-http-triggered-function-app-in-kubernetes-using-keda-4m42).

1. Create a function triggered by an azure storage queue:

```bash
# create new directory in root of repo for this function
mkdir queue_function && cd queue_function

# init function
func init --worker-runtime python --docker --platform kubernetes

# use the queue template
func new --name queuetrigger --template "Azure Queue Storage trigger"

### Create a new storage account like before
# this will include a queue for the function as well
export RG_NAME=demo-function-aks
export LOCATION=eastus
export STG_ACCT_NAME=azqueuestg080522        # name must be globally unique
export STG_SKU=Standard_LRS

# Create Resource Group
az group create --name $RG_NAME --location $LOCATION

# Create Storage Account
az storage account create --name $STG_ACCT_NAME --location $LOCATION --resource-group $RG_NAME --sku $STG_SKU

# Create queue
# Queue name python-queue-items should be in your function.json file within the function
az storage queue create --name python-queue-items --account-name $STG_ACCT_NAME

# Get connection string and set as property in local.settings.json
az storage account show-connection-string --resource-group $RG_NAME --name $STG_ACCT_NAME --query connectionString --output tsv

# Start the function locally
func start
```

> Navigate to the portal and add a message to the queue, you should see the function be triggered. Here's instructions on how to add a message through the portal. Be sure to select the `encode the message in Base64` option since the function is expecting to read it in base64.

> In your stdout logs, you should see that once you add the message, the message is read by your function.

2. Deploy KEDA to Kubernetes:

> This is now an add-on for AKS - here are the [instructions](https://docs.microsoft.com/en-us/azure/aks/keda-deploy-add-on-cli) in the docs as well for deployment and deeper insight into each command

```bash
# add preview extension
az extension add --upgrade --name aks-preview

# register the feature
az feature register --name AKS-KedaPreview --namespace Microsoft.ContainerService

# check feature is registered
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/AKS-KedaPreview')].{Name:name,State:properties.state}"

# refresh
az provider register --namespace Microsoft.ContainerService

# update AKS
az aks update \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --enable-keda
```

> Once it's complete, you can run `kubectl get pods -A | grep keda` and you should see the Keda operator running

3. Deploy to Kubernetes:

```bash
# update the dockerfile to have base image mcr.microsoft.com/azure-functions/python:4-python3.8
cat Dockerfile

# build image on ACR
az acr build -r $ACR_NAME --resource-group $RG_NAME -t queue-function:v4 .

# Generate the kubernetes manifest to deploy the function
func kubernetes deploy --write-configs --name queueapp --no-docker --image-name $ACR_SERVER/queue-function:v4

# Review the manifest - notice how values were taken from local.settings.json
# Additionally, you'll now see a ScaledObject in the manifest which is a KEDA custom resource
cat functions.yaml
```

Prior to deployment, you will need to update the `functions.yaml` manifest - specifically the scaledObject:

Replace the ScaledObject resource with this yaml:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: queueapp
  labels: {}
spec:
  scaleTargetRef:
    name: queueapp
  cooldownPeriod: 10
  minReplicaCount: 0
  pollingInterval: 5
  triggers:
  - type: azure-queue
    metadata:
      direction: in
      queueName: python-queue-items
      connectionFromEnv: 'AzureWebJobsStorage'
```

Once updated, you can now deploy the function:

```bash
# Login to AKS and deploy the function
az aks get-credentials -n $AKS_NAME -g $RG_NAME

# Deploy the function
kubectl create ns queue-app
kubectl apply -f functions.yaml -n queue-app
```

> Notice how if you run `kubectl get pods -n queue-app` you'll see no pods running. Now, create a message and you should see one spin up.

> Furthermore, if you want to see KEDA actually scaling the pods in and out, you can find the KEDA operator in `kube-system` and view the logs:

```bash
# find all keda pods in kube-system
kubectl get pods -n kube-system | grep keda

# review logs of keda-operator pod:
kubectl logs pod/<COPY_KEDA_OPERATOR_POD> -n kube-system 
# example: kubectl logs pod/keda-operator-5dc466987c-cxt5l -n kube-system
```

> If you follow those logs as you add messages, you'll see KEDA spin pods up and down.

# Potential Next Steps

From here, you could go further and apply different function templates - for example, building a function triggered by messages in event hub. This is also where [KEDA](https://keda.sh/) could be applied for further scaling.

Check out the following [documentation](https://docs.microsoft.com/en-us/azure/azure-functions/functions-kubernetes-keda#supported-triggers-in-keda) to see the supported triggers that KEDA supports. Additional development and customization can be done for unique needs and requirements.

# References and Tooling Documentation

1. [Azure Functions Base Images](https://hub.docker.com/_/microsoft-azure-functions-base)

2. [Azure Function Core Tools Documentation](https://docs.microsoft.com/en-us/azure/azure-functions/functions-core-tools-reference?tabs=v2)

3. [Create a Function on Linux Using a Custom Container](https://docs.microsoft.com/en-us/azure/azure-functions/functions-create-function-linux-custom-image?tabs=in-process%2Cbash%2Cazure-cli&pivots=programming-language-python)