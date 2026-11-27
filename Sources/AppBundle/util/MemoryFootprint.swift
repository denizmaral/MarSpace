import Darwin

/// The memory of MarSpace, as Activity Monitor shows it: the physical footprint. For the perf log of the sessions (see
/// SessionAxCost): a leak or a burst shows up in the log before anyone notices it
enum MemoryFootprint {
    /// nil if the kernel doesn't tell. A system call of a few microseconds: once per session, not per event
    static var megabytes: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        // task_info fills a C struct through a pointer: the only way to ask the kernel
        let result = withUnsafeMutablePointer(to: &info) { info in
            unsafe info.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }
}
