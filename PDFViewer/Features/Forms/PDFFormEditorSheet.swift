import SwiftUI

struct PDFFormEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var editor: PDFDocumentEditor
    @State private var validationMessage: String?
    @State private var validationSucceeded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fieldList
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fill PDF Form", systemImage: "list.bullet.rectangle")
                .font(.title2.weight(.semibold))
            Text("Changes are made to the protected working copy. The original PDF stays unchanged.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var fieldList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(editor.formFields) { field in
                    PDFFormFieldRow(field: field, editor: editor)
                        .id(fieldRevisionID(field))
                }

                if let validationMessage {
                    Label(
                        validationMessage,
                        systemImage: validationSucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(validationSucceeded ? .green : .orange)
                    .accessibilityLabel(validationMessage)
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Reset Form") {
                appState.resetFormFields()
                validationMessage = nil
            }
            .disabled(editor.formFields.allSatisfy(\.isReadOnly))

            Button("Validate Required Fields", action: validate)

            Spacer()

            Button("Export Flattened…") {
                appState.exportFlattenedForm()
            }
            .help("Create a new PDF with form appearances made permanent")

            Button("Done") {
                appState.dismissFormEditor()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func validate() {
        do {
            try editor.validateRequiredFormFields()
            validationSucceeded = true
            validationMessage = "All required fields are complete."
        } catch {
            validationSucceeded = false
            validationMessage = (error as? LocalizedError)?.errorDescription
                ?? "Complete the required fields before exporting."
        }
    }

    private func fieldRevisionID(_ field: PDFFormField) -> String {
        "\(field.id)-\(String(describing: field.value))-\(field.isReadOnly)"
    }
}

private struct PDFFormFieldRow: View {
    @EnvironmentObject private var appState: AppState
    let field: PDFFormField
    @ObservedObject var editor: PDFDocumentEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(field.displayName)
                    .font(.headline)
                if field.isRequired {
                    Text("Required")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Required field")
                }
                if field.isReadOnly {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Page \(field.pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            control
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .text:
            PDFFormTextFieldControl(field: field)
        case .checkbox:
            Toggle("Checked", isOn: checkedBinding)
                .disabled(field.isReadOnly)
                .accessibilityLabel(field.displayName)
        case .choice:
            Picker(field.displayName, selection: choiceBinding) {
                Text("No Selection").tag(Optional<String>.none)
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(Optional(option))
                }
            }
            .labelsHidden()
            .disabled(field.isReadOnly)
            .accessibilityLabel(field.displayName)
        case .radioButton:
            Picker(field.displayName, selection: radioBinding) {
                Text("No Selection").tag(Optional<String>.none)
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(Optional(option))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(field.isReadOnly)
            .accessibilityLabel(field.displayName)
        case .signature:
            Label(
                "Digital-signature fields cannot be filled as a visual signature. Use Annotate to place a clearly labeled visual signature.",
                systemImage: "signature"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .unsupported:
            Label("This field type is not editable.", systemImage: "questionmark.square")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var currentField: PDFFormField {
        editor.formFields.first { $0.name == field.name } ?? field
    }

    private var checkedBinding: Binding<Bool> {
        Binding(
            get: {
                guard case let .checked(value) = currentField.value else {
                    return false
                }
                return value
            },
            set: { appState.updateFormField(named: field.name, value: .checked($0)) }
        )
    }

    private var choiceBinding: Binding<String?> {
        Binding(
            get: {
                guard case let .selectedChoice(value) = currentField.value else {
                    return nil
                }
                return value
            },
            set: { appState.updateFormField(named: field.name, value: .selectedChoice($0)) }
        )
    }

    private var radioBinding: Binding<String?> {
        Binding(
            get: {
                guard case let .selectedRadio(value) = currentField.value else {
                    return nil
                }
                return value
            },
            set: { appState.updateFormField(named: field.name, value: .selectedRadio($0)) }
        )
    }
}

private struct PDFFormTextFieldControl: View {
    @EnvironmentObject private var appState: AppState
    let field: PDFFormField
    @State private var draft: String

    init(field: PDFFormField) {
        self.field = field
        if case let .text(value) = field.value {
            _draft = State(initialValue: value)
        } else {
            _draft = State(initialValue: "")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(field.displayName, text: $draft)
                .textFieldStyle(.roundedBorder)
                .disabled(field.isReadOnly)
                .onSubmit(apply)
                .accessibilityLabel(field.displayName)

            Button("Apply", action: apply)
                .disabled(field.isReadOnly || draft == currentText || exceedsMaximumLength)
        }

        if let maximumLength = field.maximumLength {
            Text("\(draft.count) of \(maximumLength) characters")
                .font(.caption)
                .foregroundStyle(exceedsMaximumLength ? .red : .secondary)
        }
    }

    private var currentText: String {
        guard case let .text(value) = field.value else {
            return ""
        }
        return value
    }

    private var exceedsMaximumLength: Bool {
        field.maximumLength.map { draft.count > $0 } ?? false
    }

    private func apply() {
        guard !field.isReadOnly, !exceedsMaximumLength, draft != currentText else {
            return
        }
        appState.updateFormField(named: field.name, value: .text(draft))
    }
}
