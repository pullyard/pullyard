import Darwin

enum MemoryRelief {
    static func release() {
        malloc_zone_pressure_relief(nil, 0)
    }
}
