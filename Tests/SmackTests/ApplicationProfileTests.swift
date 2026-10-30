import Foundation
import Testing
@testable import Smack

// Trimmed from real output of the tools on macOS 26.

private let footprintOutput = """
======================================================================
Finder [668]: 64-bit    Footprint: 185 MB (16384 bytes per page)
======================================================================

  Dirty      Clean  Reclaimable    Regions    Category
    ---        ---          ---        ---    ---
  80 MB        0 B       2 MB          8    MALLOC_SMALL
  13 MB        0 B          0 B        388    CoreAnimation
 336 KB        0 B          0 B          8    MALLOC metadata
    0 B      16 KB          0 B         46    __TEXT
    ---        ---          ---        ---    ---
 185 MB     48 KB       2 MB        361    TOTAL

Auxiliary data:
    phys_footprint: 185 MB
    phys_footprint_peak: 503 MB
"""

private let vmmapOutput = """
Physical footprint:         185.1M
Physical footprint (peak):  503.4M
Idle exit:                  untracked
----

Writable regions: Total=325.2M written=120.3M(37%) resident=185.2M(57%) swapped_out=12M(1%) unallocated=140.0M(43%)

                                   VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION
REGION TYPE                           SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced)
===========                        ======= ========    =====  ======= ========   ======    =====  =======
AttributeGraph Data (old mapping)    1024K    1024K    1024K       0K       0K       0K       0K        1
CoreAnimation                        13.5M    13.4M    13.4M       0K       0K    7840K       0K      388
Foundation                           46.8M    46.7M    46.7M      12M       0K     192K       0K       13
dyld private memory                   160K       56       56       0K       0K       0K       0K        4
===========                        ======= ========    =====  ======= ========   ======    =====  =======
TOTAL                               806.1M   114.3M     960K       0K       0K       0K       0K      261

                                 VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION
MALLOC ZONE                         SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT
DefaultMallocZone_0x102770000      12.8M       384K       384K         0K        183        11K       373K     98%       5
"""

private let heapOutput = """
Process 668: 7 zones

All zones: 784045 nodes malloced - Sizes: 2000KB[2] 352KB[6]

Found:  3037 ObjC classes  1247 Swift classes  266 C++ classes  325 CFTypes

-----------------------------------------------------------------------
All zones: 784045 nodes (89242958 bytes)

   COUNT      BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
   =====      =====       ===   ==========                                        ====    ======
  190395   32657755     171.5   non-object
   92515    4985792      53.9   CFString                                          ObjC    CoreFoundation
   14050    2248000     160.0   std::__shared_ptr_emplace<TFSInfo>                C++     DesktopServicesPriv
"""

private let leaksOutput = """
leaks Report Version: 4.0
Process 668: 784065 nodes malloced for 87164 KB
Process 668: 1 leak for 32 total leaked bytes.

    1 (32 bytes) ROOT LEAK: 0xd3c1ac180 [32]

Process 668 is not debuggable. Due to security restrictions, leaks can only show or save contents of readonly memory of restricted processes.
"""

private let sampleOutput = """
Call graph:
    1764 Thread_233084   DispatchQueue_1: com.apple.main-thread  (serial)

Total number in stack (recursive counted multiple, when >=5):

Sort by top of stack, same collapsed (when >= 5):
        __semwait_signal  (in libsystem_kernel.dylib)        882
        mach_msg2_trap  (in libsystem_kernel.dylib)        118

Binary Images:
       0x1022ec000 -        0x1022eca03 +sleep (329) <4AEDF2CC> /bin/sleep
"""

@Test func profileSizesParseAllToolNotations() {
    #expect(ProfileParser.bytes("336 KB") == 336 * 1024)
    #expect(ProfileParser.bytes("0 B") == 0)
    #expect(ProfileParser.bytes("64.0M") == 64 * 1024 * 1024)
    #expect(ProfileParser.bytes("56") == 56)
    #expect(ProfileParser.bytes("garbage") == nil)
}

@Test func footprintHighlightsTotalPeakAndLargestDirtyCategories() {
    let highlights = ProfileParser.highlights(for: .footprint, output: footprintOutput)
    #expect(highlights.first?.value == "185 MB")
    #expect(highlights.contains { $0.label == "Peak footprint" && $0.value == "503 MB" })
    let dirty = highlights.filter { $0.label.hasPrefix("Dirty:") }
    #expect(dirty.first?.label == "Dirty: MALLOC_SMALL")
    #expect(dirty.first?.value.contains("reclaimable") == true)
    #expect(!dirty.contains { $0.label.contains("TOTAL") || $0.label.contains("__TEXT") })
}

