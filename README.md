# Proxmox ZFS + Samba NAS Setup (LXC)
A miniature LXC NAS system tested on unprivileged `Debian 12` container using `Proxmox VE 9.1.2`. Designed for homelabs and small trusted environments.

---
<img width="1919" height="645" alt="image" src="https://github.com/user-attachments/assets/541d7196-9bba-4ccf-ba9d-8b5adf6fb543" />
<img width="1919" height="632" alt="image" src="https://github.com/user-attachments/assets/5ab0573b-9afa-475d-9a68-f8d31ca3ef14" />
<p align="center">
  <img src="https://github.com/user-attachments/assets/f9d7c14b-e48b-49ce-9024-c1915a918824" width="400"/>
  <img src="https://github.com/user-attachments/assets/0c0f6b88-25d2-4e50-a471-7bbe57957e05" width="400" />
</p>

> ⚠️ Disclaimer  
> Built as a personal project and learning exercise, I'm no expert!
> Worked well for my use case, has been tested enough to be useful, but not enough for me to claim it won't cause a headache.
> Use at your own risk.

## TODO
- ~~Management Script for backups and snapshots~~
- Basic admin web panel
- ~~Recycle bin clean-up service~~

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

**Management Commnands**
> NOTE: From ROOT HOST -> `./nas-manage <CTID> <command>`
```bash
# Commands:
#   info      : layout, users, quotas (from /etc/nas/state.env)   # Information
#   smb       : backup | list | restore [file]                    # Config file backup
#   snapshot  : create | list | rollback <tag> | remove <tag>     # Snapshot management
#   recycle   : flush  | timer <d/h/m>                            # Recycle Bin flush
```

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

### Recycle Bin flush (OFF by default)
Run management command `./nas-manage <CTID> recycle timer <d/h/m>` to add automatic flush timer within the LXC container.

```bash
# This sets 4 hour cron timer
./nas-manage 103 recycle timer 4h
```

```bash
# Run this to clean recycle bins manually
./nas-manage 103 recycle flush
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
#### Select `Debian 12` Container, Mount Point, Storage Method
<img width="735" height="401" alt="image" src="https://github.com/user-attachments/assets/b0df7d43-4462-4bc6-aff6-752afd71087c" />

#### Select the ZFS pool
<img width="979" height="113" alt="image" src="https://github.com/user-attachments/assets/20b9d71e-fb60-4f24-b6e2-5766360491ed" />

#### Create new or select pre-allocated ZFS dataset
<img width="840" height="354" alt="image" src="https://github.com/user-attachments/assets/2bae87db-88d7-4a3b-bf22-92354a51152b" />

#### Select the shares you want to have
<img width="943" height="241" alt="image" src="https://github.com/user-attachments/assets/92f18383-f7c8-422b-b8e9-d11b88420134" />

#### Set Storage quota and reservation for shares
<img width="670" height="244" alt="image" src="https://github.com/user-attachments/assets/d2e632ac-4501-4ed1-82d7-59f4a8d2a24b" />

#### Set allowed Samba subnets, set the "WORKGROUP", and optionally enable the recycle bin
<img width="766" height="90" alt="image" src="https://github.com/user-attachments/assets/cb059ec8-ad61-416a-956e-e7800590a62f" />

#### Add/Edit your users, privileges and user quotas
<img width="740" height="288" alt="image" src="https://github.com/user-attachments/assets/3e87423f-d155-4d5d-b39e-126f0d1f3b6a" />
<img width="704" height="583" alt="image" src="https://github.com/user-attachments/assets/e587a3f6-2409-4291-88d6-0c8f1a01a264" />

#### Successful Install
<img width="1001" height="676" alt="image" src="https://github.com/user-attachments/assets/5884eb2a-a8ec-4640-907f-b7b9993b96e0" />
<img width="833" height="245" alt="image" src="https://github.com/user-attachments/assets/c23495e3-45ce-41b8-9897-d3358c96bb3a" />
