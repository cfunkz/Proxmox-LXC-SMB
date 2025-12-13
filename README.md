# Proxmox ZFS + Samba NAS Setup (LXC)
A miniature LXC NAS system tested on unprivileged `Debian 12` container using `Proxmox VE 9.1.2`. Designed for homelabs and small trusted environments.

---
<img width="1919" height="640" alt="image" src="https://github.com/user-attachments/assets/0a1cc889-8fc7-47ef-b2b4-60fbdd465e43" />
<img width="1919" height="666" alt="image" src="https://github.com/user-attachments/assets/d967d906-02c7-493d-a281-5d1b873fc23e" />
<p align="center">
  <img src="https://github.com/user-attachments/assets/1a51d254-a909-4480-a439-3a842e3ee657" width="400">
  <img src="https://github.com/user-attachments/assets/995c4831-3631-403f-878f-59dc16aee643" width="400">
</p>

> ⚠️ Disclaimer  
> Built as a personal project and learning exercise, I'm no expert!
> Worked well for my use case, has been tested enough to be useful, but not enough for me to claim it won't cause a headache.
> Use at your own risk.

## TODO
- ~~Management Script for backups and snapshots~~
- Basic admin web panel
- Recycle bin clean-up service

## Table of Contents
- [How Access Works](#how-access-works)
  - [Storage Method](#storage-method)
  - [Permissions](#permissions)
  - [Roles](#roles)
  - [Features](#features)
  - [Limitations](#limitations)
- [Installation](#installation)
- [Monolithic/Single Dataset Design](#monolithicsingle-dataset-design)
  - [Installation](#installation-1)
- [Individual Datasets mounted to the LXC](#individual-datasets-mounted-to-the-lxc)
  - [Installation](#installation-2)


## How Access Works
### Storage Method
- `Mode 1`: single ZFS dataset with subdirs: homes, (optional Shared, Public, Guest)
  - Faster initial setup
  - Snapshots single dataset

- `Mode 2`: per-user datasets (`homes/<user>), (optional Shared, Public, Guest datasets)
  - Allows per-user quotas (ZFS-native)
  - Enables snapshots per user if desired

### Permissions
- **Homes**: private.
- **Shared** (Optional): everyone can read; only owners can edit/delete.
- **Public** (Optional): everyone read; only `nas_public` + `nas_admin` can write.
- **Guest** (optional): read-only for guests, writable by `nas_admin`.

### Roles
- `nas_user` = Standard users; read access to all public shares, write access limited to their own home directory.
- `nas_admin` = Full administrative access; read, write, and modify all shares and user directories.
- `nas_public` = Users granted write permissions specifically for the Public share.

### Features
- Works with privileged and unprivileged LXC containers.
- Creates a complete mini NAS structure with Homes, optional Shared, Public, and Guest shares.
- Automatic ZFS dataset creation, quotas, mountpoints, permissions, and rollback on failure.
- Samba configuration with ACL passthrough and optional per-user recycle bins.
- Automated user, group, and Samba account provisioning.
- Netbios disabled.
- SMB2/SMB3.
- Saves state inside container at `/etc/nas/state.env` for easier post-install detection.
- `nas.sh` script re-runnable modifying quotas, creating users, changing passwords.
-  Backup and snapshot management script `nas-manage.sh` can be run via `./nas-manage <CTID> <command>` .

### Limitations
- Samba authentication is local-only (no AD/LDAP).
- Samba admins are effectively trusted users.
- Single-node design (no HA / clustering).
- No brute force mitigation, must install fail2ban.
- Must configure your firewalls manually.
- Changes are script-driven.

## Installation
> NOTE: **AS ROOT ON THE HOST NODE, NOT IN CONTAINER**
```bash
# Setup Script
wget -O nas https://raw.githubusercontent.com/cfunkz/Proxmox-LXC-SMB/main/nas.sh

# Backup script via `./nas-manage <CTID> info`
wget -O nas-manage https://raw.githubusercontent.com/cfunkz/Proxmox-LXC-SMB/main/nas-manage.sh

# Make executable
chmod +x nas-manage
chmod +x nas

# Run setup script
./nas
```

## Monolithic/Single Dataset Design
### Installation
#### Select Container, Container Mount Point, Storage Method
<img width="679" height="341" alt="image" src="https://github.com/user-attachments/assets/7fa02944-95bb-4095-b3c5-b12b090e3e48" />

#### Select ZFS pool
<img width="898" height="107" alt="image" src="https://github.com/user-attachments/assets/5f000816-a5ea-4f7a-94a0-8ebe549e88a5" />

#### Select existing or create **new** dataset for the monolithic method
<img width="760" height="283" alt="image" src="https://github.com/user-attachments/assets/4cc373ec-d6ff-4c71-89ae-751870188eee" />

#### Select the shares that you want and ZFS dataset quota
<img width="753" height="204" alt="image" src="https://github.com/user-attachments/assets/83b05b91-f277-4d46-9b14-869c062790f1" />

#### Select allowed subnets enforced by Samba, WORKGROUP and optional recycle bin
<img width="693" height="61" alt="image" src="https://github.com/user-attachments/assets/1dfd7250-bd08-4f47-9de1-ef77a7a0891c" />

#### Add the initial users with permissions
<img width="570" height="179" alt="image" src="https://github.com/user-attachments/assets/f9342ed4-8544-48e7-849e-434e1a1065d4" />

#### Complete
<img width="931" height="594" alt="image" src="https://github.com/user-attachments/assets/febbd808-c110-4e7b-962d-fc8eefbfea02" />
<img width="609" height="65" alt="image" src="https://github.com/user-attachments/assets/bfa37bd3-3aa0-4cd9-bf58-b42911357720" />


## Individual Datasets mounted to the LXC
### Installation
#### Select Storage Method
<img width="667" height="137" alt="image" src="https://github.com/user-attachments/assets/d1978c56-6d35-4562-aa37-961cae671ca8" />

#### Select the container with `Debian 12`, set the mount point
<img width="504" height="261" alt="image" src="https://github.com/user-attachments/assets/485d656b-caa3-48d9-a9dc-ce5c1af5847a" />

#### Select the ZFS pool
<img width="883" height="99" alt="image" src="https://github.com/user-attachments/assets/4ac4355c-032b-4620-aedf-806b4a174d47" />

#### Create new or select pre-allocated ZFS dataset
<img width="753" height="320" alt="image" src="https://github.com/user-attachments/assets/84ad4ff4-d69b-430c-984f-1dd03e20414a" />

#### Select the shares you want to have
<img width="727" height="221" alt="image" src="https://github.com/user-attachments/assets/bbab7de3-34f1-4d90-92a7-da9a2e3801b5" />

#### Set Storage Quotas for shares
<img width="649" height="219" alt="image" src="https://github.com/user-attachments/assets/dcde5e8f-9dd6-4858-a44f-fa7c49ac174d" />

#### Set allowed Samba subnets, set the "WORKGROUP", and optionally enable the recycle bin
<img width="695" height="81" alt="image" src="https://github.com/user-attachments/assets/7249402b-b6db-4412-8c3e-d1995f1ae9a7" />

#### Add your users, privileges and quotas
<img width="728" height="258" alt="image" src="https://github.com/user-attachments/assets/e1f10228-8605-4907-8e79-e38988b1212c" />

#### Successful Install
<img width="1067" height="563" alt="image" src="https://github.com/user-attachments/assets/b7da3a01-ddae-4814-8154-85e3f04b09ab" />
<img width="810" height="204" alt="image" src="https://github.com/user-attachments/assets/dbda6019-929a-4f0e-81f7-5b5890a1d5ad" />
