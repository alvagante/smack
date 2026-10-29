# System Monitor

A lightweight macOS utility for inspecting system-wide and per-application resource usage and activity.

## Language

**Application**:
A user-facing macOS program that may own one or more processes.
_Avoid_: App process

**Process**:
An individual running program instance, including application helpers, background services, and command-line tools.
_Avoid_: Application, task

**Program**:
In Historical Data, every process instance sharing a process name, summarized and charted together; one instance can still be picked.
_Avoid_: Application (which is user-facing and owns processes), process group

**Background Process**:
A process that is not presented as a user-facing application.
_Avoid_: Background application

**Background Collection**:
Metric sampling performed while the monitoring panel is not visible, according to user-configured intervals.
_Avoid_: Background usage

**Historical Data**:
Previously collected metric samples retained for later inspection, including across application restarts.
_Avoid_: Live data, history log

**Disk Activity**:
The rate at which the system or a process reads and writes data.
_Avoid_: Disk usage, storage usage

**Storage Capacity**:
The total, used, and available space on a storage volume.
_Avoid_: Disk activity, disk usage

**Thermal State**:
The system's coarse thermal-pressure classification: nominal, fair, serious, or critical. It is not a temperature measurement.
_Avoid_: Temperature, thermal level

**Standard Sampling**:
Process metrics collected by the app with the current user's visibility.
_Avoid_: Normal mode, unprivileged mode

**Superuser Sampling**:
Process metrics collected through the optional root helper, which includes processes owned by other users.
_Avoid_: Admin mode, root mode

**Privileged Helper**:
A separately signed root daemon that exposes one read-only sampling operation over XPC and is registered through `SMAppService`.
_Avoid_: Root process, agent

**Startup Item**:
Anything macOS starts without the user opening it: Open at Login apps, app-registered background items, launch agents and daemons, and cron jobs. Disabling one changes only the next login or boot.
_Avoid_: Login item (which is one kind), autorun

**Distribution Flavor**:
A build variant with a fixed set of capabilities: the direct Developer ID build or the sandboxed App Store build.
_Avoid_: Edition, version
