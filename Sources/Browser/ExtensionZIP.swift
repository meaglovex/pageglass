import Foundation
import zlib

/// A deliberately bounded ZIP reader: stored/deflate, UTF-8, single-volume, no ZIP64 or encryption.
/// No archive paths are passed to an external unzip process. Actual inflated bytes must match the budget and CRC.
enum ExtensionZIP {
    static func extract(_ data:Data,to directory:URL) throws {
        let bytes = [UInt8](data)
        func fail(_ text:String = "ZIP 文件损坏或使用了不支持的格式")->ExtensionPackage.Failure { .init(message:text) }
        func number(_ offset:Int,_ length:Int)throws->Int {
            guard offset >= 0,offset <= bytes.count-length else { throw fail() }
            return (0..<length).reduce(0) { $0 | Int(bytes[offset+$1]) << ($1*8) }
        }
        guard bytes.count >= 22 else { throw fail() }
        var end:Int?
        for offset in stride(from:bytes.count-22,through:max(0,bytes.count-65557),by:-1) {
            if try number(offset,4) == 0x06054b50,offset+22+(try number(offset+20,2)) == bytes.count { end = offset; break }
        }
        guard let end,try number(end+4,2) == 0,try number(end+6,2) == 0 else { throw fail() }
        let count = try number(end+10,2),centralSize = try number(end+12,4),centralStart = try number(end+16,4)
        guard count > 0,count <= ExtensionPackage.countLimit,try number(end+8,2) == count,centralStart+centralSize == end else { throw fail("ZIP 文件数量超限，或不支持分卷 / ZIP64") }
        var cursor = centralStart,total = 0,seen = Set<String>(),ranges:[Range<Int>] = []
        for _ in 0..<count {
            guard try number(cursor,4) == 0x02014b50 else { throw fail() }
            let flags = try number(cursor+8,2),method = try number(cursor+10,2),crc = try number(cursor+16,4)
            let compressed = try number(cursor+20,4),size = try number(cursor+24,4)
            let nameLength = try number(cursor+28,2),extra = try number(cursor+30,2),comment = try number(cursor+32,2)
            let mode = (try number(cursor+38,4) >> 16) & 0xf000,local = try number(cursor+42,4)
            guard flags & ~0x080e == 0,[0,8].contains(method),[0,0x8000,0x4000].contains(mode),try number(cursor+34,2) == 0,
                  size <= ExtensionPackage.fileLimit,compressed <= 32*1024*1024,cursor+46+nameLength+extra+comment <= end else { throw fail("ZIP 含加密、符号链接、特殊文件或超限内容") }
            let rawName = Array(bytes[(cursor+46)..<(cursor+46+nameLength)])
            guard let original = String(bytes:rawName,encoding:.utf8) else { throw fail("ZIP 文件名需要使用 UTF-8") }
            let isDirectory = original.hasSuffix("/")
            let name = try ExtensionPackage.path(isDirectory ? String(original.dropLast()) : original)
            guard seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw fail("ZIP 含重名或大小写冲突路径") }
            guard try number(local,4) == 0x04034b50,try number(local+6,2) == flags,try number(local+8,2) == method else { throw fail() }
            let localName = try number(local+26,2),localExtra = try number(local+28,2),start = local+30+localName+localExtra
            guard localName == nameLength,start <= centralStart,compressed <= centralStart-start,
                  Array(bytes[(local+30)..<(local+30+localName)]) == rawName else { throw fail() }
            if flags & 8 == 0 {
                guard try number(local+14,4) == crc,try number(local+18,4) == compressed,try number(local+22,4) == size else { throw fail() }
            }
            let range = local..<(start+compressed)
            guard !ranges.contains(where:{$0.overlaps(range)}) else { throw fail("ZIP 包含重叠数据") }; ranges.append(range)
            let target = directory.appendingPathComponent(name)
            if isDirectory {
                guard size == 0,mode != 0x8000 else { throw fail() }
            } else {
                guard mode != 0x4000 else { throw fail() }
            }
            total += size; guard total <= ExtensionPackage.totalLimit else { throw fail("扩展解包后超过 64 MiB") }
            let input = Array(bytes[start..<(start+compressed)])
            let output:[UInt8]
            if method == 0 { guard size == compressed else { throw fail() }; output = input }
            else {
                var stream = z_stream(),buffer = [UInt8](repeating:0,count:size+1)
                guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw fail() }
                defer { inflateEnd(&stream) }
                let result = input.withUnsafeBytes { raw in
                    buffer.withUnsafeMutableBytes { out in
                        stream.next_in = UnsafeMutablePointer(mutating:raw.bindMemory(to:UInt8.self).baseAddress); stream.avail_in = uInt(input.count)
                        stream.next_out = out.bindMemory(to:UInt8.self).baseAddress; stream.avail_out = uInt(out.count)
                        return inflate(&stream,Z_FINISH)
                    }
                }
                guard result == Z_STREAM_END,stream.total_out == size,stream.total_in == compressed else { throw fail("ZIP 实际解压大小不匹配或超过限制") }
                output = Array(buffer.prefix(size))
            }
            let checksum = output.withUnsafeBytes { crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt(output.count)) }
            guard UInt32(truncatingIfNeeded:checksum) == UInt32(crc) else { throw fail("ZIP 校验失败") }
            if isDirectory {
                try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            } else {
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(output).write(to:target,options:.withoutOverwriting)
            }
            cursor += 46+nameLength+extra+comment
        }
        guard cursor == end else { throw fail() }
    }
}
