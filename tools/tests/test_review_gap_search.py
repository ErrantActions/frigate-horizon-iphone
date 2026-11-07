import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TestReviewGapSearch(unittest.TestCase):
    def test_initial_empty_window_and_native_gap_seek_share_bounded_frame_search(self):
        source = (ROOT / "App/Media/RecordingPlayer.swift").read_text(encoding="utf-8")
        prepare = source.split("private func prepareResolved(")[1].split("private func install(")[0]
        seek = source.split("private func resolveSeek(")[1].split("private var visibleViewer")[0]
        for block in [prepare, seek]:
            self.assertIn("RecordedHTTPFrameSearch.nextFrame(", block)
            self.assertNotIn("resolution.usableTimestamp()", block)
            self.assertNotIn("next + 3600", block)
        self.assertIn("playing: playing", prepare)

    def test_missing_footage_has_its_own_state_and_semantic_diagnostics(self):
        source = (ROOT / "App/Media/RecordingPlayer.swift").read_text(encoding="utf-8")
        self.assertIn("metrics.coreFailure = (failure as? RecordedHTTPError)?.diagnosticIdentifier", source)
        self.assertIn('metrics.coreFailure == "gap"', source)
        self.assertIn("ContentUnavailableView(owner.emptyStateTitle", source)
        self.assertIn("failure reason:", source)

    def test_search_does_not_create_media_or_skip_unknown_ranges(self):
        source = (ROOT / "Sources/HorizonCore/RecordedHTTPFrameSearch.swift").read_text(encoding="utf-8")
        for value in ["maximumRequests = 26", "cursor + 3600", "try Task.checkCancellation()",
                      "result.exhausted, result.searchedBefore == request.before",
                      "cursor = request.before", "RecordedHTTPError.searchLimit"]:
            self.assertIn(value, source)
        for value in [".create(", ".mediaInfo(", "AVPlayer", "urlSession", "heartbeat"]:
            self.assertNotIn(value, source)
