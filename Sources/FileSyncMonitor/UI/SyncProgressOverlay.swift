import SwiftUI

/// 高端毛玻璃同步状态浮层卡片，自带精美旋转微动画与成功/失败过渡态
struct SyncProgressOverlay: View {
    @State private var rotationAngle: Double = 0.0
    
    var body: some View {
        let service = FileMonitorService.shared
        
        if service.isShowingSyncSheet {
            ZStack {
                // 背景遮罩稍微降低不透明度，防止过度压暗
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
                // 居中的毛玻璃卡片
                VStack(spacing: 20) {
                    if service.isSyncSheetFinished {
                        if let error = service.syncSheetError {
                            // 失败状态
                            VStack(spacing: 12) {
                                if #available(macOS 15.0, *) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(Color.appRose)
                                        .symbolEffect(.bounce.up, options: .nonRepeating)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(Color.appRose)
                                }
                                
                                Text(service.syncSheetTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.appInk)
                                
                                ScrollView(.vertical) {
                                    Text(error)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.appMuted)
                                        .multilineTextAlignment(.leading)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(height: 100)
                                .background(Color.appCanvas.opacity(0.4))
                                .cornerRadius(8)
                                
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        service.isShowingSyncSheet = false
                                    }
                                }) {
                                    LocalizedText("关闭")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 7)
                                        .background(Color.appRose)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            // 成功状态
                            VStack(spacing: 16) {
                                if #available(macOS 15.0, *) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 46))
                                        .foregroundStyle(Color.appMint)
                                        .symbolEffect(.bounce.up, options: .nonRepeating)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 46))
                                        .foregroundStyle(Color.appMint)
                                }
                                
                                Text(service.syncSheetStatus)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.appInk)
                            }
                            .padding(.vertical, 8)
                        }
                    } else {
                        // 进行中状态
                        VStack(spacing: 16) {
                            // 炫酷渐变旋转圆环
                            ZStack {
                                Circle()
                                    .stroke(Color.appMuted.opacity(0.12), lineWidth: 4)
                                    .frame(width: 50, height: 50)
                                
                                Circle()
                                    .trim(from: 0, to: 0.7)
                                    .stroke(
                                        AngularGradient(
                                            gradient: Gradient(colors: [Color.appViolet, Color.appMint]),
                                            center: .center
                                        ),
                                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                    )
                                    .frame(width: 50, height: 50)
                                    .rotationEffect(Angle(degrees: rotationAngle))
                                    .onAppear {
                                        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                                            rotationAngle = 360.0
                                        }
                                    }
                                    .onDisappear {
                                        rotationAngle = 0.0
                                    }
                                
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.appViolet)
                            }
                            
                            VStack(spacing: 8) {
                                Text(service.syncSheetTitle)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.appInk)
                                
                                Text(service.syncSheetStatus)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.appMuted)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(height: 34)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(width: 320)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Material.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.appMuted.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
                .transition(.scale.combined(with: .opacity))
            }
            .transition(.opacity)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: service.isShowingSyncSheet)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: service.isSyncSheetFinished)
        }
    }
}
