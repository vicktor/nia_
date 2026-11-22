# Nia Remote v0.5.0 — SSH + tmux (experimental)

## Goal

Work on MacBook in a shell that **runs on Mac Studio**. Processes, filesystem,
Python environments, CPU and RAM are on the Studio. Nia is the SSH terminal client.
No cloud server or custom encryption service is involved.

## Prepare the Studio (trusted machine)

1. Enable macOS **System Settings → General → Sharing → Remote Login** for your account.
2. Install `tmux`: `brew install tmux`.
3. Set up a dedicated SSH key and restrict who can log in. For example,
   generate an Ed25519 key on MacBook (`ssh-keygen -t ed25519`) and add its
   *public* key to Studio's `~/.ssh/authorized_keys`.
4. Configure a trusted connection, for example using Tailscale or your VPN.
   Avoid exposing SSH openly to the internet. Verify the Studio's SSH host-key
   fingerprint from a trustworthy channel.
5. On MacBook test `ssh mac-studio` and `tmux -V` before creating a session.

Suggested `~/.ssh/config` on MacBook:

```
Host mac-studio
    HostName 100.101.102.103  # Replace with your verified VPN IP
    User YOUR_STUDIO_USER
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

In Nia click the **network icon** by New Session, choose a Nia session ID
(e.g. `listen-backend`) and the SSH alias (`mac-studio`). Nia opens:

```
ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=yes -- mac-studio tmux new-session -A -s nia-<hex-session-id>
```

The tmux name is derived from the Nia session ID so reconnecting uses the
same remote PTY, shell and running processes. If Nia closes, tmux keeps the
remote shell alive on Studio. Once the Studio itself reboots, its running
processes cannot be resurrected by SSH/tmux; only saved history and state survive.

## Security properties and boundaries

- Encryption and authentication are provided by **OpenSSH**, with strict host
  key verification and existing SSH keys / ssh-agent. No passwords or private
  keys are stored in Nia SQLite.
- This is encrypted between the SSH client and SSH server. It does **not**
  prevent a compromised Studio, compromised MacBook or another authorized tmux
  client from seeing terminal output. This is *transport E2E*, not an E2EE
  cloud-storage protocol, and is not independently security-audited.
- Nia captures the remote terminal output in **local logs**. These may include
  secrets. Protect local storage and your Nia backups accordingly.
- tmux needs to be installed on the destination. The session lives under the
  remote account; using the same session ID from two Macs reconnects to that
  named tmux session, but workspace metadata is **not yet auto-synced**.
- When an SSH key is not accepted or a host is unknown, Nia shows SSH's error
  within the terminal. It **never** disables host-key checking.

## Not included yet

Automatic bidirectional SQLite sync, device pairing, encrypted shared storage,
remote filesystem mounting, browser forwarding, and remote session status UI.
`nia-backup` / handoff is still the mechanism to move workspace metadata.

When the connection fails while Nia remains open, right-click that session and choose **Reconectar SSH**.
