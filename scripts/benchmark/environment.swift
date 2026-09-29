import Foundation
import CoreGraphics
import AppKit

let dictionary = CGSessionCopyCurrentDictionary() as? [String:Any]
let locked = dictionary?["CGSSessionScreenIsLocked"] as? Bool
let info = ProcessInfo.processInfo
let thermal = ["nominal", "fair", "serious", "critical"][min(3,info.thermalState.rawValue)]
let result: [String:Any] = [
    "screenLocked": locked ?? (dictionary == nil),
    "sessionAvailable": dictionary != nil,
    "thermalState": thermal,
    "lowPowerMode": info.isLowPowerModeEnabled,
    "osVersion": info.operatingSystemVersionString,
    "physicalMemoryBytes": info.physicalMemory,
    "cpuCount": info.processorCount,
    "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
    "sampledAt": ISO8601DateFormatter().string(from:Date())
]
print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
