// TestMode+Scripts.swift
// The scripted AI replies and web search used in test mode (Debug builds only): three believable sample ideas,
// a Reimagine run and checked prices, for the screen tests and the App Store screenshots. Every app, company and
// marketplace name here is made up (store listing rules: no real names in screenshots).

import Foundation

#if DEBUG
/// Scripted replies, keyed by the feature name each call passes.
enum TestModeScripts {
    /// Made-up competitors and their pricing pages (the web search "returns" these links).
    static let pricingPages = ["https://example.com/dunningdesk/pricing", "https://example.com/rosterbase/pricing",
                               "https://example.com/plantpal/pricing", "https://example.com/tasktidy/pricing",
                               "https://example.com/forum/families", "https://example.com/forum/chores",
                               "https://example.com/blog/tasktidy-review", "https://example.com/famplan/pricing"]

    static func reply(feature: String, system: String, prompt: String) -> String {
        switch feature {
        case "Trends": trends
        case "Starter kit": starterKit
        case "Improve idea": improved
        case "Killer ideas": ideas
        case "Reimagine directions": directions
        case "Reimagine idea": reimaginedIdea
        case "Price check", "Reimagine an app":
            system == Reimagine.profileInstructions ? profile
                : system == Undercut.formatInstructions ? groupCheck : prices(for: prompt)
        default: reviews
        }
    }

    private static let trends = #"{"themes":[{"title":"Invoice reminders for trades","summary":"Small trades businesses spend hours chasing unpaid invoices by hand.","opportunities":["Reminders that sound like you","A weekly 'who owes me' list"],"item_numbers":[2,3],"novelty":4,"novelty_reason":"New tools appear weekly.","viability":4,"viability_reason":"People already pay for this.","opportunity_gap":4,"opportunity_gap_reason":"Existing tools are pricey."},{"title":"Rosters for tiny teams","summary":"Cafes and clinics juggle shifts in group chats.","opportunities":["One-tap shift swaps"],"item_numbers":[2],"novelty":3,"novelty_reason":"r","viability":4,"viability_reason":"r","opportunity_gap":3,"opportunity_gap_reason":"r"}],"translations":[],"pain_clusters":[{"title":"Chasing unpaid invoices","buyer":"Sole-trader plumbers and electricians","workaround":"Copy-pasted reminder emails","pay_signals":"Pay $40+ a month for dunning tools","summary":"Overdue invoices eat into evenings.","item_numbers":[1]},{"title":"Shift swaps by group chat","buyer":"Small cafe owners","workaround":"WhatsApp and paper rosters","pay_signals":"Rostering apps from $30 a month","summary":"Swaps get lost in chat.","item_numbers":[1]}],"noise_numbers":[]}"#

    private static func idea(_ title: String, _ pitch: String, _ buyer: String, _ job: String, _ keep: String, _ leave: String,
                             _ competitor: String, _ theirs: Int, _ price: Int, _ channel: String) -> String {
        #"{"title":"\#(title)","pitch":"\#(pitch)","buyer":"\#(buyer)","pricing":"$\#(price) a month","why_now":"Phones now send reliable automated messages cheaply.","one_week_test":"Post in two trade groups; 20 sign-ups to a waitlist is a pass.","replaces":"An hour a week of manual follow-up","channel":"\#(channel)","evidence_numbers":[1],"same_as":"","one_job":"\#(job)","keep_features":[\#(keep)],"leave_out_features":[\#(leave)],"competitors":[{"name":"\#(competitor)","cheapest_plan":"Starter","price_per_month_usd":\#(theirs),"is_free":false}],"fills_gap":false,"price_per_month_usd":\#(price),"sales_model":"subscription","sales_model_reason":"It sends messages every month, which costs a little per customer."}"#
    }

