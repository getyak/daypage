import Contacts
import ContactsUI
import CoreSpotlight
import EventKit
import EventKitUI
import Foundation
import MapKit
import Photos
import Testing
import UniformTypeIdentifiers
import UserNotifications
import DayPageModels
@testable import DayPage

extension DayPageSerialSwiftTests {
@MainActor
@Suite("System action Apple adapters", .serialized)
struct SystemActionAppleAdapterTests {
    @Test func privacyFailureCodeNeverIncludesLocalizedPrivateContent() {
        let privateMessage = "alice@example.com at 31.2304,121.4737"
        let error = NSError(
            domain: "DayPage.Private Provider",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: privateMessage]
        )

        let code = AppleAdapterPrivacy.failureCode(error)

        #expect(code == "daypage.private_provider.401")
        #expect(!code.contains("alice"))
        #expect(!code.contains("31.2304"))
        #expect(code.count <= 96)
    }

    @Test func privacyBoundsAreNormativeUTF8Bytes() {
        let value = AppleAdapterPrivacy.boundedPublicText("abcdéé", limit: 6)
        #expect(value == "abcdé")
        #expect(value.utf8.count == 6)
    }

    @Test func boundedPublicTextRemovesLineBreaksAndAppliesLimit() {
        let value = AppleAdapterPrivacy.boundedPublicText("  first\nsecond\rthird  ", limit: 12)
        #expect(value == "first second")
        #expect(!value.contains("\n"))
        #expect(value.count == 12)
    }

    @Test func notificationUsesDeterministicIDAndRequestsPermissionJustInTime() async throws {
        let center = NotificationCenterDouble(status: .notDetermined)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let actionID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        let client = AppleNotificationClient(center: center, now: { now })

        let reference = try await client.schedule(
            actionID: actionID,
            title: "Reminder",
            body: "Write one line",
            fireDate: now.addingTimeInterval(60),
            threadIdentifier: nil,
            interruption: .active,
            playsSound: true
        )

        #expect(center.requestCount == 1)
        #expect(center.requests.count == 1)
        #expect(reference.identifier == "daypage.system-action.aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(await client.reconcile(actionID: actionID))
        client.cancel(actionID: actionID)
        #expect(center.removed == [reference.identifier])
    }

