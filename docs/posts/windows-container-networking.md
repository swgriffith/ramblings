---
title: "Windows Container Networking"
date: 2021-12-03T10:11:51-05:00
draft: true
categories: ["Azure", "Kubernetes", "Networking", "AKS", "Windows"]
tags: ["azure", "kubernetes", "networking", "kubenet", "azure cni", "cni", "aks", "windows", "containers"]
---

## Overview

Those of you that know me know that I HATE when I don't understand how something works. I quickly jump into the documentation for any challenge, to at least understand the fundamental moving parts. I recently had to work through some Windows container networking issues in AKS, and had a hard time finding documentation that really pulled it all together in a nice clear way. Don't get me wrong, there is a TON of good documentation out there to explain Windows Container Networking, Kubernetes Networking and Windows Containers on Kubernetes networking....but nothing that really showed the implementation in AKS. As I regularly help people debug issues in AKS, I needed this laid out. 

In this post, I'll start from the bottom (Azure NIC) up through kubernetes pods and services. I may get it a bit wrong at times, so I welcome any input as issues, which you can post [here](https://github.com/swgriffith/ramblings/issues). I hope, however, that I'm close enough to help some of you out.

Let's jump into it.

## AKS Azure Node Network configuration

When you create an AKS cluster for Windows, following the guide [here](https://docs.microsoft.com/en-us/azure/aks/windows-container-cli), you end up with two nodepools. One Linux pool, which is responsible for running system components which have not yet been compiled to run on Windows Server, and one Windows pool, which will host your Windows pods. These nodepools use Azure Virtual Machine Scale Sets for managing the underlying compute. 

Each VM in the VMSS has it's own network interface card which gets attached to the target Vnet/Subnet. If we go and look at the attached interfaces on the Vnet we'll see something interesting:

![aks kubenet route table](/azure-networking/instanceips.png)

Why does each instance have so many IPs!?!? This is because AKS [currently only supports Azure CNI](https://docs.microsoft.com/en-us/azure/aks/windows-faq#what-network-plug-ins-are-supported). Azure CNI, in it's current version, will automatically bind ip addresses from your subnet to each node. By default, it will assigne one IP for the node itself and 30 IPs for pods, giving you a total of 31 IPs per node bound to the NIC.

Let's go take a look at the node itself. There are several ways to get connected to the Windows AKS node. You can check the Microsoft docs [here](https://docs.microsoft.com/en-us/azure/aks/ssh) for the official process. I, however, prefer to just use [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump). This kubectl plugin will deploy a jump pod into your cluster that can be used to ssh into the various cluster nodes. Since ssh is enabled on AKS Windows nodes, and since I created the cluster using my local ssh key, I can just jump directly to the Windows node (*Note:* The first time you run ssh-jump it will sometimes time out. Just run it again.)

```
kubectl get nodes
NAME                                STATUS   ROLES   AGE     VERSION
aks-nodepool1-42275068-vmss000000   Ready    agent   2d20h   v1.20.9
aks-nodepool1-42275068-vmss000001   Ready    agent   2d20h   v1.20.9
akswin000000                        Ready    agent   2d18h   v1.20.9
akswin000001                        Ready    agent   2d18h   v1.20.9

kubectl ssh-jump akswin000000

Microsoft Windows [Version 10.0.17763.2300]
(c) 2018 Microsoft Corporation. All rights reserved.

griffith@akswin000000 C:\Users\griffith>
```

Nice! We're in. Let's check out the basic network configuration on the host.

```
griffith@akswin000000 C:\Users\griffith>ipconfig

Windows IP Configuration


Ethernet adapter vEthernet (Ethernet 2):

   Connection-specific DNS Suffix  . : b3jjdx52msaejilks24ajuu1jc.bx.internal.cloudapp.net
   Link-local IPv6 Address . . . . . : fe80::e5b3:e063:ad80:61b%9
   IPv4 Address. . . . . . . . . . . : 10.240.0.66
   Subnet Mask . . . . . . . . . . . : 255.255.0.0
   Default Gateway . . . . . . . . . : 10.240.0.1

Ethernet adapter vEthernet (nat):

   Connection-specific DNS Suffix  . :
   Link-local IPv6 Address . . . . . : fe80::a4f6:5ea3:7944:5378%12
   IPv4 Address. . . . . . . . . . . : 172.21.64.1
   Subnet Mask . . . . . . . . . . . : 255.255.240.0
   Default Gateway . . . . . . . . . :
```

So, that seems pretty straight forward, but it doesn'l look like the full picture. Coming from the Linux side I expect to se virtual ethernet adapters for each container, and looking at the Windows Container docs, I see I should have a virtual adpater per container. Let's try another command.

```powershell
Get-NetAdapter

Name                      InterfaceDescription                    ifIndex Status       MacAddress             LinkSpeed
----                      --------------------                    ------- ------       ----------             ---------
vEthernet (ef97202f-eth0)                                              28 Up           00-15-5D-E8-6F-94       100 Gbps
vEthernet (SwitchName)    Hyper-V Virtual Ethernet Adapter #5          34 Up           00-15-5D-00-42-00        10 Gbps
Ethernet 2                Microsoft Hyper-V Network Adapter #2         10 Up           00-0D-3A-55-FE-7D       100 Gbps
vEthernet (cc97a9e8-eth0)                                              23 Up           00-15-5D-E8-6B-62       100 Gbps
vEthernet (Ethernet 2)    Hyper-V Virtual Ethernet Adapter #2           9 Up           00-0D-3A-55-FE-7D       100 Gbps
vEthernet (nat)           Hyper-V Virtual Ethernet Adapter             12 Up           00-15-5D-7A-51-D7        10 Gbps
```

That's more like it. Now I can see all of the adapters from ipconfig, but also I now see the vEthernet adapters used by each pod on the node. Lets look at those individual adapters. Since the adapters names look a lot like docker container ID's we can try to inspect.

```powershell
docker inspect ef97202f
[
    {
        "Id": "ef97202f4612748842efd3575468bf0c0d0cf5b6c65cf0270a22aab889bd7d72",
        "Created": "2021-12-02T22:07:35.8197236Z",
        "Path": "/pause.exe",
        "Args": [],
        "State": {
            "Status": "running",
.....
_______________________________________
docker inspect cc97a9e8
[
    {
        "Id": "cc97a9e8a72c3dea175d9b48ca7eb0f7287747fd37bb295a2fa418e052265238",
        "Created": "2021-12-02T22:03:44.6371243Z",
        "Path": "/pause.exe",
        "Args": [],
        "State": {
            "Status": "running",
```

Ok, so we can see the both of those virtual adapters are bound to the 'pause' container. If you're not familiar with the pause container in Kubernetes, it's the glue that holds the containers in a Kubernetes pod together, sharing the local storage and network namespaces. You can get more detail by reading [this](https://www.ianlewis.org/en/almighty-pause-container) article. It was written for Linux, but the concepts are the same.

We can see the pause container being network bound to another container in the pod if we docker inspect the other container. In the below you can see that the Network Mode of the container is using the pause container network, as compared to 'Bridge', 'Host' or 'No Network' modes.

```powershell
docker inspect 385574c925c1 --format='{{.HostConfig.NetworkMode}}'
container:cc97a9e8a72c3dea175d9b48ca7eb0f7287747fd37bb295a2fa418e052265238
```

### Azure CNI and IPAM

We saw above that our container is connected to the pause container, and the pause container has a vEthernet device...but what is that vEthernet attached to, and how did it get it's IP address?

If we inspect the pause container and look at the 'Networks' section, we get a good idea of where to start. 

```powershell
docker inspect cc97a9e8a72c3dea175d9b48ca7eb0f7287747fd37bb295a2fa418e052265238 --format='{{json .Ne
"4ebddc462694e33d95059bffb9af4041f5b8777d1a4bd3e3a9914afbb78df176"
```

As we can see, the pause container is connected to the network id '4ebddc46269...'. We can see that network by looking at the local docker networks.

```powershell
docker network ls
NETWORK ID     NAME      DRIVER     SCOPE
00864e91df94   ext       l2bridge   local
be1fa198c3cf   nat       nat        local
4ebddc462694   none      null       local
```

If we inspect that network we can see the containers attached to it.

```powershell
docker network inspect 4ebddc462694
[
    {
        "Name": "none",
        "Id": "4ebddc462694e33d95059bffb9af4041f5b8777d1a4bd3e3a9914afbb78df176",
        "Created": "2021-11-30T21:20:57.1566728Z",
        "Scope": "local",
        "Driver": "null",
        "EnableIPv6": false,
        "IPAM": {
            "Driver": "default",
            "Options": null,
            "Config": []
        },
        "Internal": false,
        "Attachable": false,
        "Ingress": false,
        "ConfigFrom": {
            "Network": ""
        },
        "ConfigOnly": false,
        "Containers": {
            "cc97a9e8a72c3dea175d9b48ca7eb0f7287747fd37bb295a2fa418e052265238": {
                "Name": "k8s_POD_wintcpserver_default_b744ebe3-d4a9-4ba9-a70e-42b76dcb7793_0",
                "EndpointID": "6bd2a32e90fe0aa5dacb3254ff48bb2e977ac363fb0c0a7548c842692a05dd2b",
                "MacAddress": "",
                "IPv4Address": "",
                "IPv6Address": ""
            },
            "ef97202f4612748842efd3575468bf0c0d0cf5b6c65cf0270a22aab889bd7d72": {
                "Name": "k8s_POD_wintcpclient_default_681efd58-eb02-4a74-a093-cf9b6e8a9c76_0",
                "EndpointID": "af97fe8565a70aeabde55c9b59baa601875b790413f7e5a820c28aafbbeb29d7",
                "MacAddress": "",
                "IPv4Address": "",
                "IPv6Address": ""
            }
        },
        "Options": {},
        "Labels": {}
    }
]
```

### Azure CNI in Action

The last piece in the puzzle is actually seeing HOW the vEthernet is created and attached. This is where Azure CNI is orchestrating all of what we've seen to this point. 

We know that Windows clusters require Azure CNI, so pretty confident that we're using Azure CNI here. However, if you really want to see it, you can take a look at ```C:\k\kubeclusterconfig.json```.

```powershell
cat kubeclusterconfig.json
{
...
    "Cni":  {
            "Plugin":  {
                        "Name":  "bridge"
                       },
            "Name":  "azure"
            }
...
```

If you look further through the ```C:\k``` directory you'll also see the azure-vnet-ipam.json and azure-vnet-ipam.log files. Looking at these, we can see not only the IPs that have been bound to the node, which will be used by the IPAM provider to assign pods their IP, but we can see the actual log of this process.

Take some time to scan through these files. Here are a few snippets worth highligting:

```
# Starting up
##########################
2021/12/01 20:06:17 [5460] [ipam] Starting source azure.
2021/12/01 20:06:17 [5460] [ipam] Refreshing address source.
2021/12/01 20:06:17 [5460] [Utils] Initializing HTTP client with connection timeout: 10, response header timeout: 10
2021/12/01 20:06:17 [5460] [ipam] Wireserver call http://168.63.129.16/machine/plugins?comp=nmagent&type=getinterfaceinfov
1 to retrieve IP List
2021/12/01 20:06:17 [5460] [ipam] got 30 addresses from interface vEthernet (Ethernet 2), subnet 10.240.0.0/16
2021/12/01 20:06:17 [5460] [ipam] merging address space
2021/12/01 20:06:17 [5460] [ipam] saving ipam state.
2021/12/01 20:06:17 [5460] [ipam] Save succeeded.
##########################

# Adding an interface
##########################
2021/12/01 20:07:26 [6072] [cni-ipam] Processing ADD command with args {ContainerID:75943f4753e0e8f88785f7796709f6947b19ef
c5d98d3c0ee0da6ebd6aa732f6 Netns:none IfName:eth0 Args:IgnoreUnknown=1;K8S_POD_NAMESPACE=default;K8S_POD_NAME=wintcpclient
;K8S_POD_INFRA_CONTAINER_ID=75943f4753e0e8f88785f7796709f6947b19efc5d98d3c0ee0da6ebd6aa732f6 Path:c:\k\azurecni\bin StdinD
ata:{"cniVersion":"0.3.0","name":"azure","type":"azure-vnet","mode":"bridge","bridge":"azure0","ipam":{"type":"azure-vnet-
ipam","subnet":"10.240.0.0/16"},"dns":{"nameservers":["10.0.0.10","168.63.129.16"],"search":["svc.cluster.local"]},"runtim
eConfig":{"dns":{"servers":["10.0.0.10"],"searches":["default.svc.cluster.local","svc.cluster.local","cluster.local"]
##########################

# Removing and interface
##########################
2021/12/01 20:06:17 [5460] [ipam] Releasing address with address:10.240.0.72 options:map[azure.address.id:7c930f38afb6347a
792e727874f45ee54394bbe368e5d4c94c9e91d0dbfe589b].
2021/12/01 20:06:17 [5460] [ipam] Address release completed with address:10.240.0.72 err:<nil>.
2021/12/01 20:06:17 [5460] [ipam] saving ipam state.
2021/12/01 20:06:17 [5460] [ipam] Save succeeded.
2021/12/01 20:06:17 [5460] [cni-ipam] DEL command completed with err:<nil>. 
##########################
```

### azure0 bridge

Looking through the above, we can see Azure CNI and the IPAM services identifying available IPs and then assigning them. We can also see that this is done in 'bridge' network mode using a bridge called 'azure0'. This actually matches what we've seen in the past with Linux networking in AKS. 

Lets have a look at the bridge network.
