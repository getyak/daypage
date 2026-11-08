#!/usr/bin/env python3
"""Exact, host-only planning and native evidence validation. Never executes Xcode.

The reviewed method map is intentionally explicit: new compiled methods require a
reviewed shard decision. Logs are observations; the plan cannot supply observations.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

PROJECT = "DayPageLocal/DayPageLocal.xcodeproj/project.pbxproj"
SCHEME = "DayPageLocal/DayPageLocal.xcodeproj/xcshareddata/xcschemes/DayPage.xcscheme"
GROUPS = {
    "calendar_card_share": [
        "DayPageLocalUITests/CalendarUITests/testRecordCountsCancelAndExactEmptyDayCommit",
        "DayPageLocalUITests/CalendarUITests/testLargeTextMonthNavigationRetainsSelectionUntilDone",
        "DayPageLocalUITests/CardShareUITests/testShortRightDragDoesNotOpenNoteDetail",
        "DayPageLocalUITests/CardShareUITests/testSmallTouchMovementStillOpensNote",
        "DayPageLocalUITests/CardShareUITests/testBodyLongPressKeepsCardActionsAndDoesNotOpenDetail",
        "DayPageLocalUITests/CardShareUITests/testFullSwipesRevealActionsWithoutOpeningAnotherScreen",
        "DayPageLocalUITests/CardShareUITests/testDiagonalDragDoesNotOpenNoteDetail",
        "DayPageLocalUITests/CardShareUITests/testSidebarEdgeSwipesKeepNoteDetailsClosed",
        "DayPageLocalUITests/CardShareUITests/testArchiveAndSearchShortDragsKeepDetailsClosed",
        "DayPageLocalUITests/CardShareUITests/testLeadingSwipePinsAndOpensNoteScopedChat",
        "DayPageLocalUITests/CardShareUITests/testTrailingSwipeRequiresConfirmationAndKeepsUndo",
        "DayPageLocalUITests/CardShareUITests/testCardSharePreviewChangesStyleDateAndFormat",
        "DayPageLocalUITests/CardShareUITests/testDetailShareOpensTheSamePreview",
        "DayPageLocalUITests/CardShareUITests/testAttachmentOnlyNoteExplainsFormatsBeforeExport",
        "DayPageLocalUITests/CardShareUITests/testArchiveAndSearchRowsKeepSwipeActionsAndSuppressThemDuringSelection",
        "DayPageLocalUITests/CardShareUITests/testImageActuallyExportsAndSystemShareCancellationReturnsToPreview",
        "DayPageLocalUITests/CardShareUITests/testLongNoteKeepsItsFinalLineInCompleteText"
    ],
    "card_tools": [
        "DayPageLocalUITests/CardToolsSpeechUITests/testCreatedNoteAndReceiptReopenAndUndoWithoutConsumingCaptureDraft",
        "DayPageLocalUITests/CardToolsSpeechUITests/testCancelledNoteProposalReopensWithoutPublishingANote",
        "DayPageLocalUITests/CardToolsSpeechUITests/testAppendPatchTagsAndPinAreReviewedAndOpenTheUpdatedOriginal",
        "DayPageLocalUITests/CardToolsSpeechUITests/testConnectionsRequireConfirmationAndCanBeReadRemovedAndRestored",
        "DayPageLocalUITests/CardToolsSpeechUITests/testSimilarNotesReturnSourcesThatOpenTheActualOriginal",
        "DayPageLocalUITests/CardToolsSpeechUITests/testCardToolsOpenTheOriginalAndSavedReplySurvivesRelaunchWithoutConsumingCaptureDraft",
        "DayPageLocalUITests/CardToolsSpeechUITests/testTurningOffNoteExcerptsDisablesToolsAndPersistsAnOrdinaryConversation"
    ],
    "speech": [
        "DayPageLocalUITests/CardToolsSpeechUITests/testSystemAndSavedCustomSpeechChannelsSwitchReopenAndPreviewExplicitly",
        "DayPageLocalUITests/CardToolsSpeechUITests/testAnonymousSpeechWorksWithoutKeychain",
        "DayPageLocalUITests/CardToolsSpeechUITests/testSpeechFailureKeepsTheSavedChannelAndEditingItsAddressCanRetry",
        "DayPageLocalUITests/CardToolsSpeechUITests/testElevenLabsSavedKeySurvivesRelaunchAndStaysSeparateFromAnAnonymousChannel"
    ],
    "chat": [
        "DayPageLocalUITests/ChatExperienceUITests/testModelsHaveTheirOwnPageAndChatDraftSurvivesIt",
        "DayPageLocalUITests/ChatExperienceUITests/testNewConversationKeepsOldDraftInHistoryAfterRelaunch",
        "DayPageLocalUITests/ChatExperienceUITests/testCharacterCreationAndRotationSurviveReopen",
        "DayPageLocalUITests/ChatExperienceUITests/testStreamingMarkdownReasoningAndSavedHistory",
        "DayPageLocalUITests/ChatExperienceUITests/testLargeTypeKeepsComposerAndCharacterControlsReachable"
    ],
    "diary": [
        "DayPageLocalUITests/DiaryUITests/testHomeScrollsAcrossDaysAndReturnsToToday",
        "DayPageLocalUITests/DiaryUITests/testMonthJumpKeepsNeighboringDaysAndCanRepeat",
        "DayPageLocalUITests/DiaryUITests/testRediscoveryOpensAnExistingPastNoteWithoutCreatingOne",
        "DayPageLocalUITests/DiaryUITests/testCaptureFromPastDayReturnsToItsNewRecordAndKeepsHistory",
        "DayPageLocalUITests/DiaryUITests/testChineseDarkSidebarAndLargeTextStayReachable",
        "DayPageLocalUITests/DiaryUITests/testEmptyNotebookHasNoRediscoveryAndDrawerDismisses",
        "DayPageLocalUITests/DiaryUITests/testReadingPreferencesPersistAndExternalHeadingsAreHidden",
        "DayPageLocalUITests/DiaryUITests/testOptionalLocationSurvivesDraftRelaunchAndClearsForNextNote",
        "DayPageLocalUITests/DiaryUITests/testCancelledLocationCannotArriveLaterAndRemovalSurvivesRelaunch",
        "DayPageLocalUITests/DiaryUITests/testRealLocationPermissionDenialStillAllowsSavingWithoutLocation"
    ],
    "launch": [
        "DayPageLocalUITests/LaunchExperienceUITests/testArchiveIsBrowseAndSearchReturnsToItsOrigin",
        "DayPageLocalUITests/LaunchExperienceUITests/testNoSearchMatchesHasClearRecovery",
        "DayPageLocalUITests/LaunchExperienceUITests/testAISetupKeepsQuestionAndEmptyNotebookExplainsScope",
        "DayPageLocalUITests/LaunchExperienceUITests/testSuggestionsOnlyDraftAQuestion",
        "DayPageLocalUITests/LaunchExperienceUITests/testLargeArchiveFindsOlderNotesWithoutLeakingItsSearchFilter",
        "DayPageLocalUITests/LaunchExperienceUITests/testChineseArchiveCalendarAndShareUseTheSameDesignLanguage",
        "DayPageLocalUITests/LaunchExperienceUITests/testProviderSetupNeedsOnlyChoicesAndKeepsKeyDraftsSeparate",
        "DayPageLocalUITests/LaunchExperienceUITests/testCustomModelDiscoveryAndSaveSurviveReopening",
        "DayPageLocalUITests/LaunchExperienceUITests/testCardHeaderContainsFullDateAndMenuAboveTheReadingSurface",
        "DayPageLocalUITests/LaunchExperienceUITests/testDiscoveryFailureKeepsTheCustomConnection",
        "DayPageLocalUITests/LaunchExperienceUITests/testScrollingSettingsDoesNotCancelAConnectionTest",
        "DayPageLocalUITests/LaunchExperienceUITests/testChineseCardHeaderAtLargeTextInDarkMode",
        "DayPageLocalUITests/LaunchExperienceUITests/testChineseAIChoicesAndFixedGLMDefaultAreClear",
        "DayPageLocalUITests/LaunchExperienceUITests/testClearedCustomKeyDoesNotReturnAfterSwitchingServices",
        "DayPageLocalUITests/LaunchExperienceUITests/testSavedAnonymousIntentDoesNotReloadAHistoricalKey",
        "DayPageLocalUITests/LaunchExperienceUITests/testExistingProviderURLKeepsItsCorrectRegion",
        "DayPageLocalUITests/LaunchExperienceUITests/testProviderWithoutARequiredKeyOffersSetupBeforeSending",
        "DayPageLocalUITests/LaunchExperienceUITests/testCaptureFromHistoricalDateReturnsToTheSavedNoteToday"
    ],
    "local_notebook": [
        "DayPageLocalUITests/LocalNotebookUITests/testAppStoreScreenshotsUseTheLocalNotebookAndExposeItsPrivacyPolicy",
        "DayPageLocalUITests/LocalNotebookUITests/testOfflineWritingSurvivesRelaunchAndCanBeEdited",
        "DayPageLocalUITests/LocalNotebookUITests/testDevicesAndICloudStartsLocalAndExplainsTheBackupScope",
        "DayPageLocalUITests/LocalNotebookUITests/testSidebarKeepsItsDestinationsAndSettingsNeedsNoAccount",
        "DayPageLocalUITests/LocalNotebookUITests/testUnconfiguredChatMakesConfigurationExplicit",
        "DayPageLocalUITests/LocalNotebookUITests/testLargeTextSidebarKeepsSettingsReachable",
        "DayPageLocalUITests/LocalNotebookUITests/testDarkArchive",
        "DayPageLocalUITests/LocalNotebookUITests/testCaptureDraftAndAttachmentSurviveCollapseAndRelaunch",
        "DayPageLocalUITests/LocalNotebookUITests/testPinnedSearchAndRecoverableTrash",
        "DayPageLocalUITests/LocalNotebookUITests/testRestoredTodayHasCompactHeaderAndPersistentCaptureDockInChinese",
        "DayPageLocalUITests/LocalNotebookUITests/testFullAttachmentDraftKeepsCaptureSafeAndCanStillBeSaved",
        "DayPageLocalUITests/LocalNotebookUITests/testArchiveSelectionOpensExplicitScopedChat",
        "DayPageLocalUITests/LocalNotebookUITests/testDayRolloverTracksTodayAndPreservesChosenHistoricalDay",
        "DayPageLocalUITests/LocalNotebookUITests/testLongMemoExpandsInPlaceAndCollapsesWithoutLosingCaptureDock",
        "DayPageLocalUITests/LocalNotebookUITests/testExplicitChatWithIsolatedLoopbackFixtureAndReopenPersistence",
        "DayPageLocalUITests/LocalNotebookUITests/testBundledPrivacyInformationIsReadableInEnglishAfterRelaunch",
        "DayPageLocalUITests/LocalNotebookUITests/testBundledAboutAndSupportUseChineseAtAccessibilitySize",
        "DayPageLocalUITests/LocalNotebookUITests/testManualInformationCheckKeepsReadableContentAndRecordsItsActualOutcome"
    ],
    "manual_reviews": [
        "DayPageLocalUITests/ManualReviewExchangeUITests/testDayPreviewRequiresSendAndSaveThenSurvivesRelaunchWithoutChangingOriginals",
        "DayPageLocalUITests/ManualReviewExchangeUITests/testWeekReviewUsesExplicitSelectionAndSavesASeparatePage"
    ],
    "manual_cancel": [
        "DayPageLocalUITests/ManualReviewExchangeUITests/testCancelledNoncooperativeLateReplyCannotReappearOrSave"
    ],
    "manual_exchange": [
        "DayPageLocalUITests/ManualReviewExchangeUITests/testExportAndImportPreviewsDoNotPublishUntilConfirmThenUseANewNamespace",
        "DayPageLocalUITests/ManualReviewExchangeUITests/testPendingCopySurvivesRelaunchAndRequiresExplicitDiscard"
    ],
    "unsigned": [
        "DayPageLocalUITests/LaunchExperienceUITests/testAISetupKeepsQuestionAndEmptyNotebookExplainsScope",
        "DayPageLocalUITests/CardToolsSpeechUITests/testAnonymousSpeechWorksWithoutKeychain"
    ]
}

ATTACHMENTS = {
    "local_notebook": ["app-information-privacy-en", "app-information-about-zh",
                       "app-information-after-manual-check"],
    "chat": ["chat-dedicated-model-page", "chat-compact-composer", "chat-saved-history",
             "chat-character-library", "chat-streamed-markdown", "chat-accessibility-size"],
    "diary": ["diary-home-today", "diary-earlier-days", "diary-sidebar-en",
              "diary-sidebar-zh-normal", "diary-sidebar-zh-dark-large-text",
              "diary-month-position", "diary-rediscovered-note"],
    "unsigned": ["ai-key-unavailable-inline", "speech-anonymous-no-keychain"],
    "manual_reviews": ["GET442-day-relaunched-page", "GET442-week-saved-independent-page"],
    "manual_cancel": ["GET442-cancelled-late-reply-fenced"],
    "manual_exchange": ["GET442-import-preview-before-confirmation", "GET442-confirmed-new-namespace-readback",
                        "GET442-pending-copy-explicitly-discarded"],
}
SUITES = ("full", "manual_review_exchange")
MANUAL_GROUPS = ("manual_reviews", "manual_cancel", "manual_exchange")


def scoped_groups(suite):
    require(suite in SUITES, "unknown native plan scope")
    return GROUPS if suite == "full" else {key: GROUPS[key] for key in MANUAL_GROUPS}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def read_json(path):
    # Plans/receipts/summaries/manifests are small; reject an unexpected large artifact.
    require(path.stat().st_size <= 8 * 1024 * 1024, "oversized metadata")
    return json.loads(path.read_text())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def parse_pbx(text):
    """Parse the project's OpenStep plist, including explicit target membership."""
    tokens = []
    pattern = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"]+', re.S)
    position = 0
    for match in pattern.finditer(text):
        require(match.start() == position, "unsupported project syntax")
        token = match.group()
        position = match.end()
        if token.isspace() or token.startswith(("/*", "//")):
            continue
        tokens.append(token)
    require(position == len(text) and len(tokens) < 200000, "invalid project")
    index = 0

    def take():
        nonlocal index
        require(index < len(tokens), "incomplete project")
        token = tokens[index]
        index += 1
        return token

    def value(depth=0):
        require(depth < 64, "project nesting")
        token = take()
        if token == "{":
            result = {}
            while tokens[index] != "}":
                key = take()
                require(take() == "=" and key not in result, "ambiguous project key")
                result[key] = value(depth + 1)
                require(take() == ";", "project missing separator")
            take()
            return result
        if token == "(":
            result = []
            while tokens[index] != ")":
                result.append(value(depth + 1))
                if tokens[index] != ")":
                    require(take() == ",", "project missing array separator")
            take()
            return result
        if token.startswith('"'):
            # PBX strings here use JSON-compatible escapes; unknown syntax fails closed.
            return json.loads(token)
        require(token not in "{}()=;,", "unexpected project token")
        return token

    result = value()
    require(index == len(tokens), "trailing project data")
    return result


