# Customer Deployment Plan

Deploy nodes in this exact order:

1. `CTRL1` (primary)
2. `CTRL2` (standby)
3. `BRAIN1`
4. `BRAIN2`
5. `EDGE1`
6. `EDGE2`

## Method A: Per-node installer

On each VM after transferring and extracting the installer bundle:

```bash
sudo bash node-init.sh
```

Select the correct role during prompts (`ctrl`, `ctrl-standby`, `brain`, `edge`).

## Method B: Central wizard + deploy

From a management host with SSH access to all nodes:

```bash
./aetheria-setup wizard
./aetheria-setup deploy
```

## Mandatory checkpoint

After `CTRL2` install, verify replication before continuing:

```bash
docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list
```

Proceed only when CTRL2 appears as `Replica` with lag `0`.
