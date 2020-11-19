---
title: "AKS Advanced Load Balancing Part2: Services"
date: 2020-11-18T11:36:21-05:00
draft: true
categories: ["Azure", "Kubernetes", "Networking", "AKS"]
tags: ["azure", "kubernetes", "networking", "kubenet", "azure cni", "cni", "aks", "load balancer"]
---

## Overview

In my last post I focused on getting a deeper understanding of how AKS interacts with Azure, and specifically the Azure Load Balancer (ALB), to route traffic into a cluster. We walked through the default hashed based load balancing algorithm, and then showed the routing and ALB impact of using the kubernetes service sessionAffinity mode of 'ClientIP' to enable sticky sessions. If you haven't run through that, then I'd definitely give [part 1](../aks-advanced-loadbalancing) a read before continuing here.

We're working our way down from an external user sending traffic through the ALB into a cluster, through an ingress controller and ultimately landing on a pod. After looking at the ALB, the next hop in our journey is a kubernetes service. In this post we'll crack open iptables to see how creation and modification of a service ultimately translates to inter-cluster routing.

## Services

I won't go into a full explanation of services in kubernetes here, as the kubernetes [docs](https://kubernetes.io/docs/concepts/services-networking/service/) do a good job of that on their own, but I will lay our a few key concepts relative to Azure Kubernetes Service.

1. A service in kubernetes provides a mechanism to expose a deployment to callers within and external to the cluster

1. Services are managed on a cluster via kube-proxy, which is run as a daemonset on your cluster (i.e. a kube-proxy pod on every node)

1. The [type](https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types) set for the service is key in determining how that service is exposed (i.e. Cluster Internal, Private Network, Public Internet, etc)