    @Test func notificationDenialCreatesNoRequest() async {
        let center = NotificationCenterDouble(status: .denied)
        let client = AppleNotificationClient(center: center)

        await #expect(throws: AppleSystemActionAdapterError.authorizationDenied(.notifications)) {
            try await client.schedule(
                actionID: UUID(),
                title: "Private title",
                body: "Private body",
                fireDate: Date().addingTimeInterval(60),
                threadIdentifier: nil,
                interruption: .active,
                playsSound: true
            )
        }
        #expect(center.requestCount == 0)
        #expect(center.requests.isEmpty)
    }

    @Test func reminderPreservesApprovedSecondsAndRefusesUndoAfterExternalEdit() async throws {
        let store = EventStoreDouble()
        let client = AppleRemindersClient(store: store)
        let due = Date(timeIntervalSince1970: 1_700_000_056.789)

        let reference = try await client.createReminder(
            title: "Exact reminder",
            notes: "Keep exact",
            dueDate: due,
            timeZoneIdentifier: "UTC",
            listHint: nil,
            priority: 4
        )

        let saved = try #require(store.savedReminder)
        var expectedCalendar = Calendar(identifier: .gregorian)
        expectedCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(saved.dueDateComponents?.second == expectedCalendar.component(.second, from: due))
        #expect((saved.dueDateComponents?.nanosecond ?? 0) >= 788_000_000)
        saved.title = "Edited outside DayPage"
        let removed = try await client.removeIfUnchanged(
            identifier: reference.identifier,
            expectedSnapshot: reference.snapshot
        )
        #expect(!removed)
        #expect(store.removedReminderCount == 0)
    }

    @Test func calendarRefusesUndoAfterExternalEdit() async throws {
        let store = EventStoreDouble()
        let client = AppleCalendarClient(store: store)
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Exact event"
        event.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_700_003_600)
        event.notes = "Keep exact"
        store.savedEvent = event
        let expectedSnapshot = try AppleCalendarClient.snapshotData(for: event)

        event.location = "Edited outside DayPage"
        let removed = try await client.removeIfUnchanged(
            identifier: "external-event-id",
            expectedSnapshot: expectedSnapshot
        )

        #expect(!removed)
        #expect(store.removedEventCount == 0)
    }

    @Test func contactsRefusesUndoAfterExternalEdit() async throws {
        let contact = CNMutableContact()
        contact.givenName = "Exact"
        contact.familyName = "Person"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: "+1 555 0100")),
        ]
        let store = ContactStoreDouble(contact: contact)
        let client = AppleContactsClient(store: store)
        let expectedSnapshot = try AppleContactsClient.snapshotData(for: contact)

        contact.organizationName = "Edited outside DayPage"
        let removed = try await client.deleteIfUnchanged(
            identifier: "external-contact-id",
            expectedSnapshot: expectedSnapshot
        )

        #expect(!removed)
        #expect(store.executeCount == 0)
    }

    @Test func notificationDowngradesTimeSensitiveWhenSystemSettingIsDisabled() async throws {
        let center = NotificationCenterDouble(status: .authorized)
        center.timeSensitive = .disabled
        let client = AppleNotificationClient(center: center)

        _ = try await client.schedule(
            actionID: UUID(),
            title: "Reminder",
            body: "Write one line",
            fireDate: Date().addingTimeInterval(60),
            threadIdentifier: nil,
            interruption: .timeSensitive,
            playsSound: true
        )

        #expect(center.requests.count == 1)
        #expect(center.requests[0].content.interruptionLevel == .active)
    }

    @Test func notificationAppliesEveryApprovedLockScreenRedactionLevel() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let privateTitle = NSLocalizedString(
            "system_action.notification.private_title",
            value: "DayPage Notification",
            comment: ""
        )
        let privateBody = NSLocalizedString(
            "system_action.notification.private_body",
            value: "Open DayPage to view notification details.",
            comment: ""
        )
        let cases: [(SystemActionRedactionLevel, String, String, String)] = [
            (.privateOnLockScreen, privateTitle, privateBody, ""),
            (.titleOnly, "Private customer title", privateBody, ""),
            (.boundedSummary, "Private customer title", "Private customer body", ""),
        ]

        for (redactionLevel, expectedTitle, expectedBody, expectedThread) in cases {
            let center = NotificationCenterDouble(status: .authorized)
            let adapter = AppleNotificationSystemActionAdapter(
                client: AppleNotificationClient(center: center, now: { now })
            )
            let proposal = try notificationProposal(
                fireAt: now.addingTimeInterval(60),
                redactionLevel: redactionLevel
            )

            _ = try await adapter.execute(proposal: proposal, context: executionContext())

            let content = try #require(center.requests.first?.content)
            #expect(content.title == expectedTitle)
            #expect(content.body == expectedBody)
            #expect(content.threadIdentifier == expectedThread)
            if redactionLevel == .privateOnLockScreen {
                #expect(!content.title.contains("customer"))
                #expect(!content.body.contains("customer"))
                #expect(!content.threadIdentifier.contains("private"))
            }
        }

        let futureLocalPayload = SystemActionNotificationPayload(
            title: "Private customer title",
            body: "Private customer body",
            fireAt: now.addingTimeInterval(60),
            threadIdentifier: "private-thread"
        )
        #expect(AppleNotificationSystemActionAdapter.publicContent(
            for: futureLocalPayload,
            redactionLevel: .privateOnLockScreen
        ).threadIdentifier == nil)
        #expect(AppleNotificationSystemActionAdapter.publicContent(
            for: futureLocalPayload,
            redactionLevel: .titleOnly
        ).threadIdentifier == nil)
        #expect(AppleNotificationSystemActionAdapter.publicContent(
            for: futureLocalPayload,
            redactionLevel: .boundedSummary
        ).threadIdentifier == nil)
    }

    @Test func notificationDoesNotRewriteApprovedPublicText() async throws {
        let center = NotificationCenterDouble(status: .authorized)
        let client = AppleNotificationClient(center: center)
        let title = String(repeating: "T", count: 129)
        let body = String(repeating: "B", count: 257) + "\nsecond line"

        _ = try await client.schedule(
            actionID: UUID(),
            title: title,
            body: body,
            fireDate: Date().addingTimeInterval(60),
            threadIdentifier: nil,
            interruption: .active,
            playsSound: true
        )

        let content = try #require(center.requests.first?.content)
        #expect(content.title == title)
        #expect(content.body == body)
    }

    @Test func focusHonorsIndependentFlagsAndRedactsPrivateLockScreenTitle() async throws {
        let activity = FocusActivityDouble()
        let alert = FocusAlertDouble()
        let adapter = AppleFocusSystemActionAdapter(
            activityClient: activity,
            alertClient: alert,
            alarmClient: FocusAlarmDouble()
        )
        let alertOnly = try focusProposal(
            schedulesEndAlert: true,
            allowsLiveActivity: false,
            redactionLevel: .privateOnLockScreen
        )

        let alertOnlyResult = try await adapter.execute(
            proposal: alertOnly,
            context: executionContext()
        )

        #expect(activity.startedTitles.isEmpty)
        #expect(alert.scheduledTitles == ["DayPage"])
        #expect(alertOnlyResult.localMaterial?.metadata["end_alert_id"] != nil)
        #expect(alertOnlyResult.localMaterial?.metadata["live_activity_id"] == nil)

        let privateLiveActivity = try focusProposal(
            schedulesEndAlert: false,
            allowsLiveActivity: true,
            redactionLevel: .privateOnLockScreen
        )
        let activityOnlyResult = try await adapter.execute(
            proposal: privateLiveActivity,
            context: executionContext()
        )

        #expect(activity.startedTitles == ["DayPage Focus"])
        #expect(activity.scheduledEnds.count == 1)
        #expect(alert.scheduledTitles == ["DayPage"])
        #expect(activityOnlyResult.localMaterial?.metadata["live_activity_id"] != nil)
        #expect(activityOnlyResult.localMaterial?.metadata["end_alert_id"] == nil)
    }

    @Test func focusCapabilityRemainsAvailableWhenLiveActivitiesAreDisabled() async {
        let activity = FocusActivityDouble(capabilityState: .denied)
        let adapter = AppleFocusSystemActionAdapter(
            activityClient: activity,
            alertClient: FocusAlertDouble(),
            alarmClient: FocusAlarmDouble()
        )

        let capability = await adapter.capabilitySnapshot()

        #expect(capability.availability == .available)
        #expect(capability.authorization == .notApplicable)
    }

    @Test func focusUsesAlarmKitWithoutSchedulingDuplicateNotification() async throws {
        let activity = FocusActivityDouble()
        let alert = FocusAlertDouble()
        let alarm = FocusAlarmDouble()
        let context = executionContext()
        let proposal = try focusProposal(
            schedulesEndAlert: true,
            allowsLiveActivity: false,
            redactionLevel: .boundedSummary
        )
        alarm.scheduledReference = .init(
            identifier: "alarmkit:\(proposal.id.uuidString.lowercased())",
            createdAt: context.startedAt
        )
        let adapter = AppleFocusSystemActionAdapter(
            activityClient: activity,
            alertClient: alert,
            alarmClient: alarm,
            now: { context.startedAt }
        )

        let result = try await adapter.execute(proposal: proposal, context: context)

        #expect(alert.scheduledTitles.isEmpty)
        #expect(alarm.activeActionIDs == [proposal.id])
        #expect(result.localMaterial?.metadata["end_alert_surface"] == "alarmkit")
        #expect(result.boundedResult?.metadata["end_alert_surface"] == "alarmkit")
        let reconciled = try await adapter.reconcile(
            proposal: proposal,
            context: context,
            material: result.localMaterial
        )
        #expect(reconciled.disposition == .confirmed)
        #expect(alert.scheduledTitles.isEmpty)
    }

    @Test func focusDurationStartsAtNativeAttemptNotLeaseTimestamp() async throws {
        let context = executionContext()
        let nativeStart = context.startedAt.addingTimeInterval(90)
        let alert = FocusAlertDouble()
        let adapter = AppleFocusSystemActionAdapter(
            activityClient: FocusActivityDouble(),
            alertClient: alert,
            alarmClient: FocusAlarmDouble(),
            now: { nativeStart }
        )
        let proposal = try focusProposal(
            schedulesEndAlert: true,
            allowsLiveActivity: false,
            redactionLevel: .boundedSummary
        )

        let result = try await adapter.execute(proposal: proposal, context: context)

        #expect(alert.scheduledFireDates == [nativeStart.addingTimeInterval(25 * 60)])
        #expect(result.localMaterial?.metadata["focus_started_at"] == SystemActionCanonicalJSON.timestamp(nativeStart))
    }

    @Test func elapsedFocusReconciliationCleansUpAndNeverRetriesBlindly() async throws {
        let activity = FocusActivityDouble()
        let alert = FocusAlertDouble()
        let context = executionContext()
        let clock = MutableDateBox(context.startedAt.addingTimeInterval(2_000))
        let adapter = AppleFocusSystemActionAdapter(
            activityClient: activity,
            alertClient: alert,
            alarmClient: FocusAlarmDouble(),
            now: { clock.value }
        )
        let proposal = try focusProposal(
            schedulesEndAlert: true,
            allowsLiveActivity: true,
            redactionLevel: .boundedSummary
        )
        let executed = try await adapter.execute(proposal: proposal, context: context)
        clock.value = clock.value.addingTimeInterval(2_000)

        let reconciled = try await adapter.reconcile(
            proposal: proposal,
            context: context,
            material: executed.localMaterial
        )

        #expect(reconciled.disposition == .needsReview)
        #expect(reconciled.errorCode == "focus_window_elapsed")
        #expect(activity.endedIdentifiers.count == 1)
        #expect(!alert.activeActionIDs.contains(proposal.id))
    }

    @Test func mapRejectsInvalidCoordinateBeforeOpeningExternalUI() {
        var opened = false
        let client = AppleMapClient { _, _ in
            opened = true
            return true
        }

        #expect(throws: AppleSystemActionAdapterError.invalidPayload(field: "coordinate")) {
            try client.openRoute(latitude: 200, longitude: 0, label: nil, mode: .driving)
        }
        #expect(!opened)
    }

    @Test func mapResolvesAddressOnlyWithoutLocationPermission() async throws {
        let probe = MapProbe()
        let client = AppleMapClient(
            opener: { item, _ in
                probe.openedName = item.name
                return true
            },
            addressResolver: { query in
                probe.resolvedQuery = query
                let item = MKMapItem(placemark: MKPlacemark(
                    coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
                ))
                item.name = "Resolved"
                return item
            }
        )

        try await client.openRoute(
            latitude: nil,
            longitude: nil,
            address: "上海市人民广场",
            label: "会面地点",
            mode: .transit
        )

        #expect(probe.resolvedQuery == "上海市人民广场")
        #expect(probe.openedName == "会面地点")
    }

    @Test func mapPassesTheExactApprovedDestinationLabelForBothRouteShapes() async throws {
        let exactLabel = String(repeating: "L", count: 130) + "\nSecond line"
        let coordinateProbe = MapProbe()
        let coordinateClient = AppleMapClient { item, _ in
            coordinateProbe.openedName = item.name
            return true
        }
        try coordinateClient.openRoute(
            latitude: 31.2304,
            longitude: 121.4737,
            label: exactLabel,
            mode: .walking
        )
        #expect(coordinateProbe.openedName == exactLabel)

        let addressProbe = MapProbe()
        let addressClient = AppleMapClient(
            opener: { item, _ in
                addressProbe.openedName = item.name
                return true
            },
            addressResolver: { _ in
                MKMapItem(placemark: MKPlacemark(
                    coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
                ))
            }
        )
        try await addressClient.openRoute(
            latitude: nil,
            longitude: nil,
            address: "100 Design Road",
            label: exactLabel,
            mode: .transit
        )
        #expect(addressProbe.openedName == exactLabel)
    }

    @Test func routeAndMomentNormalizeUserCancellation() async throws {
        let mapClient = AppleMapClient { _, _ in false }
        let routeAdapter = AppleRouteSystemActionAdapter(client: mapClient)
        let routeResult = try await routeAdapter.execute(
            proposal: try routeProposal(),
            context: executionContext()
        )
        #expect(routeResult.outcome == .cancelled)
        #expect(routeResult.errorCode == "maps_cancelled")

        let locationClient = OneShotLocationDouble(
            result: .failure(AppleSystemActionAdapterError.userCancelled(.location))
        )
        let momentStore = MomentStoreDouble()
        let momentAdapter = AppleMomentSystemActionAdapter(
            locationClient: locationClient,
            momentStore: momentStore
        )
        let momentResult = try await momentAdapter.execute(
            proposal: try momentProposal(location: .init(label: "Approved place")),
            context: executionContext()
        )
        #expect(momentResult.outcome == .cancelled)
        #expect(momentResult.errorCode == "location_cancelled")
        #expect(await momentStore.completedCoordinates.isEmpty)
    }

    @Test func captureBrokerReturnsOnlyValidatedRelativeLocalMaterial() async throws {
        let broker = SystemActionUIBroker()
        let actionID = UUID()
        let operation = Task {
            try await broker.presentCapture(
                actionID: actionID,
                kind: .document,
                suggestedTitle: "Receipt",
                attachesToSource: true
            )
        }
        defer { operation.cancel() }
        let presentation = try await requirePresentation(from: broker)
        guard case .capture(let request) = presentation.content else {
            Issue.record("Expected a capture presentation")
            operation.cancel()
            return
        }

        broker.completeCapture(
            presentationID: request.presentationID,
            artifact: .init(
                kind: .document,
                relativePath: "system-actions/captures/receipt.pdf",
                uniformTypeIdentifier: UTType.pdf.identifier,
                byteCount: 4_096,
                pageCount: 2
            )
        )
        let artifact = try await operation.value

        #expect(artifact.relativePath == "system-actions/captures/receipt.pdf")
        #expect(artifact.boundedReceiptMetadata["page_count"] == "2")
        #expect(artifact.boundedReceiptMetadata["relative_path"] == nil)
        #expect(artifact.localReceiptMetadata["relative_path"] == artifact.relativePath)
        #expect(broker.activePresentation == nil)
    }

    @Test func captureBrokerRejectsAbsolutePathAndClearsPresentation() async throws {
        let broker = SystemActionUIBroker()
        let operation = Task {
            try await broker.presentCapture(
                actionID: UUID(),
                kind: .file,
                suggestedTitle: nil,
                attachesToSource: false
            )
        }
        defer { operation.cancel() }
        let presentation = try await requirePresentation(from: broker)
        guard case .capture(let request) = presentation.content else {
            Issue.record("Expected a capture presentation")
            operation.cancel()
            return
        }

        broker.completeCapture(
            presentationID: request.presentationID,
            artifact: .init(kind: .file, relativePath: "/private/user/document.pdf")
        )

        await #expect(throws: AppleSystemActionAdapterError.invalidPayload(field: "capture.relativePath")) {
            try await operation.value
        }
        #expect(broker.activePresentation == nil)
    }

    @Test func captureAdapterAwaitsForegroundArtifactAndSeparatesCloudFromLocalMetadata() async throws {
        let broker = SystemActionUIBroker()
        let adapter = AppleCaptureSystemActionAdapter(uiBroker: broker)
        let proposal = try captureProposal(kind: .document)
        let operation = Task {
            try await adapter.execute(proposal: proposal, context: executionContext())
        }
        defer { operation.cancel() }
        let presentation = try await requirePresentation(from: broker)
        guard case .capture(let request) = presentation.content else {
            Issue.record("Expected a capture presentation")
            operation.cancel()
            return
        }

        broker.completeCapture(
            presentationID: request.presentationID,
            artifact: .init(
                kind: .document,
                relativePath: "system-actions/captures/document.pdf",
                uniformTypeIdentifier: UTType.pdf.identifier,
                byteCount: 2_048,
                pageCount: 1
            )
        )
        let result = try await operation.value

        #expect(result.outcome == .succeeded)
        #expect(result.boundedResult?.metadata["capture_kind"] == "document")
        #expect(result.boundedResult?.metadata["relative_path"] == nil)
        #expect(result.localMaterial?.metadata["relative_path"] == "system-actions/captures/document.pdf")
    }

    @Test func captureAdapterMapsForegroundCancellationToCancelledOutcome() async throws {
        let broker = SystemActionUIBroker()
        let adapter = AppleCaptureSystemActionAdapter(uiBroker: broker)
        let proposal = try captureProposal(kind: .voice)
        let operation = Task {
            try await adapter.execute(proposal: proposal, context: executionContext())
        }
        defer { operation.cancel() }
        let presentation = try await requirePresentation(from: broker)

        broker.cancel(presentationID: presentation.id)
        let result = try await operation.value

        #expect(result.outcome == .cancelled)
        #expect(result.errorCode == "capture_cancelled")
    }

    @Test func calendarNativeEditorCancellationResumesAwaiter() async throws {
        let broker = SystemActionUIBroker()
        let controller = EKEventEditViewController()
        let operation = Task { try await broker.presentCalendarEditor(controller) }
        defer { operation.cancel() }
        _ = try await requirePresentation(from: broker)

        controller.editViewDelegate?.eventEditViewController(controller, didCompleteWith: .canceled)

        await #expect(throws: AppleSystemActionAdapterError.userCancelled(.calendar)) {
            try await operation.value
        }
        #expect(broker.activePresentation == nil)
    }

    @Test func contactNativeEditorCancellationResumesAwaiter() async throws {
        let broker = SystemActionUIBroker()
        let controller = CNContactViewController(forNewContact: CNMutableContact())
        let operation = Task { try await broker.presentContactEditor(controller) }
        defer { operation.cancel() }
        _ = try await requirePresentation(from: broker)

        controller.delegate?.contactViewController?(controller, didCompleteWith: nil)

        await #expect(throws: AppleSystemActionAdapterError.userCancelled(.contacts)) {
            try await operation.value
        }
        #expect(broker.activePresentation == nil)
    }

    @Test func brokerRejectsConcurrentPresentationWithoutOrphaningFirstRequest() async throws {
        let broker = SystemActionUIBroker()
        let first = Task {
            try await broker.presentCapture(
                actionID: UUID(),
                kind: .ink,
                suggestedTitle: nil,
                attachesToSource: false
            )
        }
        defer { first.cancel() }
        let firstPresentation = try await requirePresentation(from: broker)

        await #expect(throws: AppleSystemActionAdapterError.presentationInProgress(.contacts)) {
            try await broker.presentContactEditor(
                CNContactViewController(forNewContact: CNMutableContact())
            )
        }
        #expect(broker.activePresentation?.id == firstPresentation.id)

        broker.cancel(presentationID: firstPresentation.id)
        await #expect(throws: AppleSystemActionAdapterError.userCancelled(.capture)) {
            try await first.value
        }
    }

    @Test func photosRequestsOnlyAddAuthorizationAtConfirmedSave() async throws {
        let library = PhotoLibraryDouble(status: .notDetermined, requestedStatus: .authorized)
        let client = ApplePhotosClient(library: library)
        #expect(library.requestCount == 0)

        try await client.saveConfirmedExport(data: Data([0x89, 0x50]), type: .png)

        #expect(library.requestCount == 1)
        #expect(library.savedTypes == [UTType.png.identifier])
    }

    @Test func weatherRejectsInvalidCoordinateWithoutCallingProvider() async {
        let probe = AsyncProbe()
        let client = AppleWeatherContextClient { _ in
            await probe.mark()
            return AppleWeatherContext(
                observedAt: Date(), conditionCode: "clear", symbolName: "sun.max",
                temperatureCelsius: 20, apparentTemperatureCelsius: 20, humidity: 0.5
            )
        }

        await #expect(throws: AppleSystemActionAdapterError.invalidPayload(field: "coordinate")) {
            try await client.fetchConfirmedContext(latitude: 100, longitude: 0)
        }
        #expect(!(await probe.wasCalled))
    }

    @Test func healthRejectsBroadWindowBeforeAuthorization() async {
        let probe = AsyncProbe()
        let client = AppleHealthContextClient(
            requestAuthorization: { _ in
                await probe.mark()
                return true
            },
            readSteps: { _, _, _ in 10 }
        )
        let start = Date(timeIntervalSince1970: 0)

        await #expect(throws: AppleSystemActionAdapterError.invalidPayload(field: "healthWindow")) {
            try await client.readConfirmedStepContext(
                start: start,
                end: start.addingTimeInterval(8 * 24 * 60 * 60)
            )
        }
        #expect(!(await probe.wasCalled))
    }

    @Test func momentWithoutApprovedLocationDoesNotRequestCoreLocation() async throws {
        let store = MomentStoreDouble()
        let adapter = AppleMomentSystemActionAdapter(momentStore: store)
        let proposal = try momentProposal(location: nil)

        let result = try await adapter.execute(proposal: proposal, context: executionContext())
        let completedCoordinates = await store.completedCoordinates

        #expect(result.outcome == .succeeded)
        #expect(result.boundedResult?.summaryCode == "moment_captured")
        #expect(result.localMaterial?.metadata["moment_record_id"] == store.recordID.uuidString.lowercased())
        #expect(completedCoordinates.count == 1)
        #expect(completedCoordinates[0] == nil)
    }

    @Test func momentDiscardPersistsCleanupObligationAndRetriesAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-moment-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = AppleMomentStore(vaultRootURL: root)
        let id = try await firstStore.saveDraft(
            title: "Durable cleanup",
            occurredAt: Date(),
            contactReferenceHashes: [],
            photoFileURL: nil,
            photoFileExtension: nil
        )
        let manifest = root
            .appendingPathComponent("_agent/system-actions/moments", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")
        let validManifest = try Data(contentsOf: manifest)
        try Data("corrupt".utf8).write(to: manifest, options: .atomic)

        await #expect(throws: (any Error).self) {
            try await firstStore.discardDraft(id: id)
        }
        #expect(try await firstStore.pendingCleanupIDs() == [id])
        #expect(FileManager.default.fileExists(atPath: manifest.path))

        try validManifest.write(to: manifest, options: .atomic)
        let restartedStore = AppleMomentStore(vaultRootURL: root)
        try await restartedStore.retryPendingCleanup()
        #expect(try await restartedStore.pendingCleanupIDs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test func momentRejectIntentClosesCrossStoreCrashWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-moment-reject-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proposalID = UUID()
        let payloadHash = String(repeating: "a", count: 64)
        let firstStore = AppleMomentStore(vaultRootURL: root)
        let id = try await firstStore.saveDraft(
            title: "Cross-store cleanup",
            occurredAt: Date(),
            contactReferenceHashes: [],
            photoFileURL: nil,
            photoFileExtension: nil
        )
        let manifest = root
            .appendingPathComponent("_agent/system-actions/moments", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")

        // Crash before the ledger rejection: startup proves no decision exists,
        // cancels the intent, and preserves the user's draft.
        try await firstStore.prepareDiscard(
            id: id,
            proposalID: proposalID,
            proposalRevision: 1,
            payloadHash: payloadHash
        )
        let beforeRejectRestart = AppleMomentStore(vaultRootURL: root)
        try await beforeRejectRestart.retryPendingCleanup { _, _, _ in false }
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try await beforeRejectRestart.pendingCleanupIDs().isEmpty)

        // Crash after the exact rejection: the same durable intent is now
        // authorized by ledger evidence and cleanup completes after restart.
        try await beforeRejectRestart.prepareDiscard(
            id: id,
            proposalID: proposalID,
            proposalRevision: 1,
            payloadHash: payloadHash
        )
        let afterRejectRestart = AppleMomentStore(vaultRootURL: root)
        try await afterRejectRestart.retryPendingCleanup { id, revision, hash in
            id == proposalID && revision == 1 && hash == payloadHash
        }
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(try await afterRejectRestart.pendingCleanupIDs().isEmpty)
    }

    @available(iOS 16.1, *)
    @Test func focusResumeCompensatesAlertWhenActivityUpdateFails() async {
        enum UpdateFailure: Error { case unavailable }
        let probe = FocusTransactionProbe()

        await #expect(throws: UpdateFailure.unavailable) {
            try await AppleFocusSessionControlService.applyResumeTransaction(
                schedule: { await probe.record("schedule") },
                update: {
                    await probe.record("update")
                    throw UpdateFailure.unavailable
                },
                cancel: { await probe.record("cancel") }
            )
        }
        #expect(await probe.events == ["schedule", "update", "cancel"])
    }

    @available(iOS 16.1, *)
    @Test func focusResumeSurfacesFailedAlertCompensation() async {
        enum UpdateFailure: Error { case unavailable }
        enum CancelFailure: Error { case staleAlertMayRemain }
        let probe = FocusTransactionProbe()

        await #expect(throws: CancelFailure.staleAlertMayRemain) {
            try await AppleFocusSessionControlService.applyResumeTransaction(
                schedule: { await probe.record("schedule") },
                update: {
                    await probe.record("update")
                    throw UpdateFailure.unavailable
                },
                cancel: {
                    await probe.record("cancel")
                    throw CancelFailure.staleAlertMayRemain
                }
            )
        }
        #expect(await probe.events == ["schedule", "update", "cancel"])
    }

    @Test func localContextAdapterRequiresExistingTypeMatchedLocalReference() async throws {
        let referenceID = UUID()
        let verifier = LocalContextVerifierDouble(values: [
            referenceID: SystemActionLocalContextKind.healthSummary.rawValue
        ])
        let adapter = AppleLocalContextSystemActionAdapter(verifier: verifier)
        let proposal = try localContextProposal(referenceID: referenceID, kind: .healthSummary)

        let result = try await adapter.execute(proposal: proposal, context: executionContext())

        #expect(result.outcome == .succeeded)
        #expect(result.boundedResult?.metadata["context_kind"] == "health_summary")
        #expect(result.boundedResult?.metadata["context_reference"] == nil)
        #expect(result.localMaterial?.metadata["context_reference"] == referenceID.uuidString.lowercased())
    }

    @Test func localContextAdapterRejectsMissingReferenceWithoutFetchingFrameworkData() async throws {
        let referenceID = UUID()
        let adapter = AppleLocalContextSystemActionAdapter(
            verifier: LocalContextVerifierDouble(values: [:])
        )
        let proposal = try localContextProposal(referenceID: referenceID, kind: .weatherSummary)

        await #expect(throws: AppleSystemActionAdapterError.ambiguousOutcome(.localContext)) {
            try await adapter.execute(proposal: proposal, context: executionContext())
        }
    }

    @Test func localContextReferenceRejectsNonUUID() {
        #expect(throws: AppleSystemActionAdapterError.invalidPayload(field: "localContext.reference")) {
            try AppleLocalContextReference.parse("not-a-reference")
        }
    }

    @Test func localContextStorePersistsImmutableBoundedRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-local-context-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppleLocalContextStore(vaultRootURL: root)

        let referenceID = try await store.persist(
            kind: .weatherSummary,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            boundedValues: ["condition_code": "clear", "temperature_c": "22.5"]
        )

        #expect(await store.contains(referenceID: referenceID, kind: .weatherSummary))
        #expect(!(await store.contains(referenceID: referenceID, kind: .healthSummary)))
    }

    @Test func spotlightPrivacyPlaceholderExcludesPrivateSummary() async throws {
        let index = SearchableIndexDouble()
        let client = AppleSpotlightIndexer(index: index)

        try await client.upsert([AppleSpotlightRecord(
            identifier: "memo-1",
            domainIdentifier: "daypage.test",
            title: "Private title",
            summary: "alice@example.com private memo",
            keywords: ["private"],
            expirationDate: nil,
            contentURL: URL(string: "daypage://memo/1"),
            privacySensitive: true
        )])

        #expect(index.items.count == 1)
        #expect(index.items[0].attributeSet.title == "Private DayPage item")
        #expect(index.items[0].attributeSet.contentDescription == "Open DayPage to view this private item.")
        #expect(!(index.items[0].attributeSet.contentDescription?.contains("alice") ?? false))
        #expect(index.items[0].attributeSet.keywords?.isEmpty ?? true)
    }

    @Test func spotlightClearTargetsOnlyTheSystemActionDomain() async throws {
        let index = SearchableIndexDouble()
        let client = AppleSpotlightIndexer(index: index)

        try await client.clear(
            domainIdentifier: SystemActionSharedSummaryStore.spotlightDomainIdentifier
        )

        #expect(index.deletedDomains == [SystemActionSharedSummaryStore.spotlightDomainIdentifier])
    }
}
}

