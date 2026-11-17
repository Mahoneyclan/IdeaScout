// SourceChangesTests.swift
// The 17 Nov 2026 source changes: WordPress plugin complaints (plugin list and review feed parsing, daily pick),
// App Store complaints from apps ranked 26–100 with the interest area first, Y Combinator no longer read, and
// Atlassian Marketplace off for new installs only. Samples are trimmed copies of real replies; no network.

import Foundation
import Testing
@testable import IdeaScout

/// Recorded WordPress.org replies (17 Nov 2026), trimmed to a few entries.
enum WordPressSamples {
    /// `query_plugins` for the "invoice" tag: one popular plugin, one too small, one with an unsafe slug.
    static let plugins = #"""
    {"info":{"page":1,"pages":55,"results":109},"plugins":[
     {"name":"Sliced Invoices &#8211; WordPress Invoice Plugin","slug":"sliced-invoices","version":"3.10.1","rating":92,
      "ratings":{"5":97,"4":6,"3":5,"2":1,"1":8},"num_ratings":117,"active_installs":4000,
      "short_description":"A WordPress invoicing plugin for creating invoices and quotes.","homepage":"http:\/\/slicedinvoices.com\/"},
     {"name":"Tiny Quotes","slug":"tiny-quotes","rating":100,"ratings":[],"num_ratings":0,"active_installs":10,"short_description":"Quotes"},
     {"name":"Odd","slug":"odd\/..\/x","active_installs":9000,"short_description":"x"}]}
    """#

    /// A plugin's reviews feed: a 4-star, a 1-star and an old 2-star review.
    static func reviews(recent: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let day = formatter.string(from: recent)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel><title>WordPress.org Forums &#187; [Sliced Invoices] Reviews</title>
        <item><guid>https://wordpress.org/support/topic/good-plugin-7047/</guid><title>Good Plugin (4 stars)</title>
        <link>https://wordpress.org/support/topic/good-plugin-7047/</link><pubDate>\(day)</pubDate><dc:creator>a</dc:creator>
        <description><![CDATA[<p>Replies: 0</p><p>Rating: 4 stars</p><p class="wp-block-paragraph">Helpful.</p>]]></description></item>
        <item><guid>https://wordpress.org/support/topic/pdf-broken/</guid><title>PDF broken after update (1 star)</title>
        <link>https://wordpress.org/support/topic/pdf-broken/</link><pubDate>\(day)</pubDate><dc:creator>b</dc:creator>
        <description><![CDATA[<p>Replies: 1</p><p>Rating: 1 star</p><p class="wp-block-paragraph">The PDF won&#8217;t generate and support never answered.</p>]]></description></item>
        <item><guid>https://wordpress.org/support/topic/old/</guid><title>Old moan (2 stars)</title>
        <link>https://wordpress.org/support/topic/old/</link><pubDate>Tue, 21 Nov 2023 20:29:37 +0000</pubDate><dc:creator>c</dc:creator>
        <description><![CDATA[<p>Replies: 0</p><p>Rating: 2 stars</p><p>Slow</p>]]></description></item>
        </channel></rss>
        """
    }
}

struct WordPressReviewsTests {
    @Test func keepsPopularPluginsWithSafeSlugs() throws {
        let plugins = try WordPressReviewsFetcher.parsePlugins(Data(WordPressSamples.plugins.utf8), tag: "invoice")
        #expect(plugins.map(\.slug) == ["sliced-invoices"])
        #expect(plugins.first?.name == "Sliced Invoices – WordPress Invoice Plugin")
        #expect(plugins.first?.installs == 4000 && plugins.first?.tag == "invoice")
    }

    @Test func keepsOnlyRecentLowStarReviews() throws {
        let plugin = WordPressReviewsFetcher.Plugin(slug: "sliced-invoices", name: "Sliced Invoices", summary: "",
                                                    installs: 4000, tag: "invoice")
        let since = Date.now.addingTimeInterval(-90 * 86_400)
        let feed = WordPressSamples.reviews(recent: .now.addingTimeInterval(-86_400))
        let items = try WordPressReviewsFetcher.parseReviews(Data(feed.utf8), plugin: plugin, since: since)
        #expect(items.count == 1)
        let review = try #require(items.first)
        #expect(review.title == "Sliced Invoices: PDF broken after update")
        #expect(review.detail.hasPrefix("★1 review of a WordPress plugin ("))
        #expect(review.detail.hasSuffix("invoice): The PDF won’t generate and support never answered."))
        #expect(review.url.absoluteString == "https://wordpress.org/support/topic/pdf-broken/")
        #expect(review.source == .wordpressReviews && review.score == 2)
    }

