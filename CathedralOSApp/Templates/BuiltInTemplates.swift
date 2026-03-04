import Foundation

enum BuiltInTemplates {
    static let all: [ProfileTemplate] = [work, home, training, founder, busyParent]

    static let work = ProfileTemplate(
        templateName: "Work",
        defaultProfileName: "Work",
        roles: ["Employee"],
        domains: ["Work"],
        seasons: ["Normal capacity"],
        resources: ["Calendar", "Email", "Task list"],
        preferences: ["Short iterations", "Clear next actions"],
        failurePatterns: ["Context switching kills momentum"],
        goals: ["Make steady progress on top priorities"],
        constraints: ["Meetings fragment the day", "Limited deep work blocks"]
    )

    static let home = ProfileTemplate(
        templateName: "Home",
        defaultProfileName: "Home",
        roles: ["Partner", "Household manager"],
        domains: ["Family", "Home"],
        seasons: ["Normal capacity"],
        resources: ["Shared calendar", "Checklists"],
        preferences: ["Simple routines", "Batch chores"],
        failurePatterns: ["Letting clutter accumulate"],
        goals: ["Reduce household friction"],
        constraints: ["Time is limited on weekdays"]
    )

    static let training = ProfileTemplate(
        templateName: "Training",
        defaultProfileName: "Training",
        roles: ["Athlete"],
        domains: ["Health", "Training"],
        seasons: ["Training block"],
        resources: ["Gym/garage setup"],
        preferences: ["Progress tracking", "Recovery first"],
        failurePatterns: ["Doing too much too soon"],
        goals: ["Train consistently 3–5x/week"],
        constraints: ["Sleep and recovery limit volume"]
    )

    static let founder = ProfileTemplate(
        templateName: "Founder",
        defaultProfileName: "Founder",
        roles: ["Founder", "Builder"],
        domains: ["Work", "Business", "Creative"],
        seasons: ["High focus"],
        resources: ["GitHub", "Automation", "User feedback"],
        preferences: ["Ship small", "Fast feedback"],
        failurePatterns: ["Overbuilding before validation"],
        goals: ["Validate one offer", "Ship weekly improvements"],
        constraints: ["Time and focus stretched thin"]
    )

    static let busyParent = ProfileTemplate(
        templateName: "Busy Parent",
        defaultProfileName: "Busy Parent",
        roles: ["Parent", "Employee"],
        domains: ["Family", "Work", "Health"],
        seasons: ["Low bandwidth"],
        resources: ["Routines", "Meal plan"],
        preferences: ["Low-friction habits", "Short blocks"],
        failurePatterns: ["All-or-nothing planning"],
        goals: ["Keep the week stable", "Protect energy"],
        constraints: ["Interrupted time", "Unpredictable schedule"]
    )
}