@MainActor
private func requirePresentation(
    from broker: SystemActionUIBroker
) async throws -> SystemActionUIPresentation {
    // Task.yield() is only a scheduling hint: a fixed number of yields can
    // finish before the child task gets its first MainActor turn. Wait for the
    // actual presentation under a bounded monotonic deadline instead.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let presentation = broker.activePresentation { return presentation }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw AppleSystemActionAdapterError.requiresUserInterface(.capture)
}

@MainActor
private final class MapProbe {
    var resolvedQuery: String?
    var openedName: String?
}

private final class NotificationCenterDouble: AppleNotificationCenter, @unchecked Sendable {
    var status: UNAuthorizationStatus
    var timeSensitive: UNNotificationSetting = .enabled
    var requestCount = 0
    var requests: [UNNotificationRequest] = []
    var removed: [String] = []

    init(status: UNAuthorizationStatus) { self.status = status }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func timeSensitiveSetting() async -> UNNotificationSetting { timeSensitive }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        status = .authorized
        return true
    }

    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
    func pendingRequestIdentifiers() async -> Set<String> { Set(requests.map(\.identifier)) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removed = identifiers }
}

@MainActor
private final class EventStoreDouble: AppleEventStore {
    private let backingStore = EKEventStore()
    var savedEvent: EKEvent?
    var savedReminder: EKReminder?
    var removedEventCount = 0
    var removedReminderCount = 0
    lazy var reminderCalendar: EKCalendar = {
        let calendar = EKCalendar(for: .reminder, eventStore: backingStore)
        calendar.title = "Reminders"
        return calendar
    }()

    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus { .authorized }
    func requestLegacyAccess(to entityType: EKEntityType) async throws -> Bool { true }
    func requestWriteOnlyEventAccess() async throws -> Bool { true }
    func requestFullEventAccess() async throws -> Bool { true }
    func requestFullReminderAccess() async throws -> Bool { true }
    var defaultCalendarForNewEvents: EKCalendar? { nil }
    func defaultCalendarForNewReminders() -> EKCalendar? { reminderCalendar }
    func calendars(for entityType: EKEntityType) -> [EKCalendar] { [reminderCalendar] }
    func save(event: EKEvent, span: EKSpan) throws {}
    func save(reminder: EKReminder, commit: Bool) throws { savedReminder = reminder }
    func event(withIdentifier identifier: String) -> EKEvent? { savedEvent }
    func predicateForEvents(withStart startDate: Date, end endDate: Date) -> NSPredicate {
        NSPredicate(value: false)
    }
    func events(matching predicate: NSPredicate) -> [EKEvent] { [] }
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
        guard savedReminder?.calendarItemIdentifier == identifier else { return nil }
        return savedReminder
    }
    func remove(event: EKEvent, span: EKSpan) throws { removedEventCount += 1 }
    func remove(reminder: EKReminder, commit: Bool) throws { removedReminderCount += 1 }
}