1. [kube-proxy](https://kubernetes.io/docs/concepts/overview/components/#kube-proxy) is responsible for interacting with the host node packet filtering implementation to set up relevant routes for resources on the cluster based on the 'type' you set

1. A service of type 'LoadBalancer' will trigger a call to the cloud provider to deploy a load balancer on the host cloud (ex. In AKS an ALB will be created. See [part 1](../aks-advanced-loadbalancing) for more details on this implementation)

## Setup

For this walk-through we're going to re-use the cluster created in [part 1](../aks-advanced-loadbalancing). This setup includes the following:

* Resource Group
* Vnet with a subnet for the cluster
* AKS Cluster
    * Network Plugin: Kubenet
    * Zones: 1 & 2
    * Joined to Vnet created above
* Test Application deployment with a Service of type LoadBalancer

## ALB Routing Review

As we discussed in [part 1](../aks-advanced-loadbalancing), the 'Default' distribution method for an ALB is hash based. That means that it uses a has of the source and destination IP and ports, along with the protocol, to distribute traffic. This can be modified by enabling sessionAffinity on the Service, but lets leave it to Default for now. 

Let's again use [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump/blob/master/README.md) to access a node and fire up our sweet [tshark](https://www.wireshark.org/docs/man-pages/tshark.html) command to watch for traffic. We'll again use [hey](https://github.com/rakyll/hey) to throw some requests at the cluster with tcp-keep-alive disabled.

```bash
# Get the node name for the node running out pod
kubectl get pods -o wide
NAME                       READY   STATUS    RESTARTS   AGE    IP           NODE                                NOMINATED NODE   READINESS GATES
testapp-6f7947bc4b-x7427   1/1     Running   0          12m    10.100.2.2   aks-nodepool1-23454376-vmss000001   <none>           <none>

# SSH to the node
kubectl ssh-jump aks-nodepool1-23454376-vmss000001

# Run tshark
sudo tshark -i eth0 -f 'port 80' -Y "http.request.method == "GET" && http contains YO" -T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e ip.proto
```

Now back on our local machine we run hey and check out the output in tshark on the AKS node

```bash
# Get the service external (ALB) ip
kubectl get svc
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)        AGE
kubernetes   ClusterIP      10.200.0.1      <none>          443/TCP        15m
testapp      LoadBalancer   10.200.105.65   20.185.96.169   80:30918/TCP   7m58s

# Fire off 10 requests to the service with the --disable-keepalive flag to ensure no duplicate source ports
hey --disable-keepalive -d "YO" -n 10 -c 2 http://20.185.96.169

# Output seen from tshark on the node
71.246.124.116  58796   20.185.96.169   80      6
10.220.1.6      25185   10.100.2.2      80      6
10.220.1.4      37406   10.100.2.2      80      6
10.220.1.6      59377   10.100.2.2      80      6
71.246.124.116  58799   20.185.96.169   80      6
10.220.1.4      1222    10.100.2.2      80      6
10.220.1.6      5473    10.100.2.2      80      6
71.246.124.116  58802   20.185.96.169   80      6
10.220.1.4      36522   10.100.2.2      80      6
10.220.1.6      41753   10.100.2.2      80      6
```

As you can see, our ALB is evenly distributing traffic such that we have some traffic coming directly at the node where our pod sits, as identified by the public internet ip of 72.X.X.X, and then we have an equal number of requests from our two other nodes at 10.220.1.4 and 10.220.1.6.

So how does this traffic actually hit a node where a pod doesnt exist and then get bounced over to the right node. The answer lies in the impact of Service creation on kube-proxy and iptables. Lets have a look at the iptables on two nodes. First, the node we're on right now, where our pod sits, and second on a node without our pod. 

>**NOTE:** We're going to run through some iptables commands which you have seen before if you read my post on [AKS Networking iptables]9../aks-networking-iptables). If you haven't read that, it's probably worth a quick scan.

```bash
# First have a look at the KUBE-SERVICES chain
sudo iptables -t nat -nL KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.0.10          /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
KUBE-SVC-ERIFXISQEP7F7OF4  tcp  --  0.0.0.0/0            10.200.0.10          /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.175.215       /* kube-system/metrics-server: cluster IP */ tcp dpt:443
KUBE-SVC-LC5QY66VUV2HJ6WZ  tcp  --  0.0.0.0/0            10.200.175.215       /* kube-system/metrics-server: cluster IP */ tcp dpt:443
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.105.65        /* default/testapp: cluster IP */ tcp dpt:80
KUBE-SVC-K4VUERBNKSOP4S25  tcp  --  0.0.0.0/0            10.200.105.65        /* default/testapp: cluster IP */ tcp dpt:80
KUBE-FW-K4VUERBNKSOP4S25  tcp  --  0.0.0.0/0            20.185.96.169        /* default/testapp: loadbalancer IP */ tcp dpt:80
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.70.146        /* kube-system/kubernetes-dashboard: cluster IP */ tcp dpt:443
KUBE-SVC-XGLOHA7QRQ3V22RZ  tcp  --  0.0.0.0/0            10.200.70.146        /* kube-system/kubernetes-dashboard: cluster IP */ tcp dpt:443
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.218.147       /* kube-system/dashboard-metrics-scraper: cluster IP */ tcp dpt:8000
KUBE-SVC-O33EAQYCTNTKHSTD  tcp  --  0.0.0.0/0            10.200.218.147       /* kube-system/dashboard-metrics-scraper: cluster IP */ tcp dpt:8000
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.0.1           /* default/kubernetes:https cluster IP */ tcp dpt:443
KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  0.0.0.0/0            10.200.0.1           /* default/kubernetes:https cluster IP */ tcp dpt:443
KUBE-MARK-MASQ  udp  -- !10.100.0.0/16        10.200.0.10          /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  0.0.0.0/0            10.200.0.10          /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
KUBE-NODEPORTS  all  --  0.0.0.0/0            0.0.0.0/0            /* kubernetes service nodeports; NOTE: this must be the last rule in this chain */ ADDRTYPE match dst-type LOCAL
```

If you look through the comments above we can see that there are three rules related to our 'testapp' service.

1. **KUBE-MARK-MASQ for source !10.100.0.0/16:** This one is saying that any traffic from outside of the pod cidr (10.100.0.0/16) should be marked for SNAT.

1. **KUBE-SVC-K4VUERBNKSOP4S25 from 0.0.0.0/0 to 10.200.105.65:** This rule says that any traffic (aka 0.0.0.0/0) destined for 10.200.105.65 (our service ClusterIP) should jump to the KUBE-SVC-K4VUERBNKSOP4S25 chain, which we'll check out in a minute

1. **KUBE-FW-K4VUERBNKSOP4S25 from 0.0.0.0/0 to 20.185.96.169:** And finally, this rule says that any traffic (aka 0.0.0.0/0) destined for 20.185.96.169 should jump to the KUBE-FW-K4VUERBNKSOP4S25 chain, which we'll also look at in a minute

First lets have a look at the KUBE-SVC-K4VUERBNKSOP4S25 chain.

```bash
# Get the rules for the KUBE-SVC-K4VUERBNKSOP4S25
sudo iptables -t nat -nL KUBE-SVC-K4VUERBNKSOP4S25
Chain KUBE-SVC-K4VUERBNKSOP4S25 (3 references)
target     prot opt source               destination         
KUBE-SEP-STQ7EMRESDHHERMG  all  --  0.0.0.0/0            0.0.0.0/0 

# KUBE-SVC-K4VUERBNKSOP4S25 jumps all traffic to KUBE-SEP-STQ7EMRESDHHERMG so lets check that
sudo iptables -t nat -nL KUBE-SEP-STQ7EMRESDHHERMG
Chain KUBE-SEP-STQ7EMRESDHHERMG (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.100.2.2           0.0.0.0/0           
DNAT       tcp  --  0.0.0.0/0            0.0.0.0/0            tcp to:10.100.2.2:80
```

