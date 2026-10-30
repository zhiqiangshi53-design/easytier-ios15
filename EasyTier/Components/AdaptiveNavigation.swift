import SwiftUI

struct AdaptiveNavigation<PrimaryView, SecondaryView, Enum>: View where PrimaryView: View, SecondaryView: View, Enum: Identifiable & Hashable {
#if os(macOS)
    let sizeClass = UserInterfaceSizeClass.compact
#else
    @Environment(\.horizontalSizeClass) var sizeClass
#endif
    @ViewBuilder var primaryColumn: PrimaryView
    @ViewBuilder var secondaryColumn: SecondaryView
    @Binding var showNav: Enum?
    
    init(_ primary: PrimaryView, _ secondary: SecondaryView, showNav: Binding<Enum?>) {
        primaryColumn = primary
        secondaryColumn = secondary
        _showNav = showNav
    }
    
    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    primaryColumn
                        .frame(maxWidth: columnMaxWidth)
                    secondaryColumn
                }
            } else {
                primaryColumn
            }
        }
        .adaptiveNavigationDestination(item: (sizeClass == .compact ? $showNav : .constant(nil)), destination: { secondaryColumn })
    }
}

extension View {
    @ViewBuilder
    func adaptiveNavigationDestination<Enum: Identifiable & Hashable, Destination: View>(
        item: Binding<Enum?>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.navigationDestination(item: item) { _ in
                destination()
            }
        } else if #available(iOS 16.0, macOS 13.0, *) {
            self.navigationDestination(
                isPresented: Binding(
                    get: { item.wrappedValue != nil },
                    set: { isPresented in
                        if !isPresented {
                            item.wrappedValue = nil
                        }
                    }
                )
            ) {
                destination()
            }
        } else {
            // iOS 15: NavigationStack is shimmed to NavigationView, so push the
            // secondary column with a hidden, programmatically activated link.
            // The destination is re-evaluated by the parent when the selection
            // changes, so it always matches the currently selected pane.
            self.background(
                NavigationLink(
                    destination: destination(),
                    isActive: Binding(
                        get: { item.wrappedValue != nil },
                        set: { isActive in
                            if !isActive {
                                item.wrappedValue = nil
                            }
                        }
                    ),
                    label: {
                        EmptyView()
                    }
                )
                .hidden()
            )
        }
    }
}