@MainActor
private final class ContactStoreDouble: AppleContactStore {
    let contact: CNContact
    var executeCount = 0

    init(contact: CNContact) {
        self.contact = contact
    }

    func authorizationStatus() -> CNAuthorizationStatus { .authorized }
    func requestAccess() async throws -> Bool { true }
    func execute(_ request: CNSaveRequest) throws { executeCount += 1 }
    func unifiedContact(identifier: String, keys: [CNKeyDescriptor]) throws -> CNContact { contact }
}

@available(iOS 16.1, *)
private final class FocusActivityDouble: AppleFocusActivityServing, @unchecked Sendable {
    let state: AppleAuthorizationState
    var startedTitles: [String] = []
    var identifiersByAction: [UUID: String] = [:]
    var endedIdentifiers: [String] = []
    var scheduledEnds: [(String, Date)] = []

    init(capabilityState: AppleAuthorizationState = .authorized) {
        self.state = capabilityState
    }

    func capabilityState() -> AppleAuthorizationState { state }

    func start(
        actionID: UUID,
        title: String,
        endsAt: Date,
        schedulesEndAlert: Bool
    ) throws -> AppleExternalReference {
        let identifier = "activity-\(actionID.uuidString.lowercased())"
        startedTitles.append(title)
        identifiersByAction[actionID] = identifier
        return .init(identifier: identifier, createdAt: Date())
    }

