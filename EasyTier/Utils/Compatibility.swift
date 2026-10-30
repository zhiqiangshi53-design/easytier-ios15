import SwiftUI

#if os(iOS)
    let ToolbarLeading = ToolbarItemPlacement.navigationBarLeading
    let ToolbarTrailing = ToolbarItemPlacement.navigationBarTrailing
#else
    let ToolbarLeading = ToolbarItemPlacement.navigation
    let ToolbarTrailing = ToolbarItemPlacement.primaryAction
#endif

// MARK: - iOS 15 shims
//
// The upstream project targets iOS 16 and uses SwiftUI APIs added in iOS 16.
// These shims keep the same call sites working while remaining source compatible
// with the original code (native behaviour is used whenever it is available).

#if os(iOS)
    /// `NavigationStack` is iOS 16+. On iOS 15 it falls back to a `NavigationView`
    /// using the stack style, which gives the same single-column push behaviour.
    struct NavigationStack<Content: View>: View {
        @ViewBuilder var content: () -> Content

        init(@ViewBuilder content: @escaping () -> Content) {
            self.content = content
        }

        var body: some View {
            if #available(iOS 16.0, *) {
                SwiftUI.NavigationStack {
                    content()
                }
            } else {
                NavigationView {
                    content()
                }
                .navigationViewStyle(.stack)
            }
        }
    }
#endif

extension View {
    func decimalKeyboardType() -> some View {
#if os(iOS)
        return self.keyboardType(.decimalPad)
#else
        return self
#endif
    }
    
    func numberKeyboardType() -> some View {
#if os(iOS)
        return self.keyboardType(.numberPad)
#else
        return self
#endif
    }
    
    func adaptiveNavigationBarTitleInline() -> some View {
#if os(iOS)
        return self.navigationBarTitleDisplayMode(.inline)
#else
        return self
#endif
    }
    
    func adaptiveNoTextInputAutocapitalization() -> some View {
#if os(iOS)
        return self.textInputAutocapitalization(.never)
#else
        return self
#endif
    }

    /// `.formStyle(.grouped)` is iOS 16+. On iOS 15 a plain `Form` already uses
    /// the grouped look, so the modifier can simply be omitted.
    @ViewBuilder
    func adaptiveFormStyleGrouped() -> some View {
#if os(iOS)
        if #available(iOS 16.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
#else
        self.formStyle(.grouped)
#endif
    }

    /// `.scrollDismissesKeyboard(.immediately)` is iOS 16+.
    @ViewBuilder
    func adaptiveScrollDismissesKeyboard() -> some View {
#if os(iOS)
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
#else
        self
#endif
    }

    /// `.fontWeight(_:)` on `View` is iOS 16+. On iOS 15 the weight is skipped.
    @ViewBuilder
    func adaptiveFontWeight(_ weight: Font.Weight) -> some View {
#if os(iOS)
        if #available(iOS 16.0, *) {
            self.fontWeight(weight)
        } else {
            self
        }
#else
        self.fontWeight(weight)
#endif
    }
}

#if os(iOS)
    /// `LabeledContent` is iOS 16+. On iOS 15 it renders as a simple two-column row.
    struct LabeledContent<Label: View, Content: View>: View {
        @ViewBuilder var label: () -> Label
        @ViewBuilder var content: () -> Content

        init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
            self.content = content
            self.label = label
        }

        init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) where Label == Text {
            self.label = { Text(titleKey) }
            self.content = content
        }

        var body: some View {
            if #available(iOS 16.0, *) {
                SwiftUI.LabeledContent(content: content, label: label)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label()
                    Spacer(minLength: 0)
                    content()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    extension LabeledContent where Label == Text, Content == Text {
        init(_ titleKey: LocalizedStringKey, value: String) {
            self.init(content: { Text(value).foregroundColor(.secondary) }, label: { Text(titleKey) })
        }
    }

    /// Multiline text field. `TextField(axis:)` is iOS 16+; on iOS 15 a
    /// `TextEditor` with a placeholder is used instead.
    struct MultilineTextField: View {
        let titleKey: LocalizedStringKey
        @Binding var text: String

        init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
            self.titleKey = titleKey
            _text = text
        }

        var body: some View {
            if #available(iOS 16.0, *) {
                TextField(titleKey, text: $text, axis: .vertical)
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(titleKey)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 72)
                        .padding(.horizontal, -4)
                }
            }
        }
    }

    /// Plain row used for programmatic navigation on iOS 15, where the
    /// value-based `NavigationLink` is unavailable.
    struct CompatNavigationRow: View {
        let title: LocalizedStringKey

        init(_ title: LocalizedStringKey) {
            self.title = title
        }

        var body: some View {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
    }
#endif