    private static let ideas = #"{"ideas":["# + [
        idea("NudgeBill", "Polite invoice reminders for tradies, sent from your phone.", "Sole-trader plumbers and electricians",
             "Chase overdue invoices", #""Friendly reminders","Who owes me list""#, #""Payroll","Quotes""#,
             "DunningDesk", 40, 9, "Trade association newsletters"),
        idea("ShiftSwap", "Shift swaps for small cafes, approved in one tap.", "Cafe owners with 5–15 staff",
             "Swap shifts without a group chat", #""Swap requests","Weekly roster""#, #""Payroll","Time clocks""#,
             "RosterBase", 32, 7, "Hospitality owners' forums"),
        idea("PlantPal Pro", "Watering rounds for indoor plant hire businesses.", "Indoor plant hire businesses",
             "Plan watering rounds", #""Round planner","Client notes""#, #""Invoicing","Inventory""#,
             "GreenRound", 24, 5, "Plant hire Facebook groups"),
    ].joined(separator: ",") + "]}"

    private static func review(_ title: String, _ objection: String) -> String {
        #"{"title":"\#(title)","survives":true,"objection":"\#(objection)","competitors":"Established tools cost much more.","verdict":"Worth a one-week test.","pain":4,"willing_to_pay":4,"timing":4,"gap":4,"fit":4,"buildability":4,"channel_score":4,"evidence_needed":"Ten owners saying they'd switch.","build_days":10,"likely_customers":40,"competitors_found":[],"follow_risk":"Unlikely: the big tools serve larger firms.","copy_risk":"Being known in the trade groups first.","keep_paying":"Yes, it saves time every month.","sales_model":"subscription","sales_model_reason":"Messages cost a little every month.","running_cost_per_customer_usd":0.5,"other_yearly_costs_usd":20,"monthly_churn_percent":4}"#
    }

    private static let reviews = #"{"reviews":["# + [
        review("NudgeBill", "Accounting apps could add reminders for free."),
        review("ShiftSwap", "Owners may stick with the group chat they know."),
        review("PlantPal Pro", "A small market; reaching owners takes time."),
        review("FamilyChores", "Families already use free shared lists."),
    ].joined(separator: ",") + "]}"

    /// The checked price of the one competitor of the idea named in the prompt (the scripted search echoes it).
    private static func prices(for prompt: String) -> String {
        let all = [("NudgeBill", "DunningDesk", "Starter", 40, "dunningdesk"), ("ShiftSwap", "RosterBase", "Team", 32, "rosterbase"),
                   ("PlantPal Pro", "GreenRound", "Solo", 24, "plantpal"), ("FamilyChores", "FamPlan", "Family", 8, "famplan")]
        let found = all.filter { prompt.contains($0.0) }.map {
            #"{"name":"\#($0.1)","cheapest_plan":"\#($0.2)","price_per_month_usd":\#($0.3),"is_free":false,"url":"https://example.com/\#($0.4)/pricing"}"#
        }
        return #"{"competitors":["# + found.joined(separator: ",") + "]}"
    }

    private static let starterKit = #"{"spec":"An iPhone app that sends polite reminders for overdue invoices and keeps a 'who owes me' list for sole traders.","screens":[{"name":"Who owes me","purpose":"See overdue invoices, oldest first."},{"name":"Reminder","purpose":"Preview and send a friendly reminder."}],"data_model":[{"entity":"Invoice","fields":["client (text)","amount (number)","due date (date)"],"notes":"Stored on the phone."}],"stack":[{"part":"App","choice":"SwiftUI with SwiftData","why":"Free, and everything stays on the phone."}],"monthly_cost":"About $0.50 a customer for messages.","leave_out":["Payments: link to the invoice instead."],"first_slice":"Add invoices and list the overdue ones.","done_when":["Overdue invoices are listed, oldest first."],"project_rules":["Keep keys out of the code."]}"#

    private static let improved = #"{"pitch":"Polite invoice reminders for plumbers, sent from your phone.","buyer":"Sole-trader plumbers","pricing":"$7 a month","replaces":"Manual follow-up emails","channel":"Plumbers' association newsletter","why_now":"w","one_week_test":"t","one_job":"Chase overdue invoices","keep_features":["Reminders"],"leave_out_features":["Payroll"],"price_per_month_usd":7,"changes":"Narrowed to plumbers."}"#

    /// A saved Reimagine run for "TaskTidy", built through the real parsers, so the screenshots can open it from
    /// "Recent apps" without typing.
    static func sampleRun() -> Reimagine.Run? {
        func wrapped(_ json: String) -> Data? {
            try? JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        }
        guard let profileData = wrapped(profile), let directionsData = wrapped(directions),
              let parsed = try? Reimagine.parseProfile(profileData, sources: Set(pricingPages), target: Undercut.Target(name: "TaskTidy"))
        else { return nil }
        var run = Reimagine.Run(target: parsed.target, profile: parsed.profile)
        run.evidence = parsed.items.map(Reimagine.Evidence.init)
        run.directions = (try? Reimagine.parseDirections(directionsData, items: run.items)) ?? []
        run.directionsMade = true
        return run
    }

    // Reimagine "TaskTidy", a made-up to-do app.
    private static let profile = #"{"what_it_does":"TaskTidy is a to-do list app with projects, tags and reminders. It's built for one person organising their own work.","who_its_for":"Freelancers and professionals planning their week","plans":[{"name":"TaskTidy","plan":"Pro","price_per_month_usd":8,"url":"https://example.com/tasktidy/pricing"}],"likes":[{"text":"Clean design and fast to add tasks","who":"","url":"https://example.com/blog/tasktidy-review"}],"complaints":[{"text":"No way to share a list with my partner and kids","who":"Parents","url":"https://example.com/forum/families"},{"text":"Chores can't repeat for different people each week","who":"Parents","url":"https://example.com/forum/chores"}],"alternatives":[{"name":"FamPlan","plan":"Family","price_per_month_usd":8,"url":"https://example.com/famplan/pricing"}],"already_built":[]}"#

    private static let directions = #"{"directions":[{"who":"Busy parents","job":"Share a weekly chore rota with the family","evidence_numbers":[1,2],"why_not_the_app":"It's built for one person, not a household.","already_served_by":"FamPlan, at $8 a month","rough_price":"$2 a month","strength":"strong"}]}"#

    private static let groupCheck = #"{"app_plan":"","price_per_month_usd":0,"price_url":"","summary":"","findings":[{"kind":"paid_plan","title":"FamPlan Family is $8 a month","detail":"Shared calendars and lists.","url":"https://example.com/famplan/pricing"}]}"#

    private static let reimaginedIdea = #"{"ideas":["# + idea("FamilyChores", "A weekly chore rota the whole family can see and tick off.",
        "Parents of school-age children", "Rotate chores fairly each week", #""Shared list","Reminders""#,
        #""Projects","Tags""#, "FamPlan", 8, 2, "Parenting forums and school newsletters") + "]}"
}
#endif
