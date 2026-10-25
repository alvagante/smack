# System Monitor

A lightweight macOS utility for inspecting system-wide and per-application resource usage and activity.

## Language

**Application**:
A user-facing macOS program that may own one or more processes.
_Avoid_: App process

**Process**:
An individual running program instance, including application helpers, background services, and command-line tools.
_Avoid_: Application, task

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
