---
title: "AKS Azure CNI Calico IP Masquerade"
date: 2020-12-11T11:42:17-05:00
draft: false
categories: ["Azure", "Kubernetes", "Networking", "AKS"]
tags: ["azure", "kubernetes", "networking", "kubenet", "azure cni", "cni", "aks", "calico"]
---

## Overview

Recently someone raised a question because they were seeing their traffic source NAT to the node IP when using Azure CNI and Calico. I've covered this a bit when I dug into the Azure CNI and it's impact on iptables in my [Aks Networking Iptables in AKS](../aks-networking-iptables) post. The short version is that the ip-masq-agent that runs in the cluster has a matching configmap which tells it was ranges it should ignore for outbound NAT. By default this range is set to the cluster's Vnet CIDR, however, in this post I was only looking at Azure CNI without any Kubernetes Network Policy applied. When you introduce calico into the mix some interesting things happen. Most noteably the ip-masq-agent config I shared in that article gets hijacked by Calico. Lets have a quick look at how this works.

## Setup

I'm not going to go through the full network setup here, as if you're hitting this post you've probably already run into this issue, but let me share my high level setup. In my lab I have two Vnets peered with each other. In Vnet A I have an AKS cluster and an Ubuntu node that I can use to test traffic between a node and cluster in the same Vnet. In Vnet B I just have an Ubuntu node to test traffic leaving the the AKS Vnet across the Vnet peering. On both Ubuntu nodes I've installed docker and started up an nginx pod using "```docker run -d -p 80:80 nginx```" and then once running I ran "```docker logs <containername> -f```" to watch the logs for nginx. The nginx logs will show the source IP for every request.

As for the AKS cluster, I created that in Vnet A using the following command to make sure I'd enabled Azure CNI and Calico.

```bash
# Create Cluster
az aks create -g <ResourceGroupName> \
-n azurecnicalico \
--network-plugin azure \
--network-policy calico \
--vnet-subnet-id <subnet resource id>
```

So now we have two Ubuntu nodes running Nginx that we can hit, with one being in the AKS Vnet and one in a separate peered Vnet. In our cluster we'll fire up a quick ubuntu test pod we can use to curl the two Ubuntu servers.

```bash
# Create Ubuntu Pod
cat <<EOF |kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: ubuntu
  name: ubuntu
spec:
  containers:
  - image: ubuntu
    name: ubuntu
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "while true; do sleep 30; done;" ]
  restartPolicy: Never
EOF
```

Now you can exec into the pod with ```kubectl exec -it ubuntu -- bash```, run an ```apt update``` and then ```apt install curl```. If you curl either of your servers you should see the nginx logs show the source IP. On the node in Vnet A (same vnet as the cluster) you'll see the pod ip, and on the node in Vnet B (outside of the AKS vnet) you'll see the node IP.

Lets check that out:

```bash
# Check out the pod IP
kubectl get pods -o wide
NAME                     READY   STATUS    RESTARTS   AGE     IP            NODE                                NOMINATED NODE   READINESS GATES
ubuntu                   1/1     Running   0          10m     10.240.0.46   aks-nodepool1-30745869-vmss000001   <none>           <none>

# Get the IP of the node the pod is running on
kubectl get node aks-nodepool1-30745869-vmss000001 -o wide
NAME                                STATUS   ROLES   AGE     VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
aks-nodepool1-30745869-vmss000001   Ready    agent   3d22h   v1.19.3   10.240.0.35   <none>        Ubuntu 18.04.5 LTS   5.4.0-1031-azure   containerd://1.4.1+azure
```

After running the above I can see the following:

* Pod IP: 10.240.0.46
* AKS Node IP: 10.240.0.97
* VNet A Server IP (Same Vnet as AKS): 10.240.0.97
* Vnet B Server IP (Different Vnet from AKS): 172.17.0.4

```bash
# Curl Vnet A Server (AKS Vnet) from our Ubuntu Pod
curl 10.240.0.97

# Docker Logs on the Vnet A Server
10.240.0.46 - - [11/Dec/2020:17:20:04 +0000] "GET / HTTP/1.1" 200 612 "-" "curl/7.68.0" "-"
```

