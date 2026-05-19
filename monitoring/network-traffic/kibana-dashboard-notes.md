# Host Network Traffic Dashboard Notes

These logs are designed to answer one operational question quickly:

Which Raspberry Pi was moving unusual traffic when the home network became slow?

## Recommended panels

1. Line chart: `tx_bytes_delta` over time, split by `host_name`
2. Line chart: `rx_bytes_delta` over time, split by `host_name`
3. Formula line chart: `tx_bytes_delta / window_seconds` over time, split by `host_name`
4. Formula line chart: `rx_bytes_delta / window_seconds` over time, split by `host_name`
5. Table: max derived tx/rx bytes-per-second by `host_name`
6. Table: latest `interface` and `role` by `host_name`

## Useful filters

- `site: home`
- `host_name: pi5`
- `host_name: pi4`
- `host_name: pi3`
- `role: backup-node`
- `role: utility-node`

## Operational interpretation

- Large sustained `tx_bytes_delta` often means uploads, backups, or media streaming.
- Large sustained `rx_bytes_delta` often means downloads, updates, or inbound replication.
- `window_seconds` should remain close to the timer cadence; large gaps suggest missed runs or host sleep/restart.

## Suggested alert ideas

- Alert if any host exceeds a chosen `tx_bytes_per_second` threshold for 5 minutes.
- Alert if `operstate` is not `up` for a host that should be online.
- Alert if no samples arrive from a host for more than 10 minutes.