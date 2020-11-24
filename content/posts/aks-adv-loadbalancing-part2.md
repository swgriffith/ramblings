---
title: "AKS Advanced Load Balancing Part 2: Kubernetes Services"
date: 2020-11-18T11:36:21-05:00
draft: false
categories: ["Azure", "Kubernetes", "Networking", "AKS"]
tags: ["azure", "kubernetes", "networking", "kubenet", "azure cni", "cni", "aks", "load balancer"]
---

## Overview

In my last post I focused on getting a deeper understanding of how AKS interacts with Azure, and specifically the Azure Load Balancer (ALB), to route traffic into a cluster. We walked through the default hashed based load balancing algorithm, and then showed the routing and ALB impact of using the Kubernetes service sessionAffinity mode of 'ClientIP' to enable sticky sessions. If you haven't run through that, then I'd definitely give [part 1](../aks-advanced-loadbalancing) a read before continuing here.

We're working our way down from an external user sending traffic through the ALB into a cluster, through an ingress controller and ultimately landing on a pod. After looking at the ALB, the next hop in our journey is a Kubernetes service. In this post we'll crack open iptables to see how creation and modification of a service ultimately translates to inter-cluster routing.

## Services

I won't go into a full explanation of services in Kubernetes here, as the Kubernetes [docs](https://kubernetes.io/docs/concepts/services-networking/service/) do a good job of that on their own, but I will lay out a few key concepts relative to Azure Kubernetes Service.

1. A service in Kubernetes provides a mechanism to expose a deployment to callers within and external to the cluster

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
    * Joined to Vnet noted above
* Test Application deployment with a Service of type LoadBalancer

## ALB Routing Review

As we discussed in [part 1](../aks-advanced-loadbalancing), the 'Default' distribution method for an ALB is hash based. That means that it uses a hash of the source and destination IP and ports, along with the protocol, to distribute traffic. This can be modified by enabling sessionAffinity on the Service, but lets leave it to Default for now. 

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
71.246.222.12  58796   20.185.96.169   80      6
10.220.1.6      25185   10.100.2.2      80      6
10.220.1.4      37406   10.100.2.2      80      6
10.220.1.6      59377   10.100.2.2      80      6
71.246.222.12  58799   20.185.96.169   80      6
10.220.1.4      1222    10.100.2.2      80      6
10.220.1.6      5473    10.100.2.2      80      6
71.246.222.12  58802   20.185.96.169   80      6
10.220.1.4      36522   10.100.2.2      80      6
10.220.1.6      41753   10.100.2.2      80      6
```

As you can see, our ALB is evenly distributing traffic such that we have some traffic coming directly at the node where our pod sits, as identified by the public internet ip of 72.X.X.X, and then we have an equal number of requests from our two other nodes at 10.220.1.4 and 10.220.1.6.

## iptables and Kubernetes Services

So how does this traffic actually hit a node where a pod doesnt exist and then get bounced over to the right node. The answer lies in the impact of Service creation on kube-proxy and iptables. Lets have a look at the iptables rules on our node.

>**NOTE:** We're going to run through some iptables commands which you have seen before if you read my post on [AKS Networking iptables](../aks-networking-iptables). If you haven't read that, it's probably worth a quick scan.

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

# Lets filter down to just our testapp rules
sudo iptables -t nat -nL KUBE-SERVICES|grep testapp
KUBE-MARK-MASQ  tcp  -- !10.100.0.0/16        10.200.105.65        /* default/testapp: cluster IP */ tcp dpt:80
KUBE-SVC-K4VUERBNKSOP4S25  tcp  --  0.0.0.0/0            10.200.105.65        /* default/testapp: cluster IP */ tcp dpt:80
KUBE-FW-K4VUERBNKSOP4S25  tcp  --  0.0.0.0/0            20.185.96.169        /* default/testapp: loadbalancer IP */ tcp dpt:80
```

If you look through the comments above we can see that there are three rules related to our 'testapp' service.

