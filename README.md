<h1 align="center">GNU Guix Automated Installation</h1>
<p align="center">
  <b>In Code We Trust ⚙️ | Simplified Guix System Setup</b>
</p>

---

## 📖 Overview

This project provides an automated installation script for **GNU Guix**, designed to simplify and speed up the setup process on new systems.

The `install.sh` script:
- Automatically fixes and updates your `/mnt/etc/config.scm`
- Adds required `(nongnu packages …)` and `(kernel …)` entries
- Downloads and applies your `channels.scm`
- Initializes your Guix system via `guix time-machine`
- Reboots automatically when finished  

Perfect for custom or reproducible Guix installations!

---

## 🧰 Files

| File | Description |
|------|--------------|
| `install.sh` | Main installation script |
| `channels.scm` | Custom Guix channel list |
| `config.scm` | System configuration file |
| `screenshots/*.png` | Step-by-step installation screenshots |

---

## ⚙️ Usage

> 🧩 **Prerequisite:**  
   - Install GNU GUIX from [here](https://github.com/SystemCrafters/guix-installer/releases/download/v202412150202/guix-installer-202412150202.iso)
   - Burn into your USB flash drive 
       - From Microsoft Windows i recommend [Balena Etcher](https://github.com/balena-io/etcher/releases/download/v2.1.4/balenaEtcher-2.1.4.Setup.exe) 
       - From Linux:  sudo dd if=guix-installer-202412150202.iso of=/dev/sdX status=progress
     >   [!] Remember to adjust the sdX based on your usb drive! Do you can check the correct name using lsblk command.
   - Boot from the USB flash drive
   - Follow the installation process
   - At this [moment](#attention!) do you need press ctrl + alt + F3
   - Download the script:
           wget https://short.securityops.co/install -O install.sh
   - Turn executable:
           chmod +x install.sh
   - Just run:
           ./install.sh
   - DONE!


The script will:

    -Patch your /mnt/etc/config.scm

    -Fetch your based-channels.scm

    -Initialize Guix with your configuration

    -Automatically reboot when complete

## 🖼️ Installation Screenshots

Follow the visual guide below to see each step of the installation process.
<p align="center"><img src="screenshots/1.png" width="50%"></p> 
<p align="center"><img src="screenshots/2.png" width="50%"></p> 
<p align="center"><img src="screenshots/3.png" width="50%"></p> 
<p align="center"><img src="screenshots/4.png" width="50%"></p> 
<p align="center"><img src="screenshots/5.png" width="50%"></p> 
<p align="center"><img src="screenshots/6.png" width="50%"></p> 
<p align="center"><img src="screenshots/7.png" width="50%"></p> 
<p align="center"><img src="screenshots/8.png" width="50%"></p> 
<p align="center"><img src="screenshots/9.png" width="50%"></p> 
<p align="center"><img src="screenshots/10.png" width="50%"></p> 
<p align="center"><img src="screenshots/11.png" width="50%"></p> 
<p align="center"><img src="screenshots/12.png" width="50%"></p> 
<p align="center"><img src="screenshots/13.png" width="50%"></p>
<p align="center"><img src="screenshots/14.png" width="50%"></p> 
<p align="center"><img src="screenshots/15.png" width="50%"></p> 
<p align="center"><img src="screenshots/16.png" width="50%"></p> 
<p align="center"><img src="screenshots/17.png" width="50%"></p> 
<p align="center"><img src="screenshots/18.png" width="50%"></p>
<p align="center"><img src="screenshots/19.png" width="50%"></p>
<p align="center"><img src="screenshots/20.png" width="50%"></p> 
<p align="center"><img src="screenshots/21.png" width="50%"></p> 
<p align="center"><img src="screenshots/22.png" width="50%"></p>
<p align="center"><img src="screenshots/23.png" width="50%"></p> 
<p align="center"><img src="screenshots/24.png" width="50%"></p> 

## ATTENTION!
  - At this moment do you need press CTRL + ALT + F3
<p align="center"><img src="screenshots/25.png" width="50%"></p>

## Download the script and run
    
    wget https://short.securityops.co/install -O install.sh
    chmod +x install.sh
    ./install.sh    

<p align="center"><img src="screenshots/end.png" width="50%"></p>

## Welcome to GNU GUIX Universe! Have a nice day! Enjoy!  :)

📜 License — GNU GPL v3

    Copyright (C) 2025 Cristian Cezar Moisés