    @Test func picksPluginsAboutTheInterestAreaFirst() {
        func plugin(_ slug: String, _ summary: String) -> WordPressReviewsFetcher.Plugin {
            .init(slug: slug, name: slug, summary: summary, installs: 5000, tag: "booking")
        }
        let others = (1...20).map { plugin("p\($0)", "Generic booking forms") }
        let salon = [plugin("salon-a", "Appointments for hair salons"), plugin("salon-b", "Salon calendar")]
        let picked = WordPressReviewsFetcher.todaysPlugins(others + salon + salon, day: 5,
                                                           areaWords: AreaFocus.words(in: "hair salons"))
        #expect(picked.count == WordPressReviewsFetcher.pluginsPerDay)
        #expect(picked.prefix(2).map(\.slug) == ["salon-a", "salon-b"], "area matches first, duplicates removed")
        #expect(Set(picked.map(\.slug)).count == picked.count)
    }
}

struct AppReviewsMidRankTests {
    private func app(_ rank: Int, _ name: String = "App", genre: String = "Business") -> AppReviewsFetcher.App {
        .init(id: "\(rank)", name: "\(name) \(rank)", country: "au", genre: genre, rank: rank)
    }

    @Test func readsAppsRankedBelowTheTop25() {
        let chart = (1...100).map { app($0) }
        let today = AppReviewsFetcher.todaysApps(chart, day: 3)
        #expect(today.count == AppReviewsFetcher.appsPerDay)
        #expect(today.allSatisfy { AppReviewsFetcher.ranks.contains($0.rank) })
        #expect(Set(today.map(\.id)) != Set(AppReviewsFetcher.todaysApps(chart, day: 4).map(\.id)), "rotates daily")
    }

    @Test func prefersAppsAboutTheInterestArea() {
        let chart = (1...100).map { app($0, $0 == 3 || $0 == 60 ? "Salon Booker" : "App") }
        let today = AppReviewsFetcher.todaysApps(chart, day: 3, areaWords: AreaFocus.words(in: "salon"))
        #expect(today.first?.rank == 60, "the top-3 giant is still skipped")
        #expect(!today.contains { $0.rank == 3 })
    }

    @Test func shortChartFallsBackToSkippingTheTop5() {
        let today = AppReviewsFetcher.todaysApps((1...20).map { app($0) }, day: 1)
        #expect(!today.isEmpty && today.allSatisfy { $0.rank > 5 })
    }
}

struct SourceSettingsTests {
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "com.mahoney.IdeaScout.tests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return try #require(UserDefaults(suiteName: suite))
    }

    @MainActor @Test func yCombinatorIsNoLongerRead() {
        #expect(!SourceKind.ycombinator.isScanSource)
        #expect(SourceKind.ycombinator.rawValue == "ycombinator", "stored in the database: never rename")
        #expect(!DigestService.enabledFetchers().contains { $0.kind == .ycombinator })
        #expect(SourceKind.wordpressReviews.isScanSource && SourceKind.wordpressReviews.signal == .demand)
        #expect(SourceKind.wordpressReviews.rawValue == "wordpressReviews", "stored in the database: never rename")
    }

    @Test func newInstallStartsWithAtlassianOffAndWordPressOn() throws {
        let defaults = try freshDefaults("newInstall")
        DigestService.applySourceChanges(defaults: defaults)
        #expect(!AppSettings.isEnabled(.atlassian, in: defaults))
        #expect(AppSettings.isEnabled(.wordpressReviews, in: defaults))
    }

    @Test func existingUserKeepsAtlassianUnlessTheySwitchedItOff() throws {
        let kept = try freshDefaults("existingUser")
        kept.set(true, forKey: AppSettings.Keys.onboarded)
        kept.set(true, forKey: AppSettings.Keys.sourceEnabled(.ycombinator))
        DigestService.applySourceChanges(defaults: kept)
        #expect(AppSettings.isEnabled(.atlassian, in: kept))
        #expect(kept.object(forKey: AppSettings.Keys.sourceEnabled(.ycombinator)) == nil)

        let off = try freshDefaults("existingUserOff")
        off.set(true, forKey: AppSettings.Keys.onboarded)
        off.set(false, forKey: AppSettings.Keys.sourceEnabled(.atlassian))
        DigestService.applySourceChanges(defaults: off)
        #expect(!AppSettings.isEnabled(.atlassian, in: off))

        // Runs once: a later "off" isn't undone at the next launch.
        kept.set(false, forKey: AppSettings.Keys.sourceEnabled(.atlassian))
        DigestService.applySourceChanges(defaults: kept)
        #expect(!AppSettings.isEnabled(.atlassian, in: kept))
    }
}