1. **KUBE-MARK-MASQ for source !10.100.0.0/16:** This one is saying that any traffic from outside of the pod cidr (10.100.0.0/16) should be marked for Source NAT. A later chain will check for this mark and SNAT the packet.

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

Looking at the above, the flow is pretty simple (don't let the crazy chain names scare you). When traffic comes in destined for 10.200.105.65 (our test app service ClusterIP), the KUBE-SERVICES chain sends that along to the KUBE-SVC-K4VUERBNKSOP4S25 chain. KUBE-SVC-K4VUERBNKSOP4S25 sends everything it gets right along to the KUBE-SEP-STQ7EMRESDHHERMG chain. The KUBE-SEP-STQ7EMRESDHHERMG chain sends any traffic out of the the pod (ip 10.100.2.2) to KUBE-MARK-MASQ, where it will be marked for SNAT (i.e. all pod outbound traffic also goes through SNAT). Finally, the traffic hits the DNAT chain where it gets passed along to the pod IP of 10.100.2.2. 

As you may recall from above, there was a chain for both the ClusterIP and the ExternalIP of the service; KUBE-SVC-K4VUERBNKSOP4S25 and KUBE-FW-K4VUERBNKSOP4S25. We checked out the ClusterIP chain already, so lets look at the ExternalIP chain.

```bash
# Get the rules for the KUBE-FW-K4VUERBNKSOP4S25 chain
sudo iptables -t nat -nL KUBE-FW-K4VUERBNKSOP4S25
Chain KUBE-FW-K4VUERBNKSOP4S25 (1 references)
target     prot opt source               destination
KUBE-MARK-MASQ  all  --  0.0.0.0/0            0.0.0.0/0            /* default/testapp: loadbalancer IP */
KUBE-SVC-K4VUERBNKSOP4S25  all  --  0.0.0.0/0            0.0.0.0/0            /* default/testapp: loadbalancer IP */
KUBE-MARK-DROP  all  --  0.0.0.0/0            0.0.0.0/0            /* default/testapp: loadbalancer IP */
```

So this chain is effectively accomplishes the same thing as the ClusterIP chain with two additions.

First, any traffic that hits this chain will get sent to KUBE-MARK-MASQ, which will mark the packet for SNAT. That means that when the traffic hits the pod, it will have gone through SNAT to the node ip, which you can see if you run '```kubectl logs <podname> -f```' and then throw some traffic at the ExternalIP. The logs will show the node IP as the source. So, even though we saw my internet ip coming through at the host interface card with tshark, once that traffic hits this rule it will SNAT and the pod will only ever see the host ip.

Second, the traffic gets passed along to the KUBE-SVC-K4VUERBNKSOP4S25 chain, which is the exact same chain we discussed above. So that chain will ultimately pass the traffic along to the pod itself.

Finally, if the KUBE-SVC-K4VUERBNKSOP4S25 chain doesn't pass along the traffic, which I think will only happen if the protocol doesnt match (i.e. you send udp instead of tcp, which it's expecting in the DNAT rule), the KUBE-MARK-DROP rule will hit and the packet will be marked such that the KUBE-FIREWALL chain drops it. You can check out the KUBE-FIREWALL chain with the following: ```sudo iptables -nL KUBE-FIREWALL```

Btw - all of the rules we've run through above are exactly the same across ALL nodes. Whoohooo! Why, though? Well, the magic lies in the very end of the chain, and the underlying network plugin. Looking above you can see that the final chain sends us to the pod IP of 10.100.2.2. From that point the host networking takes over by looking at the routes on the host. As you may recall from previous posts, if we run ```routes -n``` we can see where packets should next hop.

```bash
route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.220.1.1      0.0.0.0         UG    0      0        0 eth0
10.100.0.0      0.0.0.0         255.255.255.0   U     0      0        0 cbr0
10.220.1.0      0.0.0.0         255.255.255.0   U     0      0        0 eth0
168.63.129.16   10.220.1.1      255.255.255.255 UGH   0      0        0 eth0
169.254.169.254 10.220.1.1      255.255.255.255 UGH   0      0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
```

