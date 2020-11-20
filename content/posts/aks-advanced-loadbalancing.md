---
title: "AKS Advanced Load Balancing - Part 1: Azure Load Balancer"
date: 2020-11-16T10:50:23-05:00
draft: false
categories: ["Azure", "Kubernetes", "Networking", "AKS"]
tags: ["azure", "Kubernetes", "networking", "kubenet", "azure cni", "cni", "aks"]
---

## Overview

In the next few posts (yeah...I think this will require a few)..we're going to run through what the end to end traffic flow looks like for a packet going through an Azure Load Balancer, into a Kubernetes service, then an ingress controller and finally to a backend set of pods. In particular, I want to help clarify the routing decisions that are made at each step of the flow and how that can impact your application behavior and performance.

In previous posts I've run you through the full stack for the AKS network plugins [Kubenet](../aks-networking-part1) and [Azure CNI](../aks-networking-part2). As part of that, we also ran through the traffic flows at the kernel level via [iptables](../aks-networking-iptables). Before we get into advanced load balancing, I strongly recommend you read through those posts to help with some of the base concepts that will come into play here.

Let's start by setting up our test cluster, and checking out the Azure Load Balancer.

## Setup

For the analysis we're going to run we'll need a test cluster with some resources deployed. I'm going to start with an AKS cluster using the 'Kubenet' network plugin. We'll deploy a set of simple web server pods and an nginx ingress controller. Before we create the cluster, however, we'll need a network.

### Create Resource Group, Vnet and Subnets

```bash
RG=LoadBalancingLab
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
```

### Create the Kubenet AKS Cluster

```bash
######################################
# Create the Kubenet AKS Cluster
#######################################
az aks create \
-g $RG \
-n kubenet-cluster \
--network-plugin kubenet \
--vnet-subnet-id $KUBENET_SUBNET_ID \
--zones 1 2 \
--pod-cidr "10.100.0.0/16" \
--service-cidr "10.200.0.0/16" \
--dns-service-ip "10.200.0.10"

# Get Credentials
az aks get-credentials -g $RG -n kubenet-cluster
```

>**NOTE:** We're creating this cluster using Availability Zones. While this post doesn't focus on zones, we will cover it in when we dig into services and ingress, so I'm enabling it here for future use.

### Deploy the sample app

To walk through the load balancing traffic flow we'll need a set of pods distributed across nodes with an Azure Load Balancer in front. For the sake of testing, since we have a 3 node cluster, lets have 2 pods and for the load balancer we'll set up a Kubernetes Service of type 'LoadBalancer'. That will provision a public Azure Load Balancer for us in front of our cluster.

```bash
# Create the Deployment and Service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: testapp
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    run: testapp
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    run: testapp
  name: testapp
spec:
  replicas: 1
  selector:
    matchLabels:
      run: testapp
  template:
    metadata:
      labels:
        run: testapp
    spec:
      containers:
      - image: nginx
        name: nginx
EOF

# Check out the deployment and service
kubectl get svc,pods -o wide
NAME                 TYPE           CLUSTER-IP       EXTERNAL-IP     PORT(S)        AGE   SELECTOR
service/kubernetes   ClusterIP      10.200.0.1       <none>          443/TCP        17m   <none>
service/testapp      LoadBalancer   10.200.252.245   20.62.153.222   80:31857/TCP   36s   run=testapp

NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE                                NOMINATED NODE   READINESS GATES
pod/testapp-6f7947bc4b-92g9l   1/1     Running   0          36s   10.100.0.4   aks-nodepool1-23454376-vmss000001   <none>           <none>
```

Great! Now we have our network, our cluster and a deployment we can start to play with. Since we create our service as 'type: LoadBalancer' our cluster called out to Azure and created an Azure Load Balancer for us. Let's send some traffic to that endpoint and see how it behaves.

### Azure Load Balancer (ALB) to Node

