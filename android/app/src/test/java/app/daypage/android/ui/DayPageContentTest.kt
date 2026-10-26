package app.daypage.android.ui

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import app.daypage.android.ui.theme.DayPageTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(
    sdk = [35],
    application = Application::class,
    qualifiers = "en-rUS-w390dp-h844dp-normal-notlong-notround-port",
)
class DayPageContentTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun compactShellExposesDrawerAndAccountCenter() {
        composeRule.setContent {
            DayPageTheme(darkTheme = false) {
                DayPageContent(HomeUiState(), noOpActions())
            }
        }

        composeRule.onNodeWithText("Keep this moment.").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Menu").performClick()
        composeRule.onNodeWithText("Archive").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.onNodeWithContentDescription("Account Center").performClick()
        composeRule.onNodeWithText("Continue with Apple").assertIsDisplayed()
        composeRule.onNodeWithText("Email me a sign-in link").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun longCaptureStaysVisibleAndWaitsForSaveCallback() {
        val draft = "A captured thought.\n".repeat(80)
        var confirmSave: (() -> Unit)? = null
        val actions = noOpActions().copy(capture = { _, onSaved -> confirmSave = onSaved })
        composeRule.setContent {
            DayPageTheme(darkTheme = false) {
                DayPageContent(HomeUiState(), actions)
            }
        }

        composeRule.onNode(hasSetTextAction()).performTextInput(draft)
        composeRule.onNodeWithText("Keep this note").assertIsDisplayed().performClick()
        composeRule.onNode(hasSetTextAction()).assertTextEquals(draft)
        composeRule.runOnIdle { requireNotNull(confirmSave).invoke() }
        composeRule.onNodeWithText("What is on your mind?").assertIsDisplayed()
    }

    @Test
    @Config(qualifiers = "en-rUS-w1024dp-h800dp-normal-notlong-notround-land")
    fun expandedShellUsesPersistentNavigationRail() {
        composeRule.setContent {
            DayPageTheme(darkTheme = true) {
                DayPageContent(HomeUiState(), noOpActions())
            }
        }

        composeRule.onNodeWithText("Today").assertIsDisplayed()
        composeRule.onNodeWithText("Archive").assertIsDisplayed()
        composeRule.onNodeWithText("Graph").assertIsDisplayed()
        composeRule.onNodeWithText("Ask").assertIsDisplayed()
        composeRule.onNodeWithText("Settings").assertIsDisplayed()
    }

    private fun noOpActions() = DayPageActions(
        capture = { _, onSaved -> onSaved() },
        appleAuthorizationUrl = { null },
        sendEmailLink = {},
        signOutThisDevice = {},
        retrySync = {},
    )
}