On this kubenet cluster, any packet destined for my local node pod cidr of 10.100.0.0/24 will get sent to the cbr0 bridge network, otherwise it will go the way of the subnet gateway at 10.220.1.1, which will make sure it gets to the right node. Go back and check out [AKS Networking Part 1](../aks-networking-part1) and [AKS Networking Part 2](../aks-networking-part2) for more details.

## Scaling Impact

Thus far we've had a deployment with only a single replica (i.e. single pod). Lets take a quick look at what happens when we scale up. To save on bytes, I'll isolate this down to JUST the parts from the above iptables chains that actually change.

```bash
# Scale the deployment
kubectl scale deployment testapp --replicas=3

# Check out the pods
kubectl get pods -o wide
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                                NOMINATED NODE   READINESS GATES
testapp-6f7947bc4b-cq567   1/1     Running   0          16s   10.100.1.4   aks-nodepool1-23454376-vmss000002   <none>           <none>
testapp-6f7947bc4b-rgm5l   1/1     Running   0          16s   10.100.0.7   aks-nodepool1-23454376-vmss000000   <none>           <none>
testapp-6f7947bc4b-x7427   1/1     Running   0          27h   10.100.2.2   aks-nodepool1-23454376-vmss000001   <none>           <none>
```

As you can see, we now have 3 pods for our testapp, which Kubernetes distributed for us across our 3 nodes.

```bash
sudo iptables -t nat -nL KUBE-SVC-K4VUERBNKSOP4S25

Chain KUBE-SVC-K4VUERBNKSOP4S25 (3 references)
target     prot opt source               destination
KUBE-SEP-GB5ZXZKDF6JWMI74  all  --  0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.33333333349
KUBE-SEP-SHJOK7USDC7L53KY  all  --  0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.50000000000
KUBE-SEP-STQ7EMRESDHHERMG  all  --  0.0.0.0/0            0.0.0.0/0
```

As I mentioned, I'm not going to make you read ALL of the chains. Just know that the KUBE-SVC-XXXX chain is the only one that really changed. As you can see above, we now have three KUBE-SEP-XXXX chains that will be hit using a statistical distribution of 1/3 to each. They execute in order, so if the first rule doesn't hit then there are only two left which switches the probability to 50%...so don't let that confuse you. It's still evenly distributing across the three backend pods. Again, as above, once the KUBE-SEP-XXXX chain is hit, then we do a DNAT to the right pod IP and the host network routing takes over to get the packet to the right host and/or bridge network.

## sessionAffinity

The last thing we'll look at is the impact of the Kubernetes service sessionAffinity option. As we saw in [part 1](../aks-adv-loadbalancing), if we set the sessionAffinity to ClientIP, the ALB gets updated to use SourceIP based distribution...but what does that do on the Kubernetes service side. Looking at the above we can see that once a packet hits iptables it will statistically distribute, so it goes to reason that a change must occur within iptables to make the pod sticky rather than using pure statistic load balancing.

```bash
# Again...channel your inner villain and lets directly edit the service
kubectl edit svc testapp

# Change the sessionAffinity setting to 'ClientIP 

# Lets throw a few curl calls at our service ip
curl 20.185.96.169
curl 20.185.96.169
curl 20.185.96.169
```

Ok, things are about to get a little weird. Again, saving some bytes, I'll tell that the main change was to the KUBE-SVC-XXXX and KUBE-SEP-XXXX chains. Lets have a look.

