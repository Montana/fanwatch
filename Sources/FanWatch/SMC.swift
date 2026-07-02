import Foundation
import IOKit

// MARK: - Raw structs matching the AppleSMC kernel interface

private struct SMCVersion {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - Helpers

private func fourCC(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for c in s.utf8.prefix(4) {
        result = (result << 8) | UInt32(c)
    }
    return result
}

private func fourCCString(_ v: UInt32) -> String {
    let chars: [Character] = (0..<4).reversed().map { i in
        let byte = UInt8((v >> (i * 8)) & 0xFF)
        return (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "?"
    }
    return String(chars)
}

private func tupleToArray(_ t: SMCParamStruct, count: Int) -> [UInt8] {
    var bytes = t.bytes
    return withUnsafeBytes(of: &bytes) { raw in
        Array(raw.prefix(min(count, 32)))
    }
}

// MARK: - Public value model

struct SMCKeyMeta: Hashable {
    let key: String
    let type: String
    let size: Int
}

enum SMCError: Error {
    case serviceNotFound
    case connectionFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcError(UInt8)
    case undecodableType(String)
}

// MARK: - SMC client

final class SMCClient {
    private var connection: io_connect_t = 0
    private let queue = DispatchQueue(label: "smc.client")

    // SMC command codes
    private let kSMCHandleYPCEvent: UInt32 = 2
    private let cmdReadBytes: UInt8 = 5
    private let cmdReadIndex: UInt8 = 8
    private let cmdReadKeyInfo: UInt8 = 9

    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SMCError.connectionFailed(result)
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw SMCError.callFailed(result)
        }
        guard output.result == 0 else {
            throw SMCError.smcError(output.result)
        }
        return output
    }

    private func keyInfo(for key: UInt32) throws -> SMCKeyInfoData {
        if let cached = queue.sync(execute: { keyInfoCache[key] }) {
            return cached
        }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = cmdReadKeyInfo
        let output = try call(&input)
        queue.sync { keyInfoCache[key] = output.keyInfo }
        return output.keyInfo
    }

    /// Total number of keys the SMC exposes.
    func keyCount() throws -> Int {
        let raw = try readRaw(key: "#KEY")
        guard raw.bytes.count >= 4 else { return 0 }
        return Int(UInt32(raw.bytes[0]) << 24 | UInt32(raw.bytes[1]) << 16 |
                   UInt32(raw.bytes[2]) << 8 | UInt32(raw.bytes[3]))
    }

    /// Key name at a given index (for enumeration).
    func key(at index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = cmdReadIndex
        input.data32 = UInt32(index)
        let output = try call(&input)
        return fourCCString(output.key)
    }

    struct RawValue {
        let type: String
        let bytes: [UInt8]
    }

    func readRaw(key: String) throws -> RawValue {
        let code = fourCC(key)
        let info = try keyInfo(for: code)

        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = cmdReadBytes
        let output = try call(&input)

        return RawValue(
            type: fourCCString(info.dataType),
            bytes: tupleToArray(output, count: Int(info.dataSize))
        )
    }

    /// Read a key and decode it to a Double, if the type is understood.
    func readDouble(key: String) throws -> Double {
        let raw = try readRaw(key: key)
        if let v = Self.decode(type: raw.type, bytes: raw.bytes) {
            return v
        }
        throw SMCError.undecodableType(raw.type)
    }

    /// Decode common SMC data types to Double.
    static func decode(type: String, bytes b: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ioft":
            guard b.count >= 8 else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(b[i]) << (8 * i) }
            // ioft is a 48.16 fixed point in practice
            return Double(bits) / 65536.0
        case "ui8 ":
            guard b.count >= 1 else { return nil }
            return Double(b[0])
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si8 ":
            guard b.count >= 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "fp88":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0
        case "sp78":
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 256.0
        case "sp87":
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 128.0
        case "sp96":
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 64.0
        default:
            return nil
        }
    }

    /// Enumerate all keys with their type metadata. Slowish (~1000 calls); run once off the main thread.
    func allKeys() throws -> [SMCKeyMeta] {
        let count = try keyCount()
        var metas: [SMCKeyMeta] = []
        metas.reserveCapacity(count)
        for i in 0..<count {
            guard let name = try? key(at: i) else { continue }
            guard let info = try? keyInfo(for: fourCC(name)) else { continue }
            metas.append(SMCKeyMeta(
                key: name,
                type: fourCCString(info.dataType),
                size: Int(info.dataSize)
            ))
        }
        return metas
    }
}
