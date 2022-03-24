#!/bin/bash

# IMPORTANT NOTE:
# You're trying this demo out, then you *need*
# to change these:
username="jannemattila"
repo="playground-aks-gitops"

# All the variables for the deployment
subscriptionName="AzureDev"
aadAdminGroupContains="janne''s"

aksName="myaksgitops"
workspaceName="mygitopsworkspace"
vnetName="myaksgitops-vnet"
subnetAks="AksSubnet"
identityName="myaksgitops"
resourceGroupName="rg-myaksgitops"
location="westeurope"

# Login and set correct context
az login -o table
az account set --subscription $subscriptionName -o table

# Prepare extensions and providers
az extension add --upgrade --yes --name aks-preview

# Enable feature
az feature register --namespace "Microsoft.ContainerService" --name "PodSubnetPreview"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/PodSubnetPreview')].{Name:name,State:properties.state}"
az provider register --namespace Microsoft.ContainerService

# Remove extension in case conflicting previews
az extension remove --name aks-preview

az group create -l $location -n $resourceGroupName -o table

aadAdmingGroup=$(az ad group list --display-name $aadAdminGroupContains --query [].objectId -o tsv)
echo $aadAdmingGroup

workspaceid=$(az monitor log-analytics workspace create -g $resourceGroupName -n $workspaceName --query id -o tsv)
echo $workspaceid

vnetid=$(az network vnet create -g $resourceGroupName --name $vnetName \
  --address-prefix 10.0.0.0/8 \
  --query newVNet.id -o tsv)
echo $vnetid

subnetaksid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAks --address-prefixes 10.2.0.0/24 \
  --query id -o tsv)
echo $subnetaksid

subnetstorageid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetStorage --address-prefixes 10.3.0.0/24 \
  --query id -o tsv)
echo $subnetstorageid

# Delegate a subnet to Azure NetApp Files
# https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-delegate-subnet
subnetnetappid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetNetApp --address-prefixes 10.4.0.0/28 \
  --delegations "Microsoft.NetApp/volumes" \
  --query id -o tsv)
echo $subnetnetappid

identityid=$(az identity create --name $identityName --resource-group $resourceGroupName --query id -o tsv)
echo $identityid

az aks get-versions -l $location -o table

# Note: for public cluster you need to authorize your ip to use api
myip=$(curl --no-progress-meter https://api.ipify.org)
echo $myip

az aks create -g $resourceGroupName -n $aksName \
 --max-pods 50 --network-plugin azure \
 --node-count 1 --enable-cluster-autoscaler --min-count 1 --max-count 2 \
 --node-osdisk-type Ephemeral \
 --node-vm-size Standard_D32ds_v4 \
 --kubernetes-version 1.22.6 \
 --enable-addons monitoring,azure-policy,azure-keyvault-secrets-provider \
 --enable-aad \
 --enable-managed-identity \
 --disable-local-accounts \
 --aad-admin-group-object-ids $aadAdmingGroup \
 --workspace-resource-id $workspaceid \
 --load-balancer-sku standard \
 --vnet-subnet-id $subnetaksid \
 --assign-identity $identityid \
 --api-server-authorized-ip-ranges $myip \
 -o table 

sudo az aks install-cli

az aks get-credentials -n $aksName -g $resourceGroupName --overwrite-existing

kubectl get nodes
kubectl get nodes -o wide

##################################################
#  ____              _       _
# | __ )  ___   ___ | |_ ___| |_ _ __ __ _ _ __
# |  _ \ / _ \ / _ \| __/ __| __| '__/ _` | '_ \
# | |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
# |____/ \___/ \___/ \__|___/\__|_|  \__,_| .__/
#                                         |_|
# cluster for Gitops
##################################################
# Install Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sudo bash
# Install Flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# enable completions in ~/.bash_profile
. <(flux completion bash)

export GITHUB_TOKEN=$(cat .env)
echo $GITHUB_TOKEN

flux check --pre

flux bootstrap github \
  --owner=$username \
  --repository=$repo \
  --branch=main \
  --token-auth \
  --private \
  --personal \
  --timeout 15m

# Wipe out the resources
az group delete --name $resourceGroupName -y
