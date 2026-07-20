import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFFormEngineTests: XCTestCase {
    func testDiscoversSupportedFieldsInPageOrder() throws {
        let document = try makeFormDocument()

        let fields = PDFFormEngine.fields(in: document)

        XCTAssertEqual(fields.map(\.name), ["fullName", "consent", "plan", "tier"])
        XCTAssertEqual(fields.map(\.kind), [.text, .checkbox, .choice, .radioButton])
        XCTAssertEqual(fields[0].value, .text("Original"))
        XCTAssertEqual(fields[0].defaultValue, "Original")
        XCTAssertEqual(fields[0].maximumLength, 12)
        XCTAssertTrue(fields[0].isRequired)
        XCTAssertEqual(fields[1].value, .checked(false))
        XCTAssertTrue(fields[1].isRequired)
        XCTAssertEqual(fields[2].options, ["Standard", "Professional"])
        XCTAssertEqual(fields[2].value, .selectedChoice("Standard"))
        XCTAssertEqual(fields[3].options, ["Basic", "Premium"])
        XCTAssertEqual(fields[3].value, .selectedRadio("Basic"))
    }

    func testTypedUpdatesAndResetRestoreDefaults() throws {
        let document = try makeFormDocument()

        try PDFFormEngine.setValue(.text("Ada"), forFieldNamed: "fullName", in: document)
        try PDFFormEngine.setValue(.checked(true), forFieldNamed: "consent", in: document)
        try PDFFormEngine.setValue(
            .selectedChoice("Professional"),
            forFieldNamed: "plan",
            in: document
        )
        try PDFFormEngine.setValue(.selectedRadio("Premium"), forFieldNamed: "tier", in: document)

        let updated = Dictionary(uniqueKeysWithValues: PDFFormEngine.fields(in: document).map {
            ($0.name, $0.value)
        })
        XCTAssertEqual(updated["fullName"]!, .text("Ada"))
        XCTAssertEqual(updated["consent"]!, .checked(true))
        XCTAssertEqual(updated["plan"]!, .selectedChoice("Professional"))
        XCTAssertEqual(updated["tier"]!, .selectedRadio("Premium"))

        XCTAssertThrowsError(
            try PDFFormEngine.setValue(
                .selectedChoice("Enterprise"),
                forFieldNamed: "plan",
                in: document
            )
        ) { error in
            XCTAssertEqual(error as? PDFFormError, .invalidChoice(field: "plan"))
        }
        XCTAssertThrowsError(
            try PDFFormEngine.setValue(
                .text("This value is too long"),
                forFieldNamed: "fullName",
                in: document
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFFormError,
                .valueTooLong(field: "fullName", maximum: 12)
            )
        }
        XCTAssertThrowsError(
            try PDFFormEngine.setValue(.checked(true), forFieldNamed: "plan", in: document)
        ) { error in
            XCTAssertEqual(error as? PDFFormError, .incompatibleValue(field: "plan"))
        }

        try PDFFormEngine.reset(in: document)
        let reset = Dictionary(uniqueKeysWithValues: PDFFormEngine.fields(in: document).map {
            ($0.name, $0.value)
        })
        XCTAssertEqual(reset["fullName"]!, .text("Original"))
        XCTAssertEqual(reset["consent"]!, .checked(false))
        XCTAssertEqual(reset["plan"]!, .selectedChoice("Standard"))
        XCTAssertEqual(reset["tier"]!, .selectedRadio("Basic"))
    }

    func testRequiredValidationAndReadOnlyFieldsFailRecoverably() throws {
        let document = try makeFormDocument(emptyRequiredFields: true)

        XCTAssertThrowsError(try PDFFormEngine.validateRequiredFields(in: document)) { error in
            XCTAssertEqual(
                error as? PDFFormError,
                .requiredFieldsMissing(["fullName", "consent"])
            )
        }

        try PDFFormEngine.setValue(.text("Ada"), forFieldNamed: "fullName", in: document)
        try PDFFormEngine.setValue(.checked(true), forFieldNamed: "consent", in: document)
        XCTAssertNoThrow(try PDFFormEngine.validateRequiredFields(in: document))

        let readOnly = try XCTUnwrap(widget(named: "plan", in: document))
        readOnly.isReadOnly = true
        XCTAssertThrowsError(
            try PDFFormEngine.setValue(
                .selectedChoice("Professional"),
                forFieldNamed: "plan",
                in: document
            )
        ) { error in
            XCTAssertEqual(error as? PDFFormError, .fieldReadOnly("plan"))
        }
        XCTAssertEqual(
            PDFFormEngine.fields(in: document).first { $0.name == "plan" }?.value,
            .selectedChoice("Standard")
        )
    }

    func testEditorFormMutationIsAProtectedUndoableRevision() throws {
        let editor = try PDFDocumentEditor(document: makeFormDocument())

        try editor.updateFormField(named: "fullName", value: .text("Ada"))

        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertEqual(editor.formFields.first { $0.name == "fullName" }?.value, .text("Ada"))

        try editor.undo()
        XCTAssertEqual(
            editor.formFields.first { $0.name == "fullName" }?.value,
            .text("Original")
        )
        XCTAssertFalse(editor.isDirty)

        try editor.redo()
        XCTAssertEqual(editor.formFields.first { $0.name == "fullName" }?.value, .text("Ada"))
    }

    func testExportReopenPreservesValuesAndFlattenRemovesWidgets() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let filledURL = temporaryDirectory.appendingPathComponent("filled.pdf")
        let flattenedURL = temporaryDirectory.appendingPathComponent("flattened.pdf")
        let sourceDocument = try makeFormDocument()
        guard sourceDocument.write(to: sourceURL) else {
            return XCTFail("Could not write form fixture")
        }
        let sourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: sourceDocument)
        try editor.updateFormField(named: "fullName", value: .text("Ada"))
        try editor.updateFormField(named: "consent", value: .checked(true))

        _ = try PDFExporter(stagingDirectory: temporaryDirectory).export(
            document: editor.document,
            sourceURL: sourceURL,
            to: filledURL
        )

        let reopened = try XCTUnwrap(PDFDocument(url: filledURL))
        XCTAssertEqual(PDFFormEngine.fields(in: reopened), editor.formFields)
        XCTAssertEqual(
            PDFFormEngine.fields(in: reopened).first { $0.name == "fullName" }?.value,
            .text("Ada")
        )
        XCTAssertEqual(
            PDFFormEngine.fields(in: reopened).first { $0.name == "consent" }?.value,
            .checked(true)
        )

        let flattened = try PDFFormEngine.flattenedDocument(from: editor.document)
        _ = try PDFExporter(stagingDirectory: temporaryDirectory).export(
            document: flattened,
            sourceURL: sourceURL,
            to: flattenedURL
        )

        let reopenedFlattened = try XCTUnwrap(PDFDocument(url: flattenedURL))
        XCTAssertEqual(PDFFormEngine.fields(in: reopenedFlattened), [])
        XCTAssertEqual(reopenedFlattened.pageCount, editor.document.pageCount)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    private func makeFormDocument(emptyRequiredFields: Bool = false) throws -> PDFDocument {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)

        let text = widget(
            bounds: CGRect(x: 72, y: 650, width: 240, height: 28),
            fieldName: "fullName",
            fieldType: .text
        )
        text.widgetDefaultStringValue = "Original"
        text.widgetStringValue = emptyRequiredFields ? "" : "Original"
        text.maximumLength = 12
        _ = text.setValue(NSNumber(value: 1 << 1), forAnnotationKey: .widgetFieldFlags)
        page.addAnnotation(text)

        let checkbox = widget(
            bounds: CGRect(x: 72, y: 610, width: 24, height: 24),
            fieldName: "consent",
            fieldType: .button
        )
        checkbox.widgetControlType = .checkBoxControl
        checkbox.buttonWidgetState = emptyRequiredFields ? .offState : .offState
        checkbox.widgetDefaultStringValue = "Off"
        _ = checkbox.setValue(NSNumber(value: 1 << 1), forAnnotationKey: .widgetFieldFlags)
        page.addAnnotation(checkbox)

        let choice = widget(
            bounds: CGRect(x: 72, y: 560, width: 240, height: 28),
            fieldName: "plan",
            fieldType: .choice
        )
        choice.choices = ["Standard", "Professional"]
        choice.widgetDefaultStringValue = "Standard"
        choice.widgetStringValue = "Standard"
        page.addAnnotation(choice)

        let basic = radioWidget(
            bounds: CGRect(x: 72, y: 520, width: 24, height: 24),
            fieldName: "tier",
            stateName: "Basic",
            selected: true
        )
        let premium = radioWidget(
            bounds: CGRect(x: 120, y: 520, width: 24, height: 24),
            fieldName: "tier",
            stateName: "Premium",
            selected: false
        )
        basic.widgetDefaultStringValue = "Basic"
        premium.widgetDefaultStringValue = "Basic"
        page.addAnnotation(basic)
        page.addAnnotation(premium)

        return document
    }

    private func widget(
        bounds: CGRect,
        fieldName: String,
        fieldType: PDFAnnotationWidgetSubtype
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        annotation.widgetFieldType = fieldType
        annotation.fieldName = fieldName
        return annotation
    }

    private func radioWidget(
        bounds: CGRect,
        fieldName: String,
        stateName: String,
        selected: Bool
    ) -> PDFAnnotation {
        let annotation = widget(bounds: bounds, fieldName: fieldName, fieldType: .button)
        annotation.widgetControlType = .radioButtonControl
        annotation.buttonWidgetStateString = stateName
        annotation.buttonWidgetState = selected ? .onState : .offState
        return annotation
    }

    private func widget(named name: String, in document: PDFDocument) -> PDFAnnotation? {
        (0..<document.pageCount).lazy.compactMap { document.page(at: $0) }.flatMap(\.annotations)
            .first { $0.type == PDFAnnotationSubtype.widget.pdfTypeName && $0.fieldName == name }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PDFViewerFormTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