```bash
sudo iptables -t nat -nL KUBE-SVC-K4VUERBNKSOP4S25
Chain KUBE-SVC-K4VUERBNKSOP4S25 (3 references)
target     prot opt source               destination
KUBE-SEP-GB5ZXZKDF6JWMI74  all  --  0.0.0.0/0            0.0.0.0/0            recent: CHECK seconds: 10800 reap name: KUBE-SEP-GB5ZXZKDF6JWMI74 side: source mask: 255.255.255.255
KUBE-SEP-SHJOK7USDC7L53KY  all  --  0.0.0.0/0            0.0.0.0/0            recent: CHECK seconds: 10800 reap name: KUBE-SEP-SHJOK7USDC7L53KY side: source mask: 255.255.255.255
KUBE-SEP-STQ7EMRESDHHERMG  all  --  0.0.0.0/0            0.0.0.0/0            recent: CHECK seconds: 10800 reap name: KUBE-SEP-STQ7EMRESDHHERMG side: source mask: 255.255.255.255
KUBE-SEP-GB5ZXZKDF6JWMI74  all  --  0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.33333333349
KUBE-SEP-SHJOK7USDC7L53KY  all  --  0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.50000000000
KUBE-SEP-STQ7EMRESDHHERMG  all  --  0.0.0.0/0            0.0.0.0/0
```

I told you it was going to get a little weird. To keep it simple, lets read this in reverse. The bottom 3 rules should look familiar. This is the normal statistic load balancing of pod traffic that we've seen before. So if none of the top 3 rules hit, then the bottom 3 take over and we just get normal statistical load balancing sending 1/3 of the traffic to each backend pod through the KUBE-SEP-XXXX chains.

Now, lets look at the top 3. Looking at these, the target chains all make sense. Each rule sends us to one of our pods through a KUBE-SEP-XXXX chain. The source, destination and protocol all look normal too (all protocols, any source and any destination). What we haven't seen is this 'recent: CHECK.....' stuff at the end, so lets break that down.

For these additional flags, it's a little bit easier to view in the iptables command line format, so lets just pipe iptables-save to grep and get all the rows with 'recent'.

```bash
sudo iptables-save -t nat |grep recent
-A KUBE-SEP-GB5ZXZKDF6JWMI74 -p tcp -m recent --set --name KUBE-SEP-GB5ZXZKDF6JWMI74 --mask 255.255.255.255 --rsource -m tcp -j DNAT --to-destination 10.100.0.7:80
-A KUBE-SEP-SHJOK7USDC7L53KY -p tcp -m recent --set --name KUBE-SEP-SHJOK7USDC7L53KY --mask 255.255.255.255 --rsource -m tcp -j DNAT --to-destination 10.100.1.4:80
-A KUBE-SEP-STQ7EMRESDHHERMG -p tcp -m recent --set --name KUBE-SEP-STQ7EMRESDHHERMG --mask 255.255.255.255 --rsource -m tcp -j DNAT --to-destination 10.100.2.2:80
-A KUBE-SVC-K4VUERBNKSOP4S25 -m recent --rcheck --seconds 10800 --reap --name KUBE-SEP-GB5ZXZKDF6JWMI74 --mask 255.255.255.255 --rsource -j KUBE-SEP-GB5ZXZKDF6JWMI74
-A KUBE-SVC-K4VUERBNKSOP4S25 -m recent --rcheck --seconds 10800 --reap --name KUBE-SEP-SHJOK7USDC7L53KY --mask 255.255.255.255 --rsource -j KUBE-SEP-SHJOK7USDC7L53KY
-A KUBE-SVC-K4VUERBNKSOP4S25 -m recent --rcheck --seconds 10800 --reap --name KUBE-SEP-STQ7EMRESDHHERMG --mask 255.255.255.255 --rsource -j KUBE-SEP-STQ7EMRESDHHERMG
```

Great, now it's a little more clear whats going on. First of all, we can see the all of these rules have a '-m recent' flag. That flag is telling iptables to use the extension module called 'recent'. If we check out the [iptables extensions](http://ipset.netfilter.org/iptables-extensions.man.html) doc we can get more info. 

Looking at the above noted doc we can see that the 'recent' extension allows you to 'dynamically create a list of IP addresses and then match against that list in a few different ways'. This extension is useful if you were doing something like rate limiting or DDoS protection (i.e. how many times have I seen this ip in the last 10 seconds), or in our case routing the traffic to a specific KUBE-SEP-XXXX or DNAT chain. There are few other flags there that contribute, so lets look at those.

