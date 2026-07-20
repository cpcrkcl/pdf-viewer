import Foundation
@preconcurrency import PDFKit

enum PDFFormFieldKind: String, Equatable {
    case text
    case checkbox
    case radioButton
    case choice
    case signature
    case unsupported
}

enum PDFFormFieldValue: Equatable {
    case text(String)
    case checked(Bool)
    case selectedChoice(String?)
    case selectedRadio(String?)
}

struct PDFFormField: Identifiable, Equatable {
    let id: String
    let name: String
    let alternateName: String?
    let pageIndex: Int
    let kind: PDFFormFieldKind
    let value: PDFFormFieldValue?
    let defaultValue: String?
    let options: [String]
    let isRequired: Bool
    let isReadOnly: Bool
    let maximumLength: Int?

    var displayName: String {
        let trimmedAlternateName = alternateName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAlternateName?.isEmpty == false ? trimmedAlternateName! : name
    }
}

enum PDFFormError: LocalizedError, Equatable {
    case fieldNotFound(String)
    case fieldReadOnly(String)
    case incompatibleValue(field: String)
    case valueTooLong(field: String, maximum: Int)
    case invalidChoice(field: String)
    case requiredFieldsMissing([String])
    case couldNotFlatten

    var errorDescription: String? {
        switch self {
        case let .fieldNotFound(field):
            "The form field “\(field)” is no longer available."
        case let .fieldReadOnly(field):
            "The form field “\(field)” is read-only."
        case let .incompatibleValue(field):
            "The selected value is not valid for the form field “\(field)”."
        case let .valueTooLong(field, maximum):
            "The form field “\(field)” accepts at most \(maximum) characters."
        case let .invalidChoice(field):
            "Choose one of the available values for “\(field)”."
        case let .requiredFieldsMissing(fields):
            "Complete the required form fields: \(fields.joined(separator: ", "))."
        case .couldNotFlatten:
            "PDFViewer could not create a safe flattened copy of this form."
        }
    }
}

@MainActor
enum PDFFormEngine {
    private struct LocatedWidget {
        let pageIndex: Int
        let annotation: PDFAnnotation
    }

    private static let readOnlyFlag = 1 << 0
    private static let requiredFlag = 1 << 1

    static func fields(in document: PDFDocument) -> [PDFFormField] {
        groupedWidgets(in: document).map { name, widgets in
            makeField(name: name, widgets: widgets)
        }
    }

    static func setValue(
        _ value: PDFFormFieldValue,
        forFieldNamed name: String,
        in document: PDFDocument
    ) throws {
        guard let widgets = groupedWidgets(in: document).first(where: { $0.0 == name })?.1 else {
            throw PDFFormError.fieldNotFound(name)
        }
        let field = makeField(name: name, widgets: widgets)
        guard !field.isReadOnly else {
            throw PDFFormError.fieldReadOnly(name)
        }

        switch (field.kind, value) {
        case let (.text, .text(text)):
            if let maximumLength = field.maximumLength, text.count > maximumLength {
                throw PDFFormError.valueTooLong(field: name, maximum: maximumLength)
            }
            widgets.forEach { $0.annotation.widgetStringValue = text }

        case let (.checkbox, .checked(isChecked)):
            widgets.forEach {
                $0.annotation.buttonWidgetState = isChecked ? .onState : .offState
            }

        case let (.choice, .selectedChoice(choice)):
            if let choice, !field.options.contains(choice) {
                throw PDFFormError.invalidChoice(field: name)
            }
            widgets.forEach { $0.annotation.widgetStringValue = choice ?? "" }

        case let (.radioButton, .selectedRadio(selection)):
            if let selection, !field.options.contains(selection) {
                throw PDFFormError.invalidChoice(field: name)
            }
            setRadioSelection(selection, in: widgets)

        default:
            throw PDFFormError.incompatibleValue(field: name)
        }
    }

    static func reset(in document: PDFDocument) throws {
        for (name, widgets) in groupedWidgets(in: document) {
            let field = makeField(name: name, widgets: widgets)
            guard !field.isReadOnly else {
                continue
            }

            switch field.kind {
            case .text:
                widgets.forEach {
                    $0.annotation.widgetStringValue = $0.annotation.widgetDefaultStringValue ?? ""
                }
            case .checkbox:
                let shouldCheck = field.defaultValue.map {
                    !$0.isEmpty && $0.caseInsensitiveCompare("Off") != .orderedSame
                } ?? false
                widgets.forEach {
                    $0.annotation.buttonWidgetState = shouldCheck ? .onState : .offState
                }
            case .choice:
                widgets.forEach {
                    $0.annotation.widgetStringValue = $0.annotation.widgetDefaultStringValue ?? ""
                }
            case .radioButton:
                setRadioSelection(field.defaultValue, in: widgets)
            case .signature, .unsupported:
                continue
            }
        }
    }