def compiled_sources(repo):
    project = repo / PROJECT
    objects = parse_pbx(project.read_text())["objects"]
    targets = [(key, obj) for key, obj in objects.items()
               if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "DayPageLocalUITests"]
    require(len(targets) == 1, "missing/ambiguous UI target")
    target_id, target = targets[0]
    require(not target.get("fileSystemSynchronizedGroups"), "synchronized membership requires reviewed planner")
    scheme = ET.parse(repo / SCHEME).getroot()
    require(scheme.find("./TestAction/TestPlans") is None, "external test plans require reviewed membership")
    refs = scheme.findall("./TestAction/Testables/TestableReference")
    require(len(refs) == 1 and refs[0].get("skipped") == "NO", "scheme excludes/expands test target")
    ref = refs[0].find("BuildableReference")
    require(ref is not None and ref.get("BlueprintIdentifier") == target_id
            and ref.get("ReferencedContainer") == "container:DayPageLocal.xcodeproj"
            and not list(refs[0].findall("SkippedTests")) and not list(refs[0].findall("SelectedTests")),
            "scheme test membership differs")
    parents = {}
    for key, obj in objects.items():
        if obj.get("isa") == "PBXGroup":
            for child in obj.get("children", []):
                require(child not in parents, "ambiguous project group")
                parents[child] = key
    base = project.parent.parent

    def resolve(key, seen=()):
        require(key not in seen and len(seen) < 32, "project group cycle")
        obj = objects[key]
        tree = obj.get("sourceTree", "<group>")
        require(tree in ("<group>", "SOURCE_ROOT"), "unsupported source root")
        parent = base if tree == "SOURCE_ROOT" or key not in parents else resolve(parents[key], (*seen, key))
        return parent / obj.get("path", "")

    phases = [objects[key] for key in target["buildPhases"] if objects[key].get("isa") == "PBXSourcesBuildPhase"]
    require(len(phases) == 1, "ambiguous UI sources phase")
    paths = []
    for key in phases[0]["files"]:
        build = objects[key]
        require(build.get("isa") == "PBXBuildFile" and not build.get("platformFilters")
                and not build.get("platformFilter"), "conditional/unknown compiled membership")
        obj = objects[build["fileRef"]]
        require(obj.get("isa") == "PBXFileReference", "unknown compiled source reference")
        path = resolve(build["fileRef"]).resolve()
        require(path.is_relative_to(repo.resolve()) and path.suffix == ".swift", "unexpected UI source path")
        paths.append(path.relative_to(repo.resolve()).as_posix())
    require(paths and len(paths) == len(set(paths)), "missing/duplicate compiled files")
    return sorted(paths)


