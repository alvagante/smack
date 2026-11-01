# Stability investigation, 2026-11-01

## Confirmed regression

Six installed 1.0.0 (build 10) crash reports on November 1 show the same SIGABRT:
20:31, 20:48, 21:35, 21:54, 22:28 and 23:00 local time.

The shared stack is:
CollectionScheduler.runNetworkPortLoop -> AgentSessionTracker.annotate ->
filter -> AgentSessionTracker.belongs -> swift_beginAccess ->
_swift_reportExclusivityConflict -> abort.

AgentSessions.swift was introduced by commit 6e8f189, after v0.7.0.

## Cause and trigger

annotate assigned directly to sessions[id]?.listeners and remoteHosts while
evaluating filters that call belongs. The dictionary subscript holds a modifying
access while the filter runs. When belongs must follow another session's parent,
it reads sessions again. Swift detects overlapping read/write access to the same
dictionary and aborts the entire application.

Multiple tracked sessions plus a listener or connection associated with another
session can trigger this. Nested agents are one deterministic example. This is
an access conflict within one actor invocation, without concurrent actor calls.

The network collector invokes this periodically, explaining exits after the
application has been running. The pre-existing annotation test has just one
session: belongs returns immediately for its owner, avoiding the dictionary read.

## Reproduction and fix

Added AgentSessionNetworkTests.swift using a Claude root, nested Codex session,
and a worker with a listener and remote connection. It calls the separate network
annotation entry point and the combined process-update entry point.

Before the fix:
swift test --filter nestedSessionNetworkAnnotationsDoNotOverlapDictionaryAccess
exited 1 after SIGABRT with "Fatal access conflict detected", matching the
installed application's stack. The test itself ran in milliseconds.

The fix computes listeners and remote hosts into locals before assigning either
to the dictionary. The regression test also runs without listeners to exercise
the remote-host assignment independently.

The patch is in the working tree. The installed application has not been replaced.

## Other reports

The October 31 report is from 0.7.0 and fails a main-executor assertion in
NativeMenuBarStore.relaunch's NSWorkspace completion callback. It is a separate,
action-specific failure, not the new periodic abort.

The November 1 21:12 report is from an unbundled Smack executable. It fails a
UNUserNotificationCenter startup assertion. It does not explain the recurring
installed-app crashes.

These other two signatures were inspected but not reproduced or changed here.

## Validation

- Before fix: regression test aborts with the same exclusivity-conflict stack.
- After fix: regression (two cases), existing network annotation and nested-session
  tests pass in both debug and optimized release configurations.
- Full debug suite: 471 tests reported, one issue in
  firstCPUSampleHasNoUsageAndLaterOnesDo (second.cpu.hasUsage).
  That CPU sampling test passes when rerun alone. The full suite is not
  unconditionally green; no CPU sampling changes were made for this patch.
- git diff --check passes.
