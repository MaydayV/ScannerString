import Foundation

@MainActor
class UsageManager: ObservableObject {
    static let shared = UsageManager()
    
    @Published private(set) var remainingScans: Int = 10
    @Published private(set) var canScanToday: Bool = true
    
    private let userDefaults = UserDefaults.standard
    private let remainingScansKey = "remainingScans"
    private let lastResetDateKey = "lastResetDate"
    
    private init() {
        loadRemainingScans()
        checkDailyReset()
    }
    
    private func loadRemainingScans() {
        remainingScans = userDefaults.integer(forKey: remainingScansKey)
        if remainingScans == 0 {
            remainingScans = 10
        }
    }
    
    private func checkDailyReset() {
        if let lastResetDate = userDefaults.object(forKey: lastResetDateKey) as? Date {
            let calendar = Calendar.current
            let today = Date()
            
            if !calendar.isDate(lastResetDate, inSameDayAs: today) {
                // 新的一天，重置使用次数
                remainingScans = 10
                userDefaults.set(remainingScans, forKey: remainingScansKey)
                userDefaults.set(today, forKey: lastResetDateKey)
            }
        } else {
            // 首次使用，设置重置日期
            userDefaults.set(Date(), forKey: lastResetDateKey)
        }
    }
    
    func recordScan() {
        if !StoreManager.shared.hasUnlimitedSubscription {
            remainingScans -= 1
            userDefaults.set(remainingScans, forKey: remainingScansKey)
        }
    }
    
    func canPerformScan() -> Bool {
        return StoreManager.shared.hasUnlimitedSubscription || remainingScans > 0
    }
    
    func remainingScansToday() -> Int {
        if StoreManager.shared.hasUnlimitedSubscription {
            return Int.max
        }
        return remainingScans
    }
} 