@Test func vmmapRanksRegionsByDirtyPlusSwappedAndFlagsSwap() {
    let highlights = ProfileParser.highlights(for: .vmmap, output: vmmapOutput)
    #expect(highlights.contains { $0.label == "Physical footprint" && $0.value == "185.1M" })
    let regions = highlights.filter { !["Physical footprint", "Peak footprint", "Writable regions"].contains($0.label) }
    #expect(regions.first?.label == "Foundation")
    #expect(regions.first?.severity == .notable)
    #expect(regions.contains { $0.label == "CoreAnimation" })
    #expect(!regions.contains { $0.label.hasPrefix("DefaultMallocZone") || $0.label == "TOTAL" })
}

@Test func heapHighlightsTopClassesBySize() {
    let highlights = ProfileParser.highlights(for: .heap, output: heapOutput)
    #expect(highlights.first?.label == "Live allocations")
    #expect(highlights.first { $0.label == "non-object" }?.value.contains("objects") == true)
    #expect(highlights.contains { $0.label == "CFString" })
    #expect(highlights.contains { $0.label == "std::__shared_ptr_emplace<TFSInfo>" })
}

@Test func leaksFlagFindingsAndProtectedProcesses() {
    let highlights = ProfileParser.highlights(for: .leaks, output: leaksOutput)
    #expect(highlights.contains { $0.label == "Leaks" && $0.severity == .alert })
    #expect(highlights.contains { $0.label == "Leak" && $0.value.contains("ROOT LEAK") })
    #expect(highlights.contains { $0.label == "Limited scan" })
    let clean = ProfileParser.highlights(for: .leaks, output: "Process 1: 10 nodes malloced for 1 KB\nProcess 1: 0 leaks for 0 total leaked bytes.")
    #expect(clean.allSatisfy { $0.severity == .normal })
}

@Test func sampleHighlightsTopOfStackWithShares() {
    let highlights = ProfileParser.highlights(for: .sample, output: sampleOutput)
    #expect(highlights.first?.label == "__semwait_signal  (in libsystem_kernel.dylib)")
    #expect(highlights.first?.value == "882 samples (88%)")
    #expect(highlights.count == 2)
}

@Test func leaksExitOneIsAResultButOtherToolsMustExitZero() {
    #expect(ProfileTool.leaks.succeeded(status: 1))
    #expect(!ProfileTool.leaks.succeeded(status: 255))
    #expect(!ProfileTool.vmmap.succeeded(status: 1))
    #expect(ProfileTool.heap.pausesProcess && ProfileTool.leaks.pausesProcess && !ProfileTool.vmmap.pausesProcess)
}

@Test func privilegeFailuresExplainWhy() {
    let message = ProfileParser.failureMessage(
        tool: .vmmap, status: 255,
        error: "vmmap[50577]: vmmap cannot examine process 1 (launchd) because you do not have appropriate privileges to examine it; try running with `sudo`.\n",
        timedOut: false
    )
    #expect(message.contains("cannot examine process 1"))
    #expect(message.contains("root-owned"))
    #expect(ProfileParser.failureMessage(tool: .heap, status: -1, error: "", timedOut: true).contains("120 seconds"))
}

@Test func runnerProfilesOwnProcessAndReportsUnreachableOnes() async {
    guard Capabilities.supportsProfiling else { return }
    let own = await ProfileRunner.run(.footprint, pid: getpid())
    #expect(own.failure == nil)
    #expect(own.output.contains("Footprint"))
    #expect(!own.highlights.isEmpty)
    let launchd = await ProfileRunner.run(.vmmap, pid: 1)
    #expect(launchd.failure != nil)
}

private func identity(_ pid: Int32, _ start: TimeInterval = 100) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: start))
}

@Test func terminatorSignalsOnlyShownAndStillRunningProcesses() {
    var sent: [(Int32, Int32)] = []
    let outcome = ProcessTerminator.terminate(
        targets: [identity(200), identity(201), identity(202), identity(1), identity(300)],
        current: [identity(200), identity(201, 999), identity(1), identity(300)],
        force: false,
        selfPID: 300
    ) { pid, signal in
        sent.append((pid, signal))
        return pid == 200 ? 0 : EPERM
    }
    #expect(sent.map(\.0) == [200])
    #expect(sent.first?.1 == SIGTERM)
    #expect(outcome.signaled == [200])
    // 201 was reused (new start time), 202 exited, 1 is launchd, 300 is Smack itself.
    #expect(outcome.skipped == [201, 202, 1, 300])
    #expect(outcome.failures.isEmpty)
}

@Test func terminatorForceUsesSigkillAndMapsErrors() {
    let outcome = ProcessTerminator.terminate(
        targets: [identity(10), identity(11), identity(12)],
        current: [identity(10), identity(11), identity(12)],
        force: true,
        selfPID: 1
    ) { pid, signal in
        #expect(signal == SIGKILL)
        return pid == 10 ? EPERM : pid == 11 ? ESRCH : 0
    }
    #expect(outcome.signaled == [12])
    #expect(outcome.skipped == [11])
    #expect(outcome.failures == [ProcessTerminator.Failure(pid: 10, code: EPERM)])
    #expect(outcome.summary.contains("not permitted"))
}
