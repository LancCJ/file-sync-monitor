import SwiftUI

struct AppDropdownMenu<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let label: Label
    var arrowEdge: Edge = .bottom
    var maxHeight: CGFloat? = nil
    var localizeOptions: Bool = true
    
    @State private var isShowingPopover = false
    
    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPopover, arrowEdge: arrowEdge) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(options, id: \.0) { option in
                        Button {
                            selection = option.0
                            isShowingPopover = false
                        } label: {
                            HStack {
                                if localizeOptions {
                                    LocalizedText(option.1)
                                        .font(.system(size: 13, weight: selection == option.0 ? .semibold : .medium))
                                } else {
                                    Text(option.1)
                                        .font(.system(size: 13, weight: selection == option.0 ? .semibold : .medium))
                                }
                                Spacer()
                                if selection == option.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.appMint)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selection == option.0 ? Color.appMint.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(QuietButtonStyle())
                        .foregroundStyle(selection == option.0 ? Color.appMint : Color.appInk)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 160)
            .frame(maxHeight: maxHeight)
            .background(
                IMAClientSurfaceBackground()
            )
        }
    }
}
