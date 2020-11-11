---
title: "AKS Advanced Load Balancing"
date: 2020-11-11T10:50:23-05:00
draft: true
categories: ["Azure", "Kubernetes", "Networking", "AKS"]
tags: ["azure", "kubernetes", "networking", "kubenet", "azure cni", "cni", "aks"]
---

## Overview

In the next few posts (yeah...I think this will require a few)..we're going to run through what the end to end traffic flow looks like for a packet going through an Azure Load Balancer, into an Nginx ingress controller and then to a backend set of pods. In particular, I want to help clarify the routing decisions that are made at each step of the flow and how that can impact your application behavior and performance.

In previous posts I've run you through the full stack for the AKS network plugins [Kubenet](../aks-networking-part1) and [Azure CNI](../aks-networking-part2). As part of that, we also ran through the traffic flows at the kernel level via [iptables](./aks-networking-iptables). Before we get into advanced load balancing, I strongly recommend you read through those posts to help with some of the base concepts that will come into play here.

## Setup

For the analysis we're going to run we'll need a test cluster with some resources deployed. I'm going to start with an AKS cluster using the 'Kubenet' network plugin. We'll deploy a set of single web server pods and an nginx ingress controller. Before we create the cluster, however, we'll need a network.

### Create Resource Group, Vnet and Subnets

```bash
RG=NetworkLab
LOC=eastus
VNET_CIDR="10.220.0.0/16"
KUBENET_AKS_CIDR="10.220.1.0/24"
SVC_LB_CIDR="10.220.3.0/24"

# Create Resource Group
az group create -n $RG -l $LOC

# Create Vnet
az network vnet create \
-g $RG \
-n aksvnet \
--address-prefix $VNET_CIDR

# Create the Cluster Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name kubenet \
    --address-prefix $KUBENET_AKS_CIDR

# Get the Kubenet Subnet ID
KUBENET_SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='kubenet'].id")

# Create the subnet for Kubernetes Service Load Balancers
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name services \
    --address-prefix $SVC_LB_CIDR
```
