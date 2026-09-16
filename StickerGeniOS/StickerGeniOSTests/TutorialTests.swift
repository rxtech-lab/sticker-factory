import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Tutorial navigation and progress")
@MainActor
struct TutorialTests {
    @Test func localesFollowAppLanguageOrder() {
        #expect(TutorialLocation.locale(["zh-Hant-TW", "en"]) == "zh-HK")
        #expect(TutorialLocation.locale(["zh-Hans-CN"]) == "zh-CN")
        #expect(TutorialLocation.locale(["en-GB", "zh-HK"]) == "en")
        #expect(TutorialLocation.locale(["fr"]) == "en")
    }
    @Test func actionLinksNeverCarryMutations() throws {
        #expect(TutorialDeepLink(url: try #require(URL(string: "stickerfactory://open/create?kind=animated&controllable=1"))) == .action(.create(animated: true, controllable: true)))
        #expect(TutorialDeepLink(url: try #require(URL(string: "stickerfactory://open/pack?action=whatsapp"))) == .action(.pack(destination: "whatsapp")))
        for value in ["stickerfactory://open/generate", "stickerfactory://open/packs/new?publish=1", "stickerfactory://open/create?kind=static&controllable=1", "stickerfactory://open/create?kind=static&kind=animated", "stickerfactory://oauth/callback?code=abc", "stickerfactory://tutorial/../secret", "stickerfactory://tutorial/a%2Fb"] {
            #expect(TutorialDeepLink(url: try #require(URL(string: value))) == nil)
        }
    }
    @Test func progressSurvivesReopeningAndLanguageChanges() throws {
        let name = "tutorial-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TutorialProgressStore(defaults: defaults)
        store.record(chapter: "controllable", step: "controls", completed: true)
        store.record(chapter: "../bad", step: "controls", completed: false)
        let reloaded = TutorialProgressStore(defaults: defaults)
        #expect(reloaded.progress.completed == ["controllable"])
        #expect(reloaded.progress.steps.count == 1)
        let base = try #require(URL(string: "https://sticker.rxlab.app"))
        let url = TutorialLocation.url(base: base, request: .init(chapter: "controllable"), progress: reloaded.progress, languages: ["zh-HK"])
        #expect(url.absoluteString == "https://sticker.rxlab.app/tutorial/zh-HK/controllable?step=controls")
        #expect(TutorialLocation.url(base: base, request: .init(chapter: "controllable", step: "enable"), progress: reloaded.progress).query == "step=enable")
    }
    @Test func publicContentRequiresExactOriginAndTutorialPath() throws {
        let base = try #require(URL(string: "https://sticker.rxlab.app"))
        #expect(TutorialContentClient(baseURL: base).accepts(try #require(URL(string: "https://sticker.rxlab.app/api/v1/tutorial/en"))))
        for value in ["http://sticker.rxlab.app/tutorial/en", "https://sticker.rxlab.app.evil.test/tutorial/en", "https://sticker.rxlab.app:444/tutorial/en", "https://sticker.rxlab.app/library", "https://sticker.rxlab.app/tutorial-other/en"] {
            #expect(!TutorialContentClient(baseURL: base).accepts(try #require(URL(string: value))))
        }
    }
    @Test func structuredContentValidatesBeforeRendering() throws {
        let source = #"""
{"version":1,"locale":"en","strings":{"title":"Tutorials","intro":"A little guidance. A lot of sticker magic.","create":"Create stickers","finish":"Finish your sticker","packs":"Sticker packs","next":"Next","back":"Back","done":"Finish chapter","index":"All chapters","resume":"Continue reading","tryIt":"Try it in the app","completed":"Completed","step":"Step","of":"of","play":"Play demonstration","pause":"Pause demonstration","restart":"Read again","nextChapter":"Next chapter","mediaError":"This image could not load. Try again when you are online.","retry":"Retry","language":"Language","tip":"A little tip","appHint":"Opens Winky Sticker Factory. It will not generate or send anything.","read":"Read chapter"},"sections":[{"id":"create","title":"Create stickers"},{"id":"finish","title":"Finish your sticker"},{"id":"packs","title":"Sticker packs"}],"chapters":[{"id":"static","title":"Make a static sticker","section":"create","steps":[{"id":"choose","title":"Start with Static","blocks":[{"type":"paragraph","text":"Open Create from Library and choose Static. Start with one clear subject and a simple expression."},{"type":"media","id":"create-static","caption":"Start with Static","poster":"/tutorial/media/en/create-static.webp"}],"action":"stickerfactory://open/create?kind=static"}]}]}
"""#
        let document = try JSONDecoder().decode(TutorialDocument.self, from: Data(source.utf8)).validated()
        #expect(document.chapters.first?.steps.first?.blocks.count == 2)
        for invalid in [source.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), source.replacingOccurrences(of: "/tutorial/media/en/create-static.webp", with: "https://evil.test/image.webp"), source.replacingOccurrences(of: "stickerfactory://open/create?kind=static", with: "stickerfactory://open/generate")] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(TutorialDocument.self, from: Data(invalid.utf8)).validated()
            }
        }
    }

}