As you can see above, within the same Vnet, the server we're calling sees the source IP is the pod IP (10.240.0.46).

```bash
# Curl Vnet B Server (Peered Vnet) from our Ubuntu Pod
curl 172.17.0.4

# Docker Logs on the Vnet A Server
10.240.0.35 - - [11/Dec/2020:17:21:45 +0000] "GET / HTTP/1.1" 200 612 "-" "curl/7.68.0" "-"
```

Now we can see that when traffic leaves the Vnet the server outside sees the source IP as the node IP (10.240.0.35).

## iptables

At this point we have a valid test scenario, and have been able to show the SNAT that is taking place..but where is this in an Azure CNI + Calico cluster. Lets have a look through the iptables. You'll need to ssh into a node. For this, as always, we'll use [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump/blob/master/README.md) but there are various other options, including using privileged containers. If you do ssh to a node, you'll need to [set up ssh access](https://docs.microsoft.com/en-us/azure/aks/ssh).

I'm going to jump right to the POSTROUTING chain here to save us some time, but obviously you could explore the full set of chains more extensively if you prefer.

```bash
# First I'll jump into a node
kubectl ssh-jump aks-nodepool1-30745869-vmss000000

# Now lets check out the POSTROUTING chain
sudo iptables -t nat -L POSTROUTING
Chain POSTROUTING (policy ACCEPT)
target     prot opt source               destination
cali-POSTROUTING  all  --  anywhere             anywhere             /* cali:O3lYWMrLQYEMJtB5 */
KUBE-POSTROUTING  all  --  anywhere             anywhere             /* kubernetes postrouting rules */
```

As we can see above, the POSTROUTING chain passes everything along to 'cali-POSTROUTING', so lets check that one out.

```bash
sudo iptables -t nat -L cali-POSTROUTING
Chain cali-POSTROUTING (1 references)
target     prot opt source               destination
cali-fip-snat  all  --  anywhere             anywhere             /* cali:Z-c7XtVd2Bq7s_hA */
cali-nat-outgoing  all  --  anywhere             anywhere             /* cali:nYKhEzDlr11Jccal */

# So cali-POSTROUTING passes to cali-fip-snat and cali-nat-outgoing
# Lets check those out
sudo iptables -t nat -L cali-fip-snat
Chain cali-fip-snat (1 references)
target     prot opt source               destination

sudo iptables -t nat -L cali-nat-outgoing
Chain cali-nat-outgoing (1 references)
target     prot opt source               destination
MASQUERADE  all  --  anywhere             anywhere             /* cali:flqWnvo8yq4ULQLa */ match-set cali40masq-ipam-pools src ! match-set cali40all-ipam-pools dst
```

Not much happending in cali-fip-snat, but we do see a pass to the MASQUERADE chain from the cali-nat-outgoing chain. MASQUERADE is where the SNAT happens. This rule has a few parameters on it. I won't dig deep into these, but the key to point out is the 'match-set' flag. match-set uses the [iptables extension](https://ipset.netfilter.org/iptables-extensions.man.html) ipset. IPSet allows you to have a table of addresses/ranges that can be queried from iptables. We can actaully see these tables using the [ipset](https://wiki.archlinux.org/index.php/Ipset) command. Let's check that out on our host.

```bash
sudo ipset list cali40masq-ipam-pools
Name: cali40masq-ipam-pools
Type: hash:net
Revision: 6
Header: family inet hashsize 1024 maxelem 1048576
Size in memory: 512
References: 1
Number of entries: 1
Members:
10.240.0.0/16
```