def discover_ids(repo, paths):
    result = []
    for path in paths:
        text = (repo / path).read_text()
        # These reviewed files use one ordinary XCTestCase class each. Any new
        # class, extension, dynamic tests, conditional compilation, or signature
        # form needs an explicit planner update rather than silent omission.
        classes = re.findall(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\s*\{", text, re.M)
        require(len(classes) == 1 and classes[0] == Path(path).stem, "unknown test class")
        declared_classes = re.findall(r"^\s*(?:(?:private|fileprivate|final)\s+)*class\s+(\w+)\b", text, re.M)
        allowed_classes = {classes[0]} | ({"SwitchGeometry"} if classes[0] == "CardToolsSpeechUITests" else set())
        require(set(declared_classes) <= allowed_classes
                and not re.search(r"@Test\b|\bimport\s+Testing\b", text), "new test class/framework needs reviewed mapping")
        require(not re.search(r"^\s*(?:#if|#elseif|extension\s+|override\s+class\s+func\s+defaultTestSuite)", text, re.M),
                "conditional/dynamic test declarations need review")
        methods = re.findall(r"^\s*func\s+(test\w+)\s*\(\s*\)\s*(?:(?:async|throws)\s*)*\{", text, re.M)
        declarations = re.findall(r"\bfunc\s+(test\w+)\s*\(", text)
        require(sorted(methods) == sorted(declarations) and methods, "unsupported test declaration")
        result.extend("DayPageLocalUITests/" + classes[0] + "/" + method for method in methods)
    require(len(result) == len(set(result)), "duplicate test declarations")
    return sorted(result)


def make_plan(repo, sha, run_id, attempt, profile, suite="full"):
    repo = repo.resolve()
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "invalid source SHA")
    require(re.fullmatch(r"[1-9][0-9]*", run_id) is not None
            and re.fullmatch(r"[1-9][0-9]*", attempt) is not None, "invalid run identity")
    require(profile in ("arm64", "intel", "intel15"), "unknown runner profile")
    paths = compiled_sources(repo)
    actual = discover_ids(repo, paths)
    signed = [item for key, items in GROUPS.items() if key != "unsigned" for item in items]
    require(len(signed) == len(set(signed)) and sorted(signed) == actual,
            "compiled tests differ from reviewed full shard map")
    require(set(GROUPS["unsigned"]) <= set(actual), "unsigned methods not compiled")
    groups = scoped_groups(suite)
    files = paths + [PROJECT, SCHEME, "scripts/qa/run_local_native_ci.sh", "scripts/qa/native_ui_matrix.py"]
    plan = {"schemaVersion": 1, "suite": suite, "sourceSHA": sha, "runId": run_id, "runAttempt": attempt, "runnerProfile": profile,
            "compiledSources": paths,
            "sourceFiles": {path: hashlib.sha256((repo / path).read_bytes()).hexdigest() for path in sorted(files)},
            "shards": [{"id": key, "signingMode": "unsigned" if key == "unsigned" else "signed",
                        "expectedIDs": sorted(items), "requiredAttachments": ATTACHMENTS.get(key, [])}
                       for key, items in groups.items()]}
    plan["planDigest"] = digest(plan)
    return plan


def validate_plan(plan, repo=None):
    require(plan.get("schemaVersion") == 1, "unknown plan version")
    require(plan.get("planDigest") == digest({k: v for k, v in plan.items() if k != "planDigest"}), "plan digest mismatch")
    groups = scoped_groups(plan.get("suite"))
    expected = [{"id": key, "signingMode": "unsigned" if key == "unsigned" else "signed",
                 "expectedIDs": sorted(items), "requiredAttachments": ATTACHMENTS.get(key, [])} for key, items in groups.items()]
    require(plan.get("shards") == expected, "unknown shard configuration")
    if repo is not None:
        require(plan == make_plan(repo, plan["sourceSHA"], plan["runId"], plan["runAttempt"], plan["runnerProfile"], plan["suite"]),
                "compiled source manifest changed")


def parse_events(path):
    observed = {key: [] for key in ("started", "passed", "failed", "skipped")}
    errors = []
    states = {}
    pattern = re.compile(r"^Test Case '-\[DayPageLocalUITests\.(\w+) (test\w+)\]' (started\.|(passed|failed|skipped) \([0-9.]+ seconds\)\.)$")
    with path.open() as lines:
        for line in lines:
            if not line.startswith("Test Case "):
                continue
            match = pattern.fullmatch(line.strip())
            if not match:
                errors.append("unrecognized XCTest case event")
                continue
            suite, method = match.group(1, 2)
            item = "DayPageLocalUITests/" + suite + "/" + method
            state = "started" if match.group(3) == "started." else match.group(4)
            if (state == "started" and item in states) or (state != "started" and states.get(item) != "started"):
                errors.append("duplicate/out-of-order XCTest event")
            states[item] = state
            observed[state].append(item)
    return observed, errors


def make_receipt(plan, shard_id, root, exit_code):
    validate_plan(plan)
    shards = [s for s in plan["shards"] if s["id"] == shard_id]
    require(len(shards) == 1, "unknown shard")
    shard = shards[0]
    prefix = "negative" if shard["signingMode"] == "unsigned" else "signed"
    receipt = {key: plan[key] for key in ("schemaVersion", "suite", "sourceSHA", "runId", "runAttempt", "planDigest", "runnerProfile")}
    receipt.update({"shard": shard_id, "signingMode": shard["signingMode"], "expectedIDs": shard["expectedIDs"],
                    "passed": False, "exitCode": exit_code, "errors": [],
                    "observed": {key: [] for key in ("started", "passed", "failed", "skipped")},
                    "requiredAttachments": shard["requiredAttachments"], "attachmentNames": [],
                    "evidenceHashes": {}, "summary": None, "toolchain": None, "evidenceChecks": False})
    errors = receipt["errors"]
    if exit_code != 0:
        errors.append("orchestration failed")
    # Preserve available actual provenance/summary even when XCTest never
    # initializes AX or a method fails. These are not inferred from the plan.
    for name, key in (("provenance.json", "provenance"), (prefix + "-summary.log", "summary")):
        try:
            receipt[key] = read_json(root / name)
        except (OSError, ValueError):
            receipt[key] = None
    if isinstance(receipt.get("provenance"), dict):
        receipt["toolchain"] = {k: receipt["provenance"].get(k) for k in
                                ("xcode", "simulatorSDK", "hostArchitecture", "runnerImage", "bundleId")}
    try:
        observed, parse_errors = parse_events(root / (prefix + "-ui.log"))
        receipt["observed"] = observed
        errors.extend(parse_errors)
        require(sorted(observed["started"]) == shard["expectedIDs"] and sorted(observed["passed"]) == shard["expectedIDs"]
                and not observed["failed"] and not observed["skipped"], "missing/extra/unfinished/failed/skipped case")
        summary = read_json(root / (prefix + "-summary.log"))
        receipt["summary"] = summary
        count = len(shard["expectedIDs"])
        require(summary.get("result") == "Passed" and all(type(summary.get(k)) is int for k in
                ("totalTestCount", "passedTests", "failedTests", "skippedTests"))
                and summary["totalTestCount"] == summary["passedTests"] == count
                and summary["failedTests"] == summary["skippedTests"] == 0, "xcresult summary contradicts exact case events")
        source = read_json(root / "provenance.json")
        require(all(source.get(key) == plan[key] for key in ("sourceSHA", "runId", "runAttempt")), "wrong source/run/attempt")
        require(source.get("bundleId") == "com.daypage.app.localqa", "non-QA bundle")
        expected_arch = "arm64" if plan["runnerProfile"] == "arm64" else "x86_64"
        require(source.get("hostArchitecture") == expected_arch, "wrong runner architecture")
        for key in ("xcode", "simulatorSDK", "runnerImage"):
            require(isinstance(source.get(key), str) and 0 < len(source[key]) < 1024, "missing toolchain provenance")
        receipt["toolchain"] = {k: source[k] for k in ("xcode", "simulatorSDK", "hostArchitecture", "runnerImage", "bundleId")}
        require(plan["runnerProfile"] != "intel15" or source["xcode"].startswith("Xcode 26.3\n"), "wrong Intel 15 toolchain")
        records = read_json(root / (prefix + "-attachments/manifest.json"))
        names = [a.get("suggestedHumanReadableName", "") for record in records for a in record.get("attachments", [])]
        receipt["attachmentNames"] = names
        require(all(any(required in name for name in names) for required in shard["requiredAttachments"]), "missing required branch attachment")
        boot = read_json(root / "simulator-boot-receipt.json")
        require(boot.get("ready") is True and boot.get("outcome") == "success" and boot.get("exitCode") == 0, "boot not completed")
        require(read_json(root / "fixture-health.log").get("healthVerified") is True
                and re.search(r"^accepted_attempt=[1-9][0-9]*$", (root / "fixture-listener-probes.log").read_text(), re.M),
                "fixture ownership/readiness not completed")
        proof_files = [prefix + "-ui.log", prefix + "-summary.log", prefix + "-attachments/manifest.json", "provenance.json",
                       "simulator-boot-receipt.json", "fixture-health.log", "fixture-listener-probes.log", prefix + "-executable.sha256"]
        executable = (root / (prefix + "-executable.sha256")).read_text()
        require(re.fullmatch(r"[0-9a-f]{64}\s+[^\n]+\n?", executable) is not None, "missing executable hash")
        if prefix == "negative":
            require(read_json(root / "negative-receipt.json").get("verified") is True, "unsigned branch not verified")
            proof_files.append("negative-receipt.json")
        else:
            entitlements = read_json(root / "simulator-entitlements.json")
            # This target has one QA app and retains its existing private-only
            # Keychain/no-App-Group validator in run_local_native_ci.sh. Do not
            # import the unmerged capture extension's entitlement contract.
            require(isinstance(entitlements, list) and entitlements, "missing signed entitlement verification")
            for entry in entitlements:
                identity = entry.get("applicationIdentifier")
                require(isinstance(identity, str) and (identity == "com.daypage.app.localqa"
                        or identity.endswith(".com.daypage.app.localqa")), "foreign signed identity")
                explicit = entry.get("explicitKeychainAccessGroups")
                require(isinstance(explicit, list) and all(group == identity for group in explicit)
                        and entry.get("keychainAccessGroups") == list(dict.fromkeys([*explicit, identity])),
                        "foreign signed Keychain group")
            require("sectname __entitlements" in (root / "macho.log").read_text(), "missing Mach-O entitlements")
            # A successful codesign --verify may legitimately write zero bytes.
            proof_files += ["simulator-entitlements.json", "signature.log", "signature-verification.log", "macho.log"]
        receipt["evidenceHashes"] = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in proof_files}
        receipt["evidenceChecks"] = True
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        errors.append(str(error)[:200] if isinstance(error, ValueError) else "missing/invalid native evidence")
    receipt["passed"] = not errors
    return receipt