    func identifier(actionID: UUID) -> String? { identifiersByAction[actionID] }
    func reconcile(identifier: String) -> Bool { identifiersByAction.values.contains(identifier) }
    func scheduleEnd(identifier: String, at date: Date) { scheduledEnds.append((identifier, date)) }
    func update(identifier: String, endsAt: Date, isPaused: Bool) async throws {}

    func end(identifier: String) async throws {
        guard identifiersByAction.values.contains(identifier) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.liveActivity)
        }
        endedIdentifiers.append(identifier)
        identifiersByAction = identifiersByAction.filter { $0.value != identifier }
    }
}

private final class FocusAlarmDouble: AppleFocusAlarmServing, @unchecked Sendable {
    var scheduledReference: AppleExternalReference?
    var activeActionIDs: Set<UUID> = []

    func schedule(actionID: UUID, title: String, fireDate: Date) async -> AppleExternalReference? {
        guard let scheduledReference else { return nil }
        activeActionIDs.insert(actionID)
        return scheduledReference
    }

    func reconcile(actionID: UUID) async -> Bool { activeActionIDs.contains(actionID) }
    func cancel(actionID: UUID) async throws { activeActionIDs.remove(actionID) }
}

@available(iOS 16.1, *)
private final class FocusAlertDouble: AppleFocusEndAlertServing, @unchecked Sendable {
    var scheduledTitles: [String] = []
    var scheduledFireDates: [Date] = []
    var activeActionIDs: Set<UUID> = []

