import Foundation

enum ProfileFactory {
    static func createProfile(from template: ProfileTemplate, name: String) -> CathedralProfile {
        let profile = CathedralProfile(name: name)

        for title in template.roles {
            profile.roles.append(Role(title: title))
        }
        for title in template.domains {
            profile.domains.append(Domain(title: title))
        }
        for title in template.seasons {
            profile.seasons.append(Season(title: title))
        }
        for title in template.resources {
            profile.resources.append(Resource(title: title))
        }
        for title in template.preferences {
            profile.preferences.append(Preference(title: title))
        }
        for title in template.failurePatterns {
            profile.failurePatterns.append(FailurePattern(title: title))
        }
        for title in template.goals {
            profile.goals.append(Goal(title: title))
        }
        for title in template.constraints {
            profile.constraints.append(Constraint(title: title))
        }

        return profile
    }
}
