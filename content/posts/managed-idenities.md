---
title: Quick One - Managed Idenities for Azure Resources
date: 2018-11-14T15:57:09-05:00
lastmod: 2018-11-14T15:57:09-05:00
cover: "/images/default1.jpg"
draft: true
categories: ["category1"]
tags: ["tag1", "tag2"]
description:
---
# Overview
Ok, so we all know that passing around credentials all whilly nilly is a bad idea. Most operators that have been around the block would just as soon have no idea what the credentials are for integrated systems and databases if they can avoid it, as nobody wants the finger pointed at them if something is broken or even worse stolen.


'''xml
  <connectionStrings>
    <add name="Jabbr" connectionString="Server=tcp:<DBSERVERNAME>.database.windows.net,1433;Database=<DBNAME>;" providerName="System.Data.SqlClient" />
    
  </connectionStrings>
  <appSettings>
    <!--Managed Identity Settings-->
    <add key="jabbr:useDBManagedIdentity" value="true" />
    <add key="jabbr:dbManagedIdentityClientID" value="<Managed Identity Client ID>" />
'''