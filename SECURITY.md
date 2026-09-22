# Security and recovery boundaries

Public reports contain sanitized status and synthetic reproductions, not subscription URLs, credentials, environment values, private hostnames, raw Docker logs or network inventories. Diagnostics remove URI credentials, paths and query parameters; remote endpoints are represented without their hostnames.

Preview is not permission to apply against changed resources. Apply and undo compare recorded/current values. Process termination revalidates start time, executable path, session and listening ownership. Stopping an explicitly selected process can interrupt its other connections and cannot be undone by a settings journal.

The one-operation journal uses Windows current-user DPAPI. It is not a credential vault, transferable backup or defense against compromise of that same account. Preserve unfinished records for recovery; never delete them to make status green. Ambiguous Git configuration is preserved instead of rewritten through a guessed location.

The project does not silently alter PAC, WinHTTP, machine environment, Docker, remote proxies or Tailscale. Do not test network resets against an active remote-control path. Unknown discovery cannot prove a dead endpoint, missing route or successful repair. Report vulnerabilities with generated addresses, files and process fixtures; real credentials are unnecessary.
Client-level shutdown has a separate confirmation and exact process identities; normal window/service exit is attempted before a separately confirmed forced close. Service stop requests are limited to selected process ownership, name and executable path; startup configuration and dependent services are not force-modified. Multiple selected ports are cleaned in one journal only after closure is verified. Restarted clients, reused ports and preserved PAC/tunnels prevent an unconditional direct-connect claim.
