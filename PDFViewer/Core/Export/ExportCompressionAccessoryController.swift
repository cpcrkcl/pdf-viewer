import AppKit

/// Save-panel accessory that lets the user pick an output-size profile.
/// The selection applies only to the one export being confirmed; Standard
/// remains the default so exports never silently re-encode images.
@MainActor
final class ExportCompressionAccessoryController: NSObject {
    let view: NSView

    private let popUpButton: NSPopUpButton
    private let summaryLabel: NSTextField

    var selectedCompression: PDFExportCompression {
        let profiles = PDFExportCompression.allCases
        let index = popUpButton.indexOfSelectedItem
        guard profiles.indices.contains(index) else {
            return .standard
        }
        return profiles[index]
    }

    override init() {
        let titleLabel = NSTextField(labelWithString: "File Size:")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        for profile in PDFExportCompression.allCases {
            popUpButton.addItem(withTitle: profile.title)
        }
        popUpButton.setAccessibilityLabel("Export file size profile")

        let summaryLabel = NSTextField(
            wrappingLabelWithString: PDFExportCompression.standard.summary
        )
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let selectionRow = NSStackView(views: [titleLabel, popUpButton])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 8

        let stackView = NSStackView(views: [selectionRow, summaryLabel])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            stackView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            stackView.leadingAnchor.constraint(
                greaterThanOrEqualTo: containerView.leadingAnchor
            ),
            stackView.trailingAnchor.constraint(
                lessThanOrEqualTo: containerView.trailingAnchor
            ),
        ])

        self.view = containerView
        self.popUpButton = popUpButton
        self.summaryLabel = summaryLabel
        super.init()

        popUpButton.target = self
        popUpButton.action = #selector(selectionChanged(_:))
    }

    @objc
    private func selectionChanged(_ sender: NSPopUpButton) {
        summaryLabel.stringValue = selectedCompression.summary
    }
}