    func schedule(
        actionID: UUID,
        title: String,
        body: String,
        fireDate: Date,
        threadIdentifier: String?,
        interruption: UNNotificationInterruptionLevel,
        playsSound: Bool
    ) async throws -> AppleExternalReference {
        scheduledTitles.append(title)
        scheduledFireDates.append(fireDate)
        activeActionIDs.insert(actionID)
        return .init(
            identifier: AppleNotificationClient.requestIdentifier(actionID: actionID),
            createdAt: Date()
        )
    }

    func reconcile(actionID: UUID) async -> Bool { activeActionIDs.contains(actionID) }
    func cancel(actionID: UUID) { activeActionIDs.remove(actionID) }
}

private final class MutableDateBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private final class PhotoLibraryDouble: ApplePhotoLibrary, @unchecked Sendable {
    var status: PHAuthorizationStatus
    let requestedStatus: PHAuthorizationStatus
    var requestCount = 0
    var savedTypes: [String] = []

    init(status: PHAuthorizationStatus, requestedStatus: PHAuthorizationStatus) {
        self.status = status
        self.requestedStatus = requestedStatus
    }

    func addOnlyAuthorizationStatus() -> PHAuthorizationStatus { status }

    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        requestCount += 1
        status = requestedStatus
        return requestedStatus
    }

    func saveAsset(data: Data, uniformTypeIdentifier: String) async throws {
        savedTypes.append(uniformTypeIdentifier)
    }
}