|Flag|Action|
|----|------|
|--name|Gives a name to the list. In our case each KUBE-SEP-XXXX (i.e. each target pod) will get it's own name|
|--rcheck|Checks if the inbound IP is already in the list|
|--set|Adds the current IP to the list|
|--rsource|Match and save the source IP to the list. This along with --rcheck and --set will make sure we check inbound IPs and add any that dont exist to the list|
|--mask|This sets the mask to be applied to the IP. In this case it's 255.255.255.255, meaning that the whole IP should be included|
|--reap & --seconds|These two work together. This is saying that we should 'reap' (i.e. purge) ips older than X seconds (10800 seconds in our case)|

One last thing to note here. As you can see from the iptables-save output, we are appending these rules to both KUBE-SEP-XXXX and KUBE-SVC-XXXX. This basically means that if a 'recent' rule matches at the service level then you'll go to that pod again, but if not you just get passed along to the statistic load balancing and once you land on a pods KUBE-SEP-XXXX chain that chain will add you to a recent list so that next time you come through the service level chain will know where you send you.

Those more curious may wonder where this 'recent' table lives. You can find it at ```/proc/net/xt_recent/```

Let's have a look:

```bash
# On our node
cd /proc/net/xt_recent/

# List the director contents
ls
KUBE-SEP-GB5ZXZKDF6JWMI74  KUBE-SEP-SHJOK7USDC7L53KY  KUBE-SEP-STQ7EMRESDHHERMG

# Check out the file contents
cat KUBE-SEP-STQ7EMRESDHHERMG
src=71.246.222.12 ttl: 48 last_seen: 4319972437 oldest_pkt: 3 4319971927, 4319972280, 4319972437
```

Nice! So we can see there, that this KUBE-SEP-XXXX was hit from my internet IP....so using the rule above, all of my traffic will continue to hit that chain.

## Impact of Availability Zones

In all of the above we haven't talked about the fact that we deployed this cluster using Availability Zones, so our pods are distributed between zones 1 & 2. Does that actually make a difference, positive of negative?

Kubernetes uses the failure-domain.beta.kubernetes.io/zone node label to indicate the node zone. In all of the analysis we did above we never saw that come into play. So no, there really isn't any impact on routing, other than the fact that a packet could land on a node in zone 1, and then the iptables rule may statistically load balance that packet over to a node on zone 2. While the overhead of that route should be minimal, it's not zero.

The take away is that you may see some increased latency in a multi-zone deployment. I like to think of zonal deployments as solving similar problems to multi-regional deployments on a micro scale, while also introducing some of the same potential issues around data replication and latency.

We'll talk about this more when we cover ingress controllers in the next post.

## Summary

In this post we ran through Kubernetes services, which are next hop after the Azure Load Balancer as traffic flows from a user to a backend pod. Here are the key learning points we hit:

1. The Kubernetes 'Service' resource allows you to load balance traffic to several backend pods in a deployment

1. kube-proxy is responsible for translating the Kubernetes networking configuration (pods and services) into iptables rules on the host nodes

1. When a packet is sent to a node from an Azure Load Balancer destined for a pod behind a Kubernetes service it will flow through the following key iptables chains: KUBE-SERVICES --> KUBE-SVC-XXXX --> KUBE-SEP --> DNAT

1. The KUBE-SVC-XXXX chain applies statistic load balancing to distribute traffic evenly across all backend pods

1. If sessionAffinity is set to ClientIP the KUBE-SVC-XXXX and KUBE-SEP-XXXX chains will use the iptables 'recent' extension to maintain stickiness from a source ip to a backend pod.

1. Kubernetes service load balancing in AKS pays no mind to zonal deployments, so if your application is distributed across zones you may notice some minimal increased latency. The impact of that will vary by your traffic patterns (i.e. for very chatty systems the aggregate latency could be a factor). You should just be aware of this as you execute your load tests.

Based on the above key points we can see that, even with sessionAffinity, our routing is still extremely basic. There's no concept of the impact of latency or any other more advanced metric on our traffic pattern. In my next post I'll look at ways that we can introduce more intelligent traffic routing through ingress controllers and service mesh.
