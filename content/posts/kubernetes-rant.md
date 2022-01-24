---
title: "Kubernetes Rant"
date: 2021-02-05T15:36:47-05:00
draft: true
categories: ["Azure", "Kubernetes", "Development", "AKS"]
tags: ["azure", "kubernetes", "development"]
---

# The untitled Kubenetes future rant

Ok, I've been thinking about this a lot for the last year, and its time to get my thoughts down so that people can tell me how wrong I am. First of all, a little bit about myself. 

I spent the first 12-13 years of my career working for Accenture where I had many roles, but all focused on developing software for customers in the Insurance space. The team I was with built Accenture Claim Components, which was sold as Customizable Off the Shelf software, although in the earlier days it was customizable mostly by code changes. I eventually moved from customer delivery to the engineering team where I moved my way up through Architecture engineering until I was the Architecture Engineering Lead on the Claims side, building the underlying architecture services (authentiation, authorization, transactions, etc) that ran the platform. I then took over as the Engineering Lead for the Duck Creek OnDemand platform (Accenture Aquired Duck Creek and rebranded the ovearall offering). I kept that role, and was also given the title of Infrastructure Technology and Infrastructure Services (IT & IS) lead...cuz if you're running the cloud platform you should also run IT & IS....right?!?!

Eventually I moved away from Accenture/Duck Creek, looking to shift from an exec career track over to an individual contributor role where I felt I could get more hands on with technology. I made the jump over to Microsoft where I worked as a Cloud Solutions Architect for about 3-4 years, helping customers develop solutions on Azure. Finally, after focusing on Kubneretes for a while, I made the transition over to the Cloud Native Global Black Belt team, where I sit now. In this role I get to help customers architect 'Cloud Native' solutions (I know...very loaded term)...which largely translates to helping design solutions on Kubernetes using Azure.

Now that you know a bit about where I came from, hopefully you can see that I have what you might consider a unique background to share opinions on the state of Kubernetes and it's future. By unique I mean that I have years of experience in consulting, application architecture (Windows & .Net Framework primarily...but we'll get to that), infrastructure, running a Software as a Service, and designing and delivering production solutions on Kubernetes. Hopefully that qualifies me, but honestly...like the rest of you I have imposter syndrome that I fight every day.

## Current State

I'll keep this short, because I think most of you reading this have at least some sense of where Kubernetes is today. Fundamentally, Kubernetes is at the point where it's arguably reached a good level of maturity, the ecosystem is robust and most organizations around the world are using it or looking at it to host their applications. I say the ecosystem is robust...but it's also a complete mess. There are 10-20 solutions to most of your cross cutting concerns, which is daunting to anyone trying to build a production solution. This is where the 'Managed' services come into play. AKS, EKS, GKE, OpenShift, Tanzu, Rancher, etc, etc, etc....are all trying to take away some of the headache of building and managing Kubernetes clusters. Each solution has a varying degree of out of the box features to help address those above mentioned cross cutting concerns. 

