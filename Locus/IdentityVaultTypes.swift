import Foundation

enum IdentityVaultProfileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal, business, career
    var id: String { rawValue }
    var title: String {
        switch self { case .personal: "Personal"; case .business: "Business"; case .career: "Career" }
    }
    var symbol: String {
        switch self { case .personal: "person.text.rectangle"; case .business: "building.2"; case .career: "briefcase" }
    }
    var templateFields: [IdentityVaultField] {
        let contact: [IdentityVaultField] = [
            .init(key: "full_name", label: "Full name"),
            .init(key: "email", label: "Email", kind: .email),
            .init(key: "phone", label: "Phone", kind: .phone),
            .init(key: "street_address", label: "Street address", kind: .multiline),
            .init(key: "city", label: "City"), .init(key: "region", label: "Province / State"),
            .init(key: "postal_code", label: "Postal / ZIP code"), .init(key: "country", label: "Country"),
        ]
        switch self {
        case .personal: return contact + [
            .init(key: "date_of_birth", label: "Date of birth", kind: .date),
            .init(key: "website", label: "Website", kind: .url),
        ]
        case .business: return [
            .init(key: "business_name", label: "Business name"),
            .init(key: "legal_name", label: "Legal business name"),
            .init(key: "registration_number", label: "Registration number", kind: .identifier),
            .init(key: "tax_id", label: "Tax identifier", kind: .identifier),
            .init(key: "website", label: "Business website", kind: .url),
            .init(key: "business_description", label: "Business description", kind: .multiline),
            .init(key: "billing_address", label: "Billing address", kind: .multiline),
            .init(key: "shipping_address", label: "Shipping address", kind: .multiline),
        ] + contact
        case .career: return contact + [
            .init(key: "headline", label: "Professional title"),
            .init(key: "professional_summary", label: "Professional summary", kind: .multiline),
            .init(key: "skills", label: "Skills", kind: .multiline),
            .init(key: "employment_1", label: "Employment 1", kind: .multiline),
            .init(key: "education_1", label: "Education 1", kind: .multiline),
            .init(key: "certifications", label: "Certifications", kind: .multiline),
            .init(key: "portfolio", label: "Portfolio", kind: .url),
            .init(key: "linkedin", label: "LinkedIn", kind: .url),
        ]
        }
    }
}

enum IdentityVaultFieldKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, multiline, email, phone, date, url, identifier
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: "Text"; case .multiline: "Long text"; case .email: "Email"
        case .phone: "Phone"; case .date: "Date"; case .url: "Website"; case .identifier: "Identifier"
        }
    }
}

struct IdentityVaultField: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var key: String
    var label: String
    var value = ""
    var kind: IdentityVaultFieldKind = .text
}

struct IdentityVaultProfile: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: IdentityVaultProfileKind
    var fields: [IdentityVaultField]
    var revision = 1
    var createdAt = Date()
    var updatedAt = Date()

    init(id: UUID = UUID(), name: String, kind: IdentityVaultProfileKind, fields: [IdentityVaultField]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fields = fields ?? kind.templateFields
    }

    /// Repeated career entries keep their own stable field IDs and order.
    mutating func appendCareerEntry(education: Bool) {
        let prefix = education ? "education" : "employment"
        var ordinal = 1
        while fields.contains(where: { $0.key == "\(prefix)_\(ordinal)" }) { ordinal += 1 }
        fields.append(.init(key: "\(prefix)_\(ordinal)", label: "\(education ? "Education" : "Employment") \(ordinal)", kind: .multiline))
    }
}

enum IdentityVaultDocumentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case resume, coverLetter, signature, business, identity, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .resume: "Résumé"; case .coverLetter: "Cover letter"; case .signature: "Signature"
        case .business: "Business document"; case .identity: "Identity document"; case .other: "Other document"
        }
    }
}

/// Each record is one immutable version. Original bytes live in a separate encrypted blob.
struct IdentityVaultDocument: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let groupID: UUID
    let version: Int
    let blobID: UUID
    let profileID: UUID?
    let name: String
    let kind: IdentityVaultDocumentKind
    let mimeType: String
    let byteCount: Int
    let contentHash: String
    let extractedText: String
    let createdAt: Date
}

struct IdentityVaultDocumentSection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var heading: String
    var text: String
}

struct IdentityVaultDraft: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var profileID: UUID?
    var title: String
    var kind: IdentityVaultDocumentKind = .resume
    var sections: [IdentityVaultDocumentSection] = []
    var revision = 1
    var createdAt = Date()
    var updatedAt = Date()
}

enum IdentityVaultDisclosureKind: String, Codable, CaseIterable, Sendable {
    case provider, website, export
}

/// Private audit information. This record is never a model-facing tool result.
struct IdentityVaultDisclosure: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var taskID: String
    var recipientID: String
    var recipientLabel: String
    var kind: IdentityVaultDisclosureKind
    var summary: String
    var fieldIDs: [UUID] = []
    var documentIDs: [UUID] = []
    var snapshotID: UUID?
    var createdAt = Date()
    var outcome: String? = "Completed"
}

struct IdentityVaultImportedDocument: Sendable {
    let name: String
    let mimeType: String
    let data: Data
    let extractedText: String
}

enum IdentityVaultError: LocalizedError {
    case unavailable, corrupt, unsupportedVersion, invalidRecord, staleRevision, missingDocument
    case tooLarge, unsupportedDocument, extractionFailed, helperUnavailable, cancelled
    case keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Identity Vault is locked or unavailable. Open it and try again."
        case .corrupt: "The encrypted vault could not be opened. Its saved data has not been changed."
        case .unsupportedVersion: "This vault was saved by a newer version of Locus. Update Locus to open it."
        case .invalidRecord: "Check the record name and fields. Every field needs a unique key and a label."
        case .staleRevision: "This item changed while it was open. Reopen it before saving."
        case .missingDocument: "That document version is no longer available."
        case .tooLarge: "Vault documents must be 100 MB or smaller; extracted text must be 5 MB or smaller."
        case .unsupportedDocument: "Choose a PDF, Word (.docx), plain text, PNG, JPEG, or HEIC file."
        case .extractionFailed: "This document could not be read locally. Check that it is valid and unlocked."
        case .helperUnavailable: "The bundled Word document helper is unavailable. Rebuild or reinstall Locus."
        case .cancelled: "The vault operation was cancelled."
        case .keychain(let status): "Identity Vault could not access its encryption key (\(status)). Unlock your Mac and try again."
        }
    }
}