    static func validateRequiredFields(in document: PDFDocument) throws {
        let missing = fields(in: document).compactMap { field -> String? in
            guard field.isRequired else {
                return nil
            }
            switch field.value {
            case let .text(value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? field.displayName
                    : nil
            case let .checked(value):
                return value ? nil : field.displayName
            case let .selectedChoice(value), let .selectedRadio(value):
                return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? nil
                    : field.displayName
            case nil:
                return field.displayName
            }
        }

        guard missing.isEmpty else {
            throw PDFFormError.requiredFieldsMissing(missing)
        }
    }

    static func flattenedDocument(from document: PDFDocument) throws -> PDFDocument {
        try validateRequiredFields(in: document)
        let options: [PDFDocumentWriteOption: Any] = [
            .burnInAnnotationsOption: true,
        ]
        guard
            let data = document.dataRepresentation(options: options),
            let flattened = PDFDocument(data: data),
            flattened.pageCount == document.pageCount,
            fields(in: flattened).isEmpty
        else {
            throw PDFFormError.couldNotFlatten
        }
        return flattened
    }

    private static func groupedWidgets(
        in document: PDFDocument
    ) -> [(String, [LocatedWidget])] {
        var order: [String] = []
        var widgetsByName: [String: [LocatedWidget]] = [:]

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }
            for annotation in page.annotations where
                annotation.type == PDFAnnotationSubtype.widget.pdfTypeName
            {
                guard
                    let fieldName = annotation.fieldName?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    !fieldName.isEmpty
                else {
                    continue
                }
                if widgetsByName[fieldName] == nil {
                    order.append(fieldName)
                    widgetsByName[fieldName] = []
                }
                widgetsByName[fieldName, default: []].append(
                    LocatedWidget(pageIndex: pageIndex, annotation: annotation)
                )
            }
        }

        return order.compactMap { name in
            widgetsByName[name].map { (name, $0) }
        }
    }

    private static func makeField(
        name: String,
        widgets: [LocatedWidget]
    ) -> PDFFormField {
        let first = widgets[0].annotation
        let kind = fieldKind(for: first)
        let options = fieldOptions(kind: kind, widgets: widgets)
        let value = fieldValue(kind: kind, widgets: widgets)
        let maximumLength = widgets.compactMap { widget -> Int? in
            let value = widget.annotation.maximumLength
            return value > 0 ? value : nil
        }.min()

        return PDFFormField(
            id: name,
            name: name,
            alternateName: first.value(forAnnotationKey: .widgetTextLabelUI) as? String,
            pageIndex: widgets[0].pageIndex,
            kind: kind,
            value: value,
            defaultValue: widgets.compactMap(\.annotation.widgetDefaultStringValue).first,
            options: options,
            isRequired: widgets.contains { fieldFlags(for: $0.annotation) & requiredFlag != 0 },
            isReadOnly: widgets.contains {
                $0.annotation.isReadOnly || fieldFlags(for: $0.annotation) & readOnlyFlag != 0
            },
            maximumLength: maximumLength
        )
    }

    private static func fieldKind(for annotation: PDFAnnotation) -> PDFFormFieldKind {
        switch annotation.widgetFieldType {
        case .text:
            return .text
        case .choice:
            return .choice
        case .signature:
            return .signature
        case .button:
            switch annotation.widgetControlType {
            case .checkBoxControl:
                return .checkbox
            case .radioButtonControl:
                return .radioButton
            case .pushButtonControl, .unknownControl:
                return .unsupported
            @unknown default:
                return .unsupported
            }
        default:
            return .unsupported
        }
    }

    private static func fieldOptions(
        kind: PDFFormFieldKind,
        widgets: [LocatedWidget]
    ) -> [String] {
        let values: [String]
        switch kind {
        case .choice:
            values = widgets.flatMap { $0.annotation.choices ?? [] }
        case .radioButton:
            values = widgets.compactMap(\.annotation.buttonWidgetStateString)
        default:
            return []
        }

        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func fieldValue(
        kind: PDFFormFieldKind,
        widgets: [LocatedWidget]
    ) -> PDFFormFieldValue? {
        switch kind {
        case .text:
            return .text(widgets[0].annotation.widgetStringValue ?? "")
        case .checkbox:
            return .checked(widgets.contains { $0.annotation.buttonWidgetState == .onState })
        case .choice:
            let value = widgets[0].annotation.widgetStringValue
            return .selectedChoice(value?.isEmpty == false ? value : nil)
        case .radioButton:
            let selected = widgets.first {
                $0.annotation.buttonWidgetState == .onState
            }?.annotation.buttonWidgetStateString
            return .selectedRadio(selected)
        case .signature, .unsupported:
            return nil
        }
    }

    private static func fieldFlags(for annotation: PDFAnnotation) -> Int {
        (annotation.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
    }

    private static func setRadioSelection(
        _ selection: String?,
        in widgets: [LocatedWidget]
    ) {
        let selectedWidget = widgets.first {
            $0.annotation.buttonWidgetStateString == selection
        }
        widgets.forEach { $0.annotation.buttonWidgetState = .offState }
        selectedWidget?.annotation.buttonWidgetState = .onState
    }
}
