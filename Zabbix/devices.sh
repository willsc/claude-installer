#!/bin/bash
# Extract hosts, devices, and mount points from Zabbix

# Get disk devices (vfs.dev.util)
curl -s --request POST \
  --url 'http://zabbix.ldn.pulsar.org/zabbix/api_jsonrpc.php' \
  --header 'Content-Type: application/json-rpc' \
  --header 'Authorization: Bearer 91799d0021ad77a85977c9daf2634a2613462995c8d301eadedfcb86f15aaa57' \
  --data '{
    "jsonrpc": "2.0",
    "method": "item.get",
    "params": {
      "search": { "key_": "vfs.dev.util" },
      "output": ["key_"],
      "selectHosts": ["host"]
    },
    "id": 1
  }' > /tmp/devices.json

# Get mount points (vfs.fs.size)
curl -s --request POST \
  --url 'http://zabbix.ldn.pulsar.org/zabbix/api_jsonrpc.php' \
  --header 'Content-Type: application/json-rpc' \
  --header 'Authorization: Bearer 91799d0021ad77a85977c9daf2634a2613462995c8d301eadedfcb86f15aaa57' \
  --data '{
    "jsonrpc": "2.0",
    "method": "item.get",
    "params": {
      "search": { "key_": "vfs.fs.size" },
      "output": ["key_"],
      "selectHosts": ["host"]
    },
    "id": 2
  }' > /tmp/mounts.json

# Combine and tabulate
jq -r -s '
  # Extract devices
  (.[0].result // [] | map({
    host: .hosts[0].host,
    device: (.key_ | capture("vfs\\.dev\\.util\\[(?<dev>[^\\]]+)") | .dev // "unknown")
  }) | group_by(.host) | map({host: .[0].host, devices: [.[].device] | unique})) as $devices |
  
  # Extract mount points
  (.[1].result // [] | map({
    host: .hosts[0].host,
    mount: (.key_ | capture("vfs\\.fs\\.size\\[(?<mp>[^,\\]]+)") | .mp // "unknown")
  }) | group_by(.host) | map({host: .[0].host, mounts: [.[].mount] | unique})) as $mounts |
  
  # Merge by host
  ($devices + $mounts | group_by(.host) | map({
    host: .[0].host,
    devices: (map(.devices // []) | add | unique // []),
    mounts: (map(.mounts // []) | add | unique // [])
  })) |
  
  # Output as table
  ["HOST", "DEVICES", "MOUNT_POINTS"],
  (.[] | [.host, (.devices | join(", ")), (.mounts | join(", "))]) |
  @tsv
' /tmp/devices.json /tmp/mounts.json | column -t -s $'\t'

# Cleanup
rm -f /tmp/devices.json /tmp/mounts.json
```

**Example output:**
```
HOST              DEVICES         MOUNT_POINTS
server1.example   sda, sdb        /, /var, /home, /data
server2.example   sda, nvme0n1    /, /var, /opt
db-server         sda, sdb, sdc   /, /var, /data/mysql
