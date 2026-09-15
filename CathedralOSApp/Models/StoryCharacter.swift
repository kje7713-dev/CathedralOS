import Foundation
import SwiftData

@objc(SafeStringArrayTransformer)
final class SafeStringArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    static let name = NSValueTransformerName(rawValue: "SafeStringArrayTransformer")

    override static var allowedTopLevelClasses: [AnyClass] {
        [NSArray.self, NSString.self]
    }

    /// Register before any ModelContainer reads a Transformable attribute.
    /// Safe to call multiple times; ValueTransformer dedupes by name.
    static func register() {
        ValueTransformer.setValueTransformer(
            SafeStringArrayTransformer(),
            forName: name,
        )
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return [] }
        do {
            let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSArray.self, NSString.self],
                from: data,
            )
            return decoded as? [String] ?? []
        } catch {
            // Legacy / corrupted Transformable blobs return [] instead of
            // crashing the entire fetch. This matches the documented
            // NSSecureUnarchiveFromDataTransformer contract.
            return []
        }
    }
}

@Model
class StoryCharacter {
    var id: UUID
    var name: String

    // MARK: Basic
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var roles: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var goals: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var preferences: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var resources: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var failurePatterns: [String]

    // MARK: Advanced
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var fears: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var flaws: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var secrets: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var wounds: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var contradictions: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var needs: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var obsessions: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var attachments: [String]
    var notes: String?
    var instructionBias: String?

    // MARK: Literary
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var selfDeceptions: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var identityConflicts: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var moralLines: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var breakingPoints: [String]
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var virtues: [String]
    var publicMask: String?
    var privateLogic: String?
    var speechStyle: String?
    var arcStart: String?
    var arcEnd: String?
    var coreLie: String?
    var coreTruth: String?
    var reputation: String?
    var status: String?

    // MARK: Field depth
    var fieldLevel: String
    @Attribute(.transformable(by: SafeStringArrayTransformer.self))
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.roles = []
        self.goals = []
        self.preferences = []
        self.resources = []
        self.failurePatterns = []
        self.fears = []
        self.flaws = []
        self.secrets = []
        self.wounds = []
        self.contradictions = []
        self.needs = []
        self.obsessions = []
        self.attachments = []
        self.notes = nil
        self.instructionBias = nil
        self.selfDeceptions = []
        self.identityConflicts = []
        self.moralLines = []
        self.breakingPoints = []
        self.virtues = []
        self.publicMask = nil
        self.privateLogic = nil
        self.speechStyle = nil
        self.arcStart = nil
        self.arcEnd = nil
        self.coreLie = nil
        self.coreTruth = nil
        self.reputation = nil
        self.status = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
