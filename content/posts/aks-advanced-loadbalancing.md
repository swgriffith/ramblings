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