Any load balancer will have an algorithm it uses to determine where to send traffic. Some of the most common and basic are 'Round Robin', 'Statistic' and 'Hash Based'. If you take a look at the [Azure docs for the ALB](https://docs.microsoft.com/en-us/azure/load-balancer/concepts#load-balancing-algorithm) we can see that the default algorithm used by the ALB is hash based.

In short the ALB creates a hash of the the following:

* Source IP
* Source Port
* Destination IP
* Destination Port
* Protocol

Hashing of the above provides some stickiness, specifically if all of the above match, which will happen if the requests are from a common session. A common session will will obviously have the same source and destination IP and protocol, but additionally the outbound port from the source will be consistent. The client side 'TCP Keep Alive' setting will determine if an how long that outbound port will remain active. Lets have a look.

To see this lets first [setup SSH on our cluster](https://docs.microsoft.com/en-us/azure/aks/ssh) and use [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump/blob/master/README.md) to access a node.

```bash
# Get the managed cluster resource group and scale set names
CLUSTER_RESOURCE_GROUP=$(az aks show --resource-group $RG --name kubenet-cluster --query nodeResourceGroup -o tsv)
SCALE_SET_NAME=$(az vmss list --resource-group $CLUSTER_RESOURCE_GROUP --query "[0].name" -o tsv)

# Add your local public key to the VMSS to enable ssh access
az vmss extension set  \
    --resource-group $CLUSTER_RESOURCE_GROUP \
    --vmss-name $SCALE_SET_NAME \
    --name VMAccessForLinux \
    --publisher Microsoft.OSTCExtensions \
    --version 1.4 \
    --protected-settings "{\"username\":\"azureuser\", \"ssh_key\":\"$(cat ~/.ssh/id_rsa.pub)\"}"

az vmss update-instances --instance-ids '*' \
    --resource-group $CLUSTER_RESOURCE_GROUP \
    --name $SCALE_SET_NAME

# Grab the node name for one of our pods
kubectl get pods -o wide
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                                NOMINATED NODE   READINESS GATES
testapp-6f7947bc4b-92g9l   1/1     Running   0          26m   10.100.0.4   aks-nodepool1-23454376-vmss000001   <none>           <none>

# ssh-jump to the node. Note: Sometimes it takes a minute for the jump pod to be ready, 
# so you may need to run the command a couple times.
kubectl ssh-jump aks-nodepool1-23454376-vmss000001
```

Ok, so now we're connected into a node that has one of our web server pods running on it. I want to see requests hitting that node network interface card and what source they're coming from so that I can see how traffic is being load balanced. We could use tcpdump for this, capture a pcap file and then open that in WireShark to do all kinds of fun analysis, but getting the file off of the node will be annoying. Alternatively, we could use [ksniff](https://github.com/eldadru/ksniff) to feed the pod traffic directly into a local instance of WireShark, but I really want to see the raw traffic as close to the interface card as possible. While there are probably 100 other ways, I found [tshark](https://www.wireshark.org/docs/man-pages/tshark.html) to be the perfect tool here. tshark will let you get all the query and filter functionality of WireShark in a local terminal, which we can run right on our node.

First, lets install tshark.

```bash
sudo apt update
sudo apt install tshark
```

Now lets take a look at the command we're going to run to watch traffic into our node. Check out the following and then I'll break it all down.
```bash
sudo tshark -i eth0 -f 'port 80' -Y "http.request.method == "GET" && http contains YO" -T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e ip.proto
```

Here are the key components of this command:

|Param|Purpose|
|:-----|:-------|
|-i eth0|Select the eth0 network interface|
|-f 'port 80'|This is a filter for tcpdump to just get traffic to port 80|
|-Y "http.request.method == "GET" && http contains YO"|Since we're grabbing all port 80 traffic we need a way to filter it down to our specific requests. There are many ways to do this, but I chose to use the -Y flag to query out all of the GET requests that contain the word 'YO'|
|-T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e ip.proto| Display the source ip, source port, destination ip, destination port and protocol as output (6=TCP for protocol)|

If we run the above command on the Kubernetes node it should now be listening for our traffic....and now we need to send some traffic. There are a million options here. I personally like either curl or [hey](https://github.com/rakyll/hey). For this test I'll use hey. 

I'll start by sending just 10 request to see what we see come through on our node.

```bash
# Send 10 web request with the message body 'YO' to my service load balancer
hey -d "YO" -n 10 -c 1 http://20.62.153.212

# Output on the AKS Node side
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
71.246.222.127  65519 20.62.153.222 80  6
```

Well thats interesting! I have a 3 node cluster, but it seems that ALL of my traffic came directly to my node. Knowing that we have a hash based load balancer I was hoping to see traffic hitting different nodes and bouncing over here. If you paid attention when we discussed how hash based load balancing works you probably already know what happened. The output above shows all the values that go into the hashing...and they're the same for EVERY request, so of course the traffic went the same way every time.

If I want my traffic to hit different nodes, how can I force that. I could send traffic from a bunch of different machines to change the source IP, but that's annoying. I cant change the destination IP or port, or the protocol. What I can change, however, is the source port. Source port is unique for each tcp session. If I can disable tcp keep alive, then every request should have it's own source port. Fortunately 'hey' has a flag for that. Lets try.

```bash
# Send another 10 request, but disable keepalive
hey --disable-keepalive -d "YO" -n 10 -c 1 http://20.62.153.212

# Output on the AKS Node side
10.220.1.6      1790  10.100.0.4    80  6
71.246.222.127  49208 20.62.153.222 80  6
10.220.1.4      65333 10.100.0.4    80  6
10.220.1.6      45617 10.100.0.4    80  6
71.246.222.127  49211 20.62.153.222 80  6
10.220.1.4      57109 10.100.0.4    80  6
10.220.1.6      49180 10.100.0.4    80  6
71.246.222.127  49214 20.62.153.222 80  6
10.220.1.4      62651 10.100.0.4    80  6
10.220.1.6      22446 10.100.0.4    80  6
```

Ah, that looks better. Now we're seeing traffic more evenly distributed. I have three nodes, so some of my traffic comes direct to the node without any SNAT (thats the traffic you see with an internet ip of 71.X.X.X), the rest of the traffic you see coming from 10.220.1.4 and 10.220.1.6, which are the other nodes in the cluster. When traffic hits a node kube-proxy and iptables will take over and send that traffic along to the right place (more on this in my [next post](../aks-adv-loadbalancing-part2)). In this case, since we only have one node with my testapp pod on it, all the other nodes will just pass the traffic to the node we're currently monitoring. That traffic will SNAT, which is why we only see my internet IP on traffic that the ALB sent directly to the node my pod is sitting on.

So what we can gleam from the above is that our traffic will be evenly distributed if it's evenly sourced. If we have a specific source that holds extra long tcp sessions, or if a specific source is very 'bursty' (i.e. a bunch of traffic in a very short period of time), that traffic may make the distribution a bit unbalanced.

### SessionAffinity

What if we actually want the session to be sticky? Well, Kubernetes has a solution for that. Let's see how that works.

If you want session affinity, you can set this on the service object by setting 'service.spec.sessionAffinity' to 'ClientIP'....but what impact does that actually have? Does the routing algorithm for the Azure Load Balancer actually change from using a hash based distribution (Default). Lets have a look.

First lets check out our cluster's load balancer current configuration

```bash
# Get the Cluster Resource Group, which will contain the load balancer
CLUSTER_RESOURCE_GROUP=$(az aks show --resource-group $RG --name kubenet-cluster --query nodeResourceGroup -o tsv)

# Get the distribution mode for the Azure Load Balancer
az network lb rule list -g $CLUSTER_RESOURCE_GROUP --lb-name kubernetes -o yaml|grep loadDistribution
# Output
loadDistribution: Default
```

As you can see above, we're still using the 'Default' loadDistribution algorithm which is hash based. Lets change the service to enable sessionAffinity.

```bash
# I'm going to be evil here and just kubectl edit...YOLO
kubectl edit svc testapp

# Change the sessionAffinity setting to 'ClientIP
# Save and exit vim...unless you've changed your default editor

# On the client side, run our hey test again
hey --disable-keepalive -d "YO" -n 100 -c 2 http://20.62.153.222

# Check the output on our node:
10.220.1.4  17239 10.100.0.4  80  6
10.220.1.4  42969 10.100.0.4  80  6
10.220.1.4  35003 10.100.0.4  80  6
10.220.1.4  57065 10.100.0.4  80  6
10.220.1.4  60440 10.100.0.4  80  6
10.220.1.4  46570 10.100.0.4  80  6
10.220.1.4  9558  10.100.0.4  80  6
10.220.1.4  26470 10.100.0.4  80  6
10.220.1.4  22225 10.100.0.4  80  6
10.220.1.4  9299  10.100.0.4  80  6
```

Interesting, so now we see that ALL of our traffic is coming directly from 10.220.1.4. If I jump to another host and hit this link, I'll see that I take a different path.

```bash
# I jumped into the Azure Cloud Shell and sent the following 4 times
curl -H 'Cache-Control: no-cache' -H 'YO: itme' http://20.62.153.222

# In my tshark logs I see this
104.211.53.219  3008  20.62.153.222 80  6
104.211.53.219  3009  20.62.153.222 80  6
104.211.53.219  3010  20.62.153.222 80  6
104.211.53.219  3011  20.62.153.222 80  6
```

So did this change actually modify the Azure Load Balancer algorithm?

```bash
# Get the Cluster Resource Group, which will contain the load balancer
CLUSTER_RESOURCE_GROUP=$(az aks show --resource-group $RG --name kubenet-cluster --query nodeResourceGroup -o tsv)

# Get the distribution mode for the Azure Load Balancer
az network lb rule list -g $CLUSTER_RESOURCE_GROUP --lb-name kubernetes -o yaml|grep loadDistribution

#Output
loadDistribution: SourceIP
```

Indeed it did! So by modifying the kubernetes service object to have a sessionAffinity of 'ClientIP' a call was initiated from the cluster to update the load balancing algorithm of our Azure Load Balancer from 'Default' (hash based) to 'SourceIP'.

## Summary

In this post we focused directly on the relationship between an Azure Load Balancer and an AKS cluster. We learned a few key things.

1. As you saw, the ALB has a hash based default load balancing algorithm, which generally distributes traffic well, but you should be aware of your traffic patterns and how they may lead to hot spots in your cluster. In particular the if callers are holding long tcp sessions.

1. Along the same lines, considering that the traffic is evenly distributed, if you enable [Availability Zones](https://docs.microsoft.com/en-us/azure/aks/availability-zones), you could see some increased latency as traffic is routed to a node in zone 1 and then kubernetes bounces it over to a node in zone 2. We'll dig into this one a bit more in my next post on Service Level Load Balancing.

1. AKS will modify the distribution method of the ALB to SourceIP if you enable sessionAffinity for your Kubernetes service.

I very intentionally avoided getting into kubernetes service routing, internal to the cluster, and the impact of iptables. We'll take a look at that in my next post. Hopefully you found this useful.

**Next:** [AKS Advanced Load Balancing Part 2: Kubernetes Services](../aks-adv-loadbalancing-part2)
