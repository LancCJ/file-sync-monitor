import Foundation
import StoreKit
import Observation

/// 负责 StoreKit 2 内购流程的服务
@Observable
final class StoreManager {
    static let shared = StoreManager()
    
    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs = Set<String>()
    
    private let proProductID = "com.filesyncmonitor.pro_lifetime"
    
    var isPro: Bool {
        purchasedProductIDs.contains(proProductID)
    }
    
    private init() {
        if Bundle.main.bundleIdentifier != nil {
            Task {
                await refreshPurchasedProducts()
            }
        } else {
            print("Warning: Skipping StoreKit refresh because Bundle Identifier is nil.")
        }
    }
    
    /// 获取产品列表
    func fetchProducts() async {
        do {
            self.products = try await Product.products(for: [proProductID])
        } catch {
            print("Failed to fetch products: \(error)")
        }
    }
    
    /// 购买产品
    func purchase() async throws -> Bool {
        guard let product = products.first(where: { $0.id == proProductID }) else { return false }
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            purchasedProductIDs.insert(transaction.productID)
            await transaction.finish()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }
    
    /// 刷新已购买的产品状态
    func refreshPurchasedProducts() async {
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                purchasedProductIDs.insert(transaction.productID)
            } catch {
                print("Transaction verification failed")
            }
        }
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

enum StoreError: Error {
    case failedVerification
}
