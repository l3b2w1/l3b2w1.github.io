---
layout:     post
title:      wpa/wpa2 四步握手过程
subtitle:   wireless dictionary brutal hacking
date:       2019-10-05
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - wpa
    - wireless
    - hack
    - aircrack-ng

---
## 缩略词
* PTK&emsp;&emsp;Pairwise Transient Key
* MIC&emsp;&emsp;Message Integrity Check
* PRF&emsp;&emsp;Pseudo Random Function         
* AA&emsp;&emsp;Authenticator’s MAC Addresses
* SA&emsp;&emsp;Supplicant’s MAC Addresses
* Nonce&emsp;&emsp;Number used once
* KCK&emsp;&emsp;Key Confirmation Key
* KEK&emsp;&emsp;Key Encryption Key
* TK&emsp;&emsp;Temporal Key
* GTK&emsp;&emsp;Groupwise Temporal Key         
    &emsp;&emsp;&emsp;&emsp;used for encrypting broadcast and multicast packets
* PMK&emsp;&emsp;Pairwise Master Key       
    &emsp;&emsp;&emsp;maybe passphrase for WPA-PSK or a key derived from the EAP process for WPA-802.1X or WPA-Enterprise

---
## key生成算法
1. Pairwise Temporal Key Generation   
    `PTK = PRF(PMK + ANonce + SNonce + AA + SA)`
2. MIC-KEY        取这个PTK 前16 个字节组成MIC-KEY
3. 用这个MIC KEY 和一个802.1x data 数据帧使用以下算法得到MIC值
    `MIC = HMAC_MD5(MIC Key, 16, 802.1x data)`
4. The GTK itself is given in the WPA Key Data field, secured/encrypted with the PTK.

## Key的用途
Once generated, the PTK is split into a Key Confirmation Key (KCK), Key Encryption Key (KEK), and Temporal Key (TK).

The KCK and KEK are used to protect handshake messages, while the TK is used to protect normal data frames with a data-confidentiality protocol.

If WPA2 is used, the 4-way handshake also transports the current Group Temporal Key (GTK) to the supplicant.

![](https://github.com/l3b2w1/l3b2w1.github.io/tree/master/img/1-supp-auth-2.jpeg)

---
## 四步握手认证过程
The four phases of the authentication process are as follows:
1. In the first phase, a 256 bit Pairwise Master Key (PMK) is independently established by both parties.
    It is generated from the PSK and the network SSID. Then the AP sends a random number, the A-Nonce, to the client.
2. The client sends a random S-Nonce to the AP, plus a Message Integrity Code (MIC).
    Meanwhile, the client computes a Pairwise Transient Key (PTK) that will be used to encrypt the traffic.
    The PTK is derived from the PMK, the A-Nonce, the S-Nonce, and the MAC addresses of both the client and the AP.
3. The AP derives the PTK itself and then sends to the client a Group Temporal Key (GTK), used to decrypt multicast and broadcast traffic, and a MIC.
4. The client sends an acknowledgement to the AP.

## 重放计数 replay counter[EAPOL Frame]
The replay counter field is used to detect replayed frames. The authenticator always increments the replay counter after transmitting a frame.
When the supplicant replies to an EAPOL frame of the authenticator, it uses the same replay counter as the one in the EAPOL frame it is responding to

## WPA/WPA2 PSK 工作原理
The way WPA/WPA2 PSK works is that, it derives the per-sessions key called Pairwise Transient Key (PTK),using the Pre-Shared Key and five other parameters:

1. SSID of Network,
2. Authenticator Nounce (ANounce),
3. Supplicant Nounce (SNounce),
4. Authenticator MAC address (Access Point MAC),
5. Suppliant MAC address (Wi-Fi Client MAC).

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/1-sta-ap.jpeg)

This key is then used to encrypt all data between the access point and client.

An attacker who is eavesdropping on this entire conversation, by sniffing the air can get all the five parameters mentioned in the previous paragraph.
**The only thing he does not have is the Pre-Shared Key.**

So how is the Pre-Shared Key created? It is derived by using the WPA-PSK passphrase supplied by the user, along with the SSID.

The combination of both of these are sent through the Password Based Key Derivation Function (PBKDF2), which outputs the 256-bit shared key.

* In a typical WPA/WPA2 PSK dictionary attack, the attacker would use a large dictionary of possible passphrases with the attack tool.
* The tool would derive the 256-bit Pre-Shared Key from each of the passphrases and use it with the other parameters, described afore said to
create the PTK.
* The PTK will be used to verify the Message Integrity Check (MIC) in one of the handshake packets. If it matches, then the guessed passphrase from the dictionary was correct, otherwise it was incorrect.
* Eventually, if the authorized network passphrase exists in the dictionary, it will be identified.

**This is exactly how WPA/WPA2 PSK cracking works!**

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/1-dictionary-hacking.jpeg)


**One of the more CPU and time-consuming calculations is that of the Pre-Shared Key using the PSK passphrase and the SSID through the PBKDF2.**

* This function hashes the combination of both over 4096 times before outputting the 256 bit Pre-Shared Key.
* The next step of cracking involves using this key along with parameters in the four-way handshake and verifying against the MIC in the handshake.
This step is computationally inexpensive.
Also, the parameters will vary in the handshake everytime and hence, this step cannot be pre-computed.

**Thus to speed up the cracking process we need to make the calculation of the  Pre-Shared Key from the passphrase as fast as possible.**

**We can speed this up by pre-calculating the Pre-Shared Key, also called the Pairwise Master Key (PMK) in the 802.11 standard parlance.**

It is important to note that, as the SSID is also used to calculate the PMK, with the same passphrase but a different SSID,
we would end up with a different PMK. Thus, the PMK depends on both the passphrase and the SSID.

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/1-hackit.jpeg)

[链接](http://calc.opensecurityresearch.com/)