There it is! You can see the AKS Cluster Vnet CIDR is listed in the 'Members' block of this ipset, but how did it get there. We have a tip in the name of the ipset. If we search online for 'Calico IP Pools' we get to the Calico [ip pool](https://docs.projectcalico.org/reference/resources/ippool) documentation, where it turns out there's an ipool CRD! Lets check that out!

```bash
kubectl get ippools
NAME                  AGE
default-ipv4-ippool   3d23h

# Lets see whats in that ippool 
kubectl get ippool default-ipv4-ippool -o yaml
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"crd.projectcalico.org/v1","kind":"IPPool","metadata":{"annotations":{},"labels":{"addonmanager.kubernetes.io/mode":"Reconcile"},"name":"default-ipv4-ippool"},"spec":{"blockSize":26,"cidr":"10.240.0.0/16","ipipMode":"Never","natOutgoing":true}}
  creationTimestamp: "2020-12-07T18:15:30Z"
  generation: 3
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
  managedFields:
  - apiVersion: crd.projectcalico.org/v1
    fieldsType: FieldsV1
    fieldsV1:
      f:metadata:
        f:annotations:
          .: {}
          f:kubectl.kubernetes.io/last-applied-configuration: {}
        f:labels:
          .: {}
          f:addonmanager.kubernetes.io/mode: {}
      f:spec:
        .: {}
        f:blockSize: {}
        f:cidr: {}
        f:ipipMode: {}
        f:natOutgoing: {}
    manager: kubectl
    operation: Update
    time: "2020-12-11T15:49:39Z"
  name: default-ipv4-ippool
  resourceVersion: "802963"
  selfLink: /apis/crd.projectcalico.org/v1/ippools/default-ipv4-ippool
  uid: 8d1132dd-358a-4422-b188-f938fc2edc57
spec:
  blockSize: 26
  cidr: 10.240.0.0/16
  ipipMode: Never
  natOutgoing: true
```

Right at the bottom of that manifest we can see the spec, including the CIDR block, that matches our ippool CIDR. Now that we can see where this Vnet CIDR is coming from, can we change that routing rule to add additional CIDR blocks, like the one from VNet B. I'm going to use the [IPPool example](https://docs.projectcalico.org/reference/resources/ippool) from the Calico docs to create an ip pool with Vnet B's CIDR. I'm going to set the 'disable' flag to false, to be sure nothing tries to assign IPs from this range, but I do want calico to be aware of it for NAT. 

> **Note:** Before you mess around with ippools you should make sure you understand all of the options and the impact on your cluster.  

```bash

cat <<EOF |kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: othervnet
spec:
  cidr: 172.17.0.0/16
  natOutgoing: true
  disabled: true
  nodeSelector: all()
EOF

# Check out the ippools list
kubectl get ippools
NAME                  AGE
default-ipv4-ippool   4d
othervnet             61m

# Lets take another look at that ipset and see if we have a new cidr block added
sudo ipset list cali40masq-ipam-pools
Name: cali40masq-ipam-pools
Type: hash:net
Revision: 6
Header: family inet hashsize 1024 maxelem 1048576
Size in memory: 576
References: 1
Number of entries: 2
Members:
10.240.0.0/16
172.17.0.0/16
```

It worked! Now lets check out the traffic to Vnet A and Vnet B.

```bash
# Curl Vnet A Server (AKS Vnet) from our Ubuntu Pod
curl 10.240.0.97

# Docker Logs on the Vnet A Server
10.240.0.46 - - [11/Dec/2020:17:20:04 +0000] "GET / HTTP/1.1" 200 612 "-" "curl/7.68.0" "-"
```

As you can see above, within the same Vnet the server we're calling still sees the source IP is the pod IP (10.240.0.46). So we didnt break that.

What about the server in Vnet B.

```bash
# Curl Vnet B Server (Peered Vnet) from our Ubuntu Pod
curl 172.17.0.4

# Docker Logs on the Vnet A Server
10.240.0.46 - - [11/Dec/2020:17:55:50 +0000] "GET / HTTP/1.1" 200 612 "-" "curl/7.68.0" "-"
```

Success! The server in Vnet B now can see the pod IP! 

## Summary

As we saw in this post, Azure CNI will use the ip-masq-agent to snat any traffic leaving the vnet, but when we enable Calico network policy that control is taken over by Calico itself. Calico uses the IPPool crd to allow you to manage ippools, which are implemented with ipsets and the ipset iptables extension. You can add an IPPool to your cluster to your cluster to extend the range of IPs that will be ignored from SNAT. 

> **WARNING:** My understanding is that some network appliances may not like to see pod traffic that hasnt been NAT'd to a real host IP address, and may drop that traffic. I need to dig into this topic further in a future post, but for now you should proceed with caution when updating ippools in your AKS clusters. Assume that AKS does this SNAT for traffic outside of the Vnet for good reason, and do your own extensive testing for any such change.
