---
title: Setting up Google Titan Security Keys on Arch Linux
date: 2018-12-19T10:42:47-05:00
lastmod: 2018-12-19T10:42:47-05:00
cover: "/titan-key-arch/githuberror.png"
draft: true
categories: ["security"]
tags: ["google", "arch", "linux", "linux", "u2f", "FIDO", "titan", "security key"]
description:
---
# Overview
I recently decided to give [Google Advanced Protection](https://landing.google.com/advancedprotection/) a shot. For those not aware, Advanced protection is Google's first party U2F authentication system. In short, you purchase the [Titan Security Bundle](https://store.google.com/us/product/titan_security_key_kit?hl=en-US) from Google, which includes two physical keys. One is a standard USB U2F key and the second is a bluetooth key. I decided to try this over YubiKey for no good reason, other than the fact that with Google behind it I assume it will pick up extensively. In hindsight, the ecosystem and support around YubiKey is more advanced. For example, my password manager still [does not support](https://lastpass.com/support.php?cmd=showfaq&id=8126) FIDO/U2F. Hopefully it will in the future, but we'll see. I may end up buying a yubikey as well. 

## Problem!
So on my windows side the Titan keys worked right away without any issue. However, on my Arch Linux box I immediately ran into issues where the browser seemed to not see the key and raise an error that either "Something went really wrong" (GitHub) or "Incorrect response. Please try again." (Twitter). 

![GitHub Error](/titan-key-arch/githuberror.png)
![Twitter Error](/titan-key-arch/twittererror.png)

A quick search returned the [this](https://support.google.com/titansecuritykey/answer/9148044?hl=en) article from Google on linux setup, however thse steps did not work. When I checked dmesg after plugging in my key I could see that the vendor and product id's did not match what google provided, as you can see below. 

```
#Google Provided udev rule
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="5026", TAG+="uaccess"
```

```
#Actual from dmesg
usb 2-6.4: new full-speed USB device number 14 using xhci_hcd
usb 2-6.4: New USB device found, idVendor=096e, idProduct=085b, bcdDevice=32.10
usb 2-6.4: New USB device strings: Mfr=1, Product=2, SerialNumber=0
usb 2-6.4: Product: ePass FIDO
usb 2-6.4: Manufacturer: FS
hid-generic 0003:096E:085B.000F: hiddev2,hidraw4: USB HID v1.10 Device [FS ePass FIDO] on usb-0000:00:14.0-6.4/input0
```
## The fix
So initially I set up my own udev rules and that seemed to work for one device, but I had an issue with my second key. In searching for that fix I came across [this](https://support.yubico.com/support/solutions/articles/15000006449-using-your-u2f-yubikey-with-linux) document from YubiKey...and when I checked the udev rules file they provided it actually included the Feitian FIDO/U2F product id and codes. A few commands later, I was up and running with both keys. 

```
#Go to the udev rules folder
cd /etc/udev/rules.d

#Pull down the file from the yubikey github
sudo wget https://raw.githubusercontent.com/Yubico/libu2f-host/master/70-u2f.rules

#Reboot, or run the following to reload your rules
sudo udevadm control --reload
```

## Conclusion
So far this seems to have address all of my issues. I presume this will resolve across most linux distros. Hopefully this helps others!