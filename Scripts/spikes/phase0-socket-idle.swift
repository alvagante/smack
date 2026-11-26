import Foundation
import Darwin

let path = CommandLine.arguments[1]
let seconds = Double(CommandLine.arguments[2])!
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
precondition(fd >= 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8CString)
precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
withUnsafeMutableBytes(of: &address.sun_path) { destination in bytes.withUnsafeBytes { destination.copyBytes(from: $0) } }
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
precondition(result == 0)
precondition(chmod(path, 0o600) == 0)
precondition(listen(fd, 8) == 0)
precondition(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
source.setEventHandler {
    while true {
        let peer = accept(fd, nil, nil)
        if peer < 0 { break }
        close(peer)
    }
}
source.resume()
func usage() -> (Double, Int64, Int64) {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return (Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6, Int64(r.ru_maxrss), Int64(r.ru_nvcsw + r.ru_nivcsw))
}
let before = usage()
let start = ProcessInfo.processInfo.systemUptime
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    let after = usage()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    print("{\"elapsed_s\":\(elapsed),\"cpu_s\":\(after.0-before.0),\"cpu_percent_one_core\":\(100*(after.0-before.0)/elapsed),\"maxrss_start_bytes\":\(before.1),\"maxrss_end_bytes\":\(after.1),\"context_switches\":\(after.2-before.2)}")
    source.cancel(); close(fd); exit(0)
}
dispatchMain()