private final class SearchableIndexDouble: AppleSearchableIndex, @unchecked Sendable {
    var items: [CSSearchableItem] = []
    var deletedDomains: [String] = []
    func index(_ items: [CSSearchableItem]) async throws { self.items = items }
    func delete(identifiers: [String]) async throws {}
    func delete(domainIdentifiers: [String]) async throws { deletedDomains = domainIdentifiers }
}

private actor AsyncProbe {
    private(set) var wasCalled = false
    func mark() { wasCalled = true }
}

private actor FocusTransactionProbe {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor LocalContextVerifierDouble: AppleLocalContextReferenceVerifying {
    let values: [UUID: String]

    init(values: [UUID: String]) {
        self.values = values
    }

    func contains(referenceID: UUID, kind: SystemActionLocalContextKind) async -> Bool {
        values[referenceID] == kind.rawValue
    }
}

private actor MomentStoreDouble: AppleMomentPersisting {
    nonisolated let recordID = UUID()
    private(set) var completedCoordinates: [CLLocationCoordinate2D?] = []

    func saveDraft(
        title: String,
        occurredAt: Date,
        contactReferenceHashes: [String],
        photoFileURL: URL?,
        photoFileExtension: String?
    ) async throws -> UUID { recordID }

    func complete(
        proposal: SystemActionProposal,
        coordinate: CLLocationCoordinate2D?
    ) async throws -> UUID {
        completedCoordinates.append(coordinate)
        return recordID
    }

    func isCompleted(id: UUID, proposalID: UUID) async -> Bool { id == recordID }
    func discardDraft(id: UUID) async throws {}
}

@MainActor
private final class OneShotLocationDouble: AppleOneShotLocationServing {
    let result: Result<AppleLocationSample, Error>

    init(result: Result<AppleLocationSample, Error>) {
        self.result = result
    }

    func authorizationState() -> AppleAuthorizationState { .authorized }
    func requestCurrentLocation() async throws -> AppleLocationSample { try result.get() }
}

private func localContextProposal(
    referenceID: UUID,
    kind: SystemActionLocalContextKind
) throws -> SystemActionProposal {
    try SystemActionProposal(
        payload: .localContextAttachment(.init(
            contextKind: kind,
            summaryCode: referenceID.uuidString.lowercased(),
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )),
        title: "Local context",
        rationale: "User confirmed local-only context",
        creatorSource: .user,
        creatorDeviceID: "test-device"
    )
}

private func momentProposal(location: SystemActionLocation?) throws -> SystemActionProposal {
    try SystemActionProposal(
        payload: .moment(.init(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "A bounded moment",
            location: location
        )),
        title: "Capture moment",
        rationale: "User confirmed the moment",
        creatorSource: .user,
        creatorDeviceID: "test-device"
    )
}

private func routeProposal() throws -> SystemActionProposal {
    try SystemActionProposal(
        payload: .route(.init(
            destination: .init(label: "Approved destination", latitude: 31.2304, longitude: 121.4737),
            mode: .walking
        )),
        title: "Open route",
        rationale: "User confirmed the route",
        creatorSource: .user,
        creatorDeviceID: "test-device"
    )
}

private func captureProposal(kind: SystemActionCaptureKind) throws -> SystemActionProposal {
    try SystemActionProposal(
        payload: .capture(.init(
            captureKind: kind,
            suggestedTitle: "Display-only title",
            attachesToSource: true
        )),
        title: "Capture",
        rationale: "User confirmed foreground capture",
        creatorSource: .user,
        creatorDeviceID: "test-device"
    )
}

private func focusProposal(
    schedulesEndAlert: Bool,
    allowsLiveActivity: Bool,
    redactionLevel: SystemActionRedactionLevel
) throws -> SystemActionProposal {
    try SystemActionProposal(
        payload: .focusSession(.init(
            title: "Secret customer work",
            durationSeconds: 25 * 60,
            schedulesEndAlert: schedulesEndAlert,
            allowsLiveActivity: allowsLiveActivity
        )),
        title: "Focus",
        rationale: "User confirmed focus session",
        creatorSource: .user,
        creatorDeviceID: "test-device",
        redactionLevel: redactionLevel
    )
}

private func notificationProposal(
    fireAt: Date,
    redactionLevel: SystemActionRedactionLevel
) throws -> SystemActionProposal {
    try SystemActionProposal(
        payload: .notification(.init(
            title: "Private customer title",
            body: "Private customer body",
            fireAt: fireAt,
            threadIdentifier: nil,
            interruption: .active,
            playsSound: true
        )),
        title: "Schedule notification",
        rationale: "User confirmed the notification",
        creatorSource: .user,
        creatorDeviceID: "test-device",
        redactionLevel: redactionLevel
    )
}

private func executionContext() -> SystemActionExecutionContext {
    .init(
        operationID: UUID(),
        phase: .execute,
        attempt: 1,
        deviceID: "test-device",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lease: nil
    )
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias SystemActionAppleAdapterTests = DayPageSerialSwiftTests.SystemActionAppleAdapterTests
