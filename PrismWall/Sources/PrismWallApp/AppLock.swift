import AppKit
import CryptoKit
import LocalAuthentication
import Observation
import SwiftUI

// MARK: - Keychain 存储（密码本体，系统级加密）

enum KeychainStore {
    private static let service = "com.hewentao.prismwall"

    static func setPassword(_ password: String, account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 应用锁管理

@MainActor
@Observable
final class AppLockManager {
    static let shared = AppLockManager()
    private static let account = "app-lock"
    private static let idleDefaultsKey = "lock.idleLimitSeconds"
    private static let hashPrefix = "v1|"

    /// 生成「v1|盐|摘要」存储串；盐内嵌于串中,解锁时取出复算
    private static func storedForm(of password: String) -> String {
        let saltData = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let salt = Data(saltData).base64EncodedString()
        return hashPrefix + salt + "|" + digest(password, salt: salt)
    }

    private static func digest(_ password: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + password).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private(set) var isEnabled = false
    private(set) var isLocked = false
    /// 闲置自动锁定秒数；0 = 从不
    var idleLimitSeconds: Int {
        didSet { UserDefaults.standard.set(idleLimitSeconds, forKey: Self.idleDefaultsKey) }
    }
    private(set) var lastActivity = Date()

    private init() {
        #if DEBUG
        // 营销截图演示模式（PW_DEMO_DATA_DIR）：不读真实 Keychain 启动锁，
        // 避免演示实例误触用户自己设置的密码锁
        if ProcessInfo.processInfo.environment["PW_DEMO_DATA_DIR"] != nil {
            isEnabled = false
            idleLimitSeconds = 0
            return
        }
        #endif
        isEnabled = KeychainStore.password(for: Self.account) != nil
        let stored = UserDefaults.standard.integer(forKey: Self.idleDefaultsKey)
        idleLimitSeconds = stored
        // 已启用密码锁但 Keychain 密码丢失（重签名等异常）：视为未启用，避免永久锁死
        if isEnabled && KeychainStore.password(for: Self.account) == nil {
            isEnabled = false
        }
    }

    func enable(password: String) {
        KeychainStore.setPassword(Self.storedForm(of: password), account: Self.account)
        isEnabled = true
    }

    /// 关闭密码锁需验证当前密码；返回是否验证成功
    func disable(currentPassword: String) -> Bool {
        guard verify(currentPassword) else { return false }
        KeychainStore.deletePassword(account: Self.account)
        isEnabled = false
        isLocked = false
        return true
    }

    /// Nit4：Keychain 中存「v1|盐|SHA256(盐+密码)」而非明文——
    /// 即使 Keychain 内容被读走也拿不到可用密码。兼容旧明文记录：校验通过即静默升级
    private func verify(_ password: String) -> Bool {
        guard let stored = KeychainStore.password(for: Self.account) else { return false }
        if stored.hasPrefix(Self.hashPrefix) {
            let parts = stored.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return false }
            return stored == Self.hashPrefix + parts[1] + "|" + Self.digest(password, salt: parts[1])
        }
        // 旧版明文记录：比对通过则升级为哈希存储
        if stored == password {
            KeychainStore.setPassword(Self.storedForm(of: password), account: Self.account)
            return true
        }
        return false
    }

    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// 返回是否解锁成功
    @discardableResult
    func unlock(with password: String) -> Bool {
        guard verify(password) else { return false }
        isLocked = false
        lastActivity = Date()
        return true
    }

    /// 安全重置：清空密码（配合媒体库重置使用）
    func resetAll() {
        KeychainStore.deletePassword(account: Self.account)
        isEnabled = false
        isLocked = false
    }

    func touch() {
        lastActivity = Date()
    }

    func checkIdle() {
        guard isEnabled, !isLocked, idleLimitSeconds > 0 else { return }
        if Date().timeIntervalSince(lastActivity) > Double(idleLimitSeconds) {
            lock()
        }
    }
}

// MARK: - 锁定覆盖层

struct LockOverlayView: View {
    let manager: AppLockManager
    let onReset: () -> Void
    @State private var password = ""
    @State private var showError = false
    @State private var showResetConfirm = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("PrismWall 已锁定")
                    .font(.title3.weight(.semibold))
                SecureField("输入密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($fieldFocused)
                    .onSubmit(tryUnlock)
                if showError {
                    Text("密码错误，请重试")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("解锁") { tryUnlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .onAppear { fieldFocused = true }
        .alert("安全重置？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置并清除密码", role: .destructive) { onReset() }
        } message: {
            Text("将清除媒体库索引与全部设置（磁盘上的照片视频文件不受影响）。重置后需重新添加文件夹。")
        }
    }

    private func tryUnlock() {
        if manager.unlock(with: password) {
            password = ""
            showError = false
        } else {
            showError = true
            password = ""
        }
    }
}
