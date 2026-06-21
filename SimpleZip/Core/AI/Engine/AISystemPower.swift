//
//  AISystemPower.swift
//  SimpleZip
//
//  系统电源状态读取(省电模式 + 电池低电 / 充电)。下沉 Core 供 **App 前台** 与 **后台 agent** 共用同一份:
//  - 前台(XPC)的 AI 电源门控由 `AIBackgroundSchedulingRules` 综合「本地 AI 活跃度 + 索引电源 + 低电 / 省电 / 空闲」判定;
//  - 后台 agent(用户拍板)**只看系统「低电量 + 省电模式」**,不参考前台的活跃度 / 索引电源设置。
//
//  纯 ProcessInfo + IOKit 读,off-main 安全、任意进程可用。无电池(台式机)→ 不低电、充电未知。
//

import Foundation
import IOKit.ps

nonisolated enum AISystemPower {
    /// 省电模式(系统「低电量模式」)。
    static var powerSaverMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// 电池:低电(< 20% 且未充电语义按容量百分比)/ 是否充电。无电池(台式机)→ (false, nil)。
    static func batteryState() -> (lowBattery: Bool, isCharging: Bool?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return (false, nil)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let pct = maxCap > 0 ? capacity * 100 / maxCap : 100
            let charging = (desc[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
            return (pct < 20, charging)
        }
        return (false, nil)
    }

    /// 后台 agent 的「跑模型」电源门控:省电模式或低电 → 不跑模型(只读电源,瞬回)。
    static func backgroundModelWorkAllowed() -> Bool {
        !powerSaverMode && !batteryState().lowBattery
    }
}