def aggregate(plan, receipts, matrix_result):
    validate_plan(plan)
    errors = []
    ids = [record.get("shard") for record in receipts]
    if Counter(ids) != Counter(s["id"] for s in plan["shards"]):
        errors.append("missing/duplicate/unknown shard receipt")
    if matrix_result != "success":
        errors.append("native matrix jobs did not all succeed")
    toolchains = []
    cells = []
    for record in receipts:
        try:
            require(all(record.get(key) == plan[key] for key in
                        ("schemaVersion", "suite", "sourceSHA", "runId", "runAttempt", "planDigest", "runnerProfile")), "receipt context differs")
            shard = next(s for s in plan["shards"] if s["id"] == record.get("shard"))
            require(record.get("signingMode") == shard["signingMode"] and record.get("expectedIDs") == shard["expectedIDs"]
                    and record.get("requiredAttachments") == shard["requiredAttachments"], "receipt mode/selection differs")
            require(record.get("passed") is True and record.get("exitCode") == 0 and record.get("errors") == []
                    and record.get("evidenceChecks") is True and record.get("evidenceHashes"), "shard did not complete successfully")
            observed = record["observed"]
            require(sorted(observed["started"]) == sorted(observed["passed"]) == shard["expectedIDs"]
                    and not observed["failed"] and not observed["skipped"], "receipt case observations differ")
            count = len(shard["expectedIDs"])
            summary = record["summary"]
            require(all(type(summary.get(k)) is int for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests"))
                    and summary["result"] == "Passed" and summary["totalTestCount"] == summary["passedTests"] == count
                    and summary["failedTests"] == summary["skippedTests"] == 0, "receipt summary differs")
            require(all(any(name in actual for actual in record["attachmentNames"]) for name in shard["requiredAttachments"]),
                    "receipt missing required attachment")
            require(record.get("toolchain"), "receipt missing toolchain")
            require(all(record["provenance"].get(key) == plan[key] for key in ("sourceSHA", "runId", "runAttempt")),
                    "observed provenance differs")
            toolchains.append(record["toolchain"])
            cells.extend((shard["signingMode"], item) for item in observed["passed"])
        except (ValueError, KeyError, TypeError, StopIteration):
            errors.append("invalid/failed shard receipt")
    expected = [(s["signingMode"], item) for s in plan["shards"] for item in s["expectedIDs"]]
    if Counter(cells) != Counter(expected):
        errors.append("configuration union is not the complete selected scope")
    if toolchains and any(value != toolchains[0] for value in toolchains):
        errors.append("shard toolchains differ")
    return {"schemaVersion": 1, "suite": plan["suite"], "sourceSHA": plan["sourceSHA"], "runId": plan["runId"], "runAttempt": plan["runAttempt"],
            "planDigest": plan["planDigest"], "passed": not errors, "errors": errors,
            "configurationCells": len(cells), "expectedConfigurationCells": len(expected), "shards": ids, "matrixJobResult": matrix_result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan_cmd = commands.add_parser("plan")
    plan_cmd.add_argument("--repo", type=Path, default=Path.cwd())
    plan_cmd.add_argument("--run-id", required=True)
    plan_cmd.add_argument("--attempt", required=True)
    plan_cmd.add_argument("--profile", required=True)
    plan_cmd.add_argument("--suite", choices=SUITES, default="full")
    plan_cmd.add_argument("--output", type=Path, required=True)
    plan_cmd.add_argument("--github-output", type=Path)
    for name in ("select", "receipt", "aggregate"):
        command = commands.add_parser(name)
        command.add_argument("--plan", type=Path, required=True)
        command.add_argument("--suite", choices=SUITES, default="full")
        if name != "aggregate":
            command.add_argument("--shard", required=True)
        if name == "select":
            command.add_argument("--repo", type=Path, default=Path.cwd())
        if name == "receipt":
            command.add_argument("--evidence", type=Path, required=True)
            command.add_argument("--exit-code", type=int, required=True)
        if name == "aggregate":
            command.add_argument("--receipts", type=Path, required=True)
            command.add_argument("--matrix-result", required=True)
        if name != "select":
            command.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "plan":
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.repo, text=True).strip()
        plan = make_plan(args.repo, sha, args.run_id, args.attempt, args.profile, args.suite)
        write_json(args.output, plan)
        if args.github_output:
            with args.github_output.open("a") as output:
                output.write("matrix=" + json.dumps({"include": [{"shard": s["id"]} for s in plan["shards"]]}, separators=(",", ":")) + "\n")
        return 0
    plan = read_json(args.plan)
    validate_plan(plan)
    require(plan["suite"] == args.suite, "plan is not the selected native scope")
    if args.command == "select":
        import os
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.repo, text=True).strip()
        require(sha == plan["sourceSHA"] and os.environ.get("GITHUB_RUN_ID") == plan["runId"]
                and os.environ.get("GITHUB_RUN_ATTEMPT") == plan["runAttempt"], "wrong active run/source")
        validate_plan(plan, args.repo)
        shard = next((s for s in plan["shards"] if s["id"] == args.shard), None)
        require(shard is not None, "unknown shard")
        print(shard["signingMode"])
        print("\n".join(shard["expectedIDs"]))
        return 0
    if args.command == "receipt":
        result = make_receipt(plan, args.shard, args.evidence, args.exit_code)
    else:
        import os
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        require(sha == plan["sourceSHA"] and os.environ.get("GITHUB_RUN_ID") == plan["runId"]
                and os.environ.get("GITHUB_RUN_ATTEMPT") == plan["runAttempt"], "aggregate is not this active source/run")
        validate_plan(plan, Path.cwd())
        paths = sorted(args.receipts.glob("**/shard-receipt.json"))
        result = aggregate(plan, [read_json(path) for path in paths], args.matrix_result)
    write_json(args.output, result)
    if not result["passed"]:
        print("; ".join(result["errors"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print("Native matrix denied: " + str(error), file=sys.stderr)
        sys.exit(1)
