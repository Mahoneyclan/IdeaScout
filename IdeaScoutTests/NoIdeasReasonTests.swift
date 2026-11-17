// NoIdeasReasonTests.swift
// Why the Ideas tab is empty (usability review, 17 Nov 2026): the most useful reason first, and nothing extra
// before the first refresh when all is well.

import Testing
@testable import IdeaScout

struct NoIdeasReasonTests {
    @Test func mostUsefulReasonFirst() {
        let noAI = NoIdeasReason.make(hasCloudAI: false, overLimit: true, refreshedToday: true, lastNote: "x")
        #expect(noAI?.needsAISettings == true && noAI?.title == "Ideas need a cloud AI")
        let limit = NoIdeasReason.make(hasCloudAI: true, overLimit: true, refreshedToday: true, lastNote: "x")
        #expect(limit?.title == "Today's spending limit is reached")
        let note = NoIdeasReason.make(hasCloudAI: true, overLimit: false, refreshedToday: true, lastNote: "Every idea was rejected.")
        #expect(note?.message == "Every idea was rejected." && note?.needsAISettings == false)
        #expect(NoIdeasReason.make(hasCloudAI: true, overLimit: false, refreshedToday: true, lastNote: nil)?.title
                == "No ideas from today's refresh")
        #expect(NoIdeasReason.make(hasCloudAI: true, overLimit: false, refreshedToday: false, lastNote: nil) == nil,
                "before the first refresh the status row already says what to do")
    }
}
