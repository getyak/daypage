package app.daypage.android.ui

import androidx.annotation.StringRes
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.ui.res.pluralStringResource
import androidx.core.net.toUri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.daypage.android.R
import app.daypage.android.auth.AccountIdentity
import app.daypage.android.auth.AccountState
import app.daypage.android.data.MemoEntity
import app.daypage.android.sync.SyncStatus
import app.daypage.designsystem.DayPageTokens
import kotlinx.coroutines.launch

private enum class Destination(@param:StringRes val label: Int, val icon: ImageVector) {
    Today(R.string.nav_today, Icons.Outlined.Home),
    Archive(R.string.nav_archive, Icons.Outlined.Archive),
    Graph(R.string.nav_graph, Icons.Outlined.GraphicEq),
    Ask(R.string.nav_ask, Icons.Outlined.Search),
    Settings(R.string.nav_settings, Icons.Outlined.Settings),
}

@Composable
fun DayPageApp(viewModel: HomeViewModel) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    DayPageContent(
        uiState = uiState,
        actions = DayPageActions(
            capture = viewModel::capture,
            appleAuthorizationUrl = viewModel::appleAuthorizationUrl,
            sendEmailLink = viewModel::sendEmailLink,
            signOutThisDevice = viewModel::signOutThisDevice,
            retrySync = viewModel::retrySync,
        ),
    )
}

internal data class DayPageActions(
    val capture: (String, () -> Unit) -> Unit,
    val appleAuthorizationUrl: () -> String?,
    val sendEmailLink: (String) -> Unit,
    val signOutThisDevice: () -> Unit,
    val retrySync: () -> Unit,
)

@Composable
internal fun DayPageContent(uiState: HomeUiState, actions: DayPageActions) {
    var destination by rememberSaveable { mutableStateOf(Destination.Today) }
    var showAccount by rememberSaveable { mutableStateOf(false) }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (maxWidth >= 840.dp) {
            Row(Modifier.fillMaxSize()) {
                DesktopNavigation(
                    destination = destination,
                    onDestination = { destination = it },
                    uiState = uiState,
                    onAccount = { showAccount = true },
                )
                VerticalDivider(
                    modifier = Modifier.fillMaxHeight().width(1.dp),
                    color = MaterialTheme.colorScheme.outlineVariant,
                )
                DestinationPage(
                    modifier = Modifier.weight(1f),
                    destination = destination,
                    uiState = uiState,
                    actions = actions,
                    onAccount = { showAccount = true },
                )
            }
        } else {
            CompactShell(
                destination = destination,
                onDestination = { destination = it },
                uiState = uiState,
                actions = actions,
                onAccount = { showAccount = true },
            )
        }
    }

    if (showAccount) {
        AccountCenter(
            uiState = uiState,
            actions = actions,
            onDismiss = { showAccount = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CompactShell(
    destination: Destination,
    onDestination: (Destination) -> Unit,
    uiState: HomeUiState,
    actions: DayPageActions,
    onAccount: () -> Unit,
) {
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    ModalNavigationDrawer(
        drawerState = drawerState,
        gesturesEnabled = drawerState.isOpen,
        drawerContent = {
            ModalDrawerSheet(
                modifier = Modifier.widthIn(max = 328.dp).fillMaxHeight(),
                drawerContainerColor = MaterialTheme.colorScheme.surface,
                drawerShape = RoundedCornerShape(topEnd = 28.dp, bottomEnd = 28.dp),
            ) {
                DrawerContent(
                    destination = destination,
                    onDestination = {
                        onDestination(it)
                        scope.launch { drawerState.close() }
                    },
                    uiState = uiState,
                    onAccount = {
                        scope.launch { drawerState.close() }
                        onAccount()
                    },
                    onClose = { scope.launch { drawerState.close() } },
                )
            }
        },
    ) {
        Scaffold(
            contentWindowInsets = WindowInsets.safeDrawing,
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                TopAppBar(
                    title = { Text(stringResource(destination.label)) },
                    navigationIcon = {
                        IconButton(
                            onClick = { scope.launch { drawerState.open() } },
                            modifier = Modifier.size(48.dp),
                        ) {
                            Icon(Icons.Outlined.Menu, contentDescription = stringResource(R.string.menu))
                        }
                    },
                    actions = {
                        IconButton(onClick = onAccount, modifier = Modifier.size(48.dp)) {
                            Icon(
                                Icons.Outlined.AccountCircle,
                                contentDescription = stringResource(R.string.account_center),
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background.copy(alpha = 0.96f),
                    ),
                )
            },
        ) { padding ->
            DestinationPage(
                modifier = Modifier.fillMaxSize().padding(padding),
                destination = destination,
                uiState = uiState,
                actions = actions,
                onAccount = onAccount,
            )
        }
    }
}

@Composable
private fun DrawerContent(
    destination: Destination,
    onDestination: (Destination) -> Unit,
    uiState: HomeUiState,
    onAccount: () -> Unit,
    onClose: () -> Unit,
) {
    Column(Modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 16.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 12.dp, bottom = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DayPageMark()
            Text(
                text = "DayPage",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(start = 12.dp).weight(1f),
            )
            IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) {
                Icon(Icons.Outlined.Close, contentDescription = stringResource(R.string.close))
            }
        }
        Destination.entries.forEach { entry ->
            NavigationDrawerItem(
                label = { Text(stringResource(entry.label)) },
                selected = destination == entry,
                onClick = { onDestination(entry) },
                icon = { Icon(entry.icon, contentDescription = null) },
                modifier = Modifier.padding(vertical = 2.dp),
                colors = NavigationDrawerItemDefaults.colors(
                    selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                ),
            )
        }
        Spacer(Modifier.weight(1f))
        AccountEntry(uiState = uiState, onClick = onAccount)
    }
}

@Composable
private fun DesktopNavigation(
    destination: Destination,
    onDestination: (Destination) -> Unit,
    uiState: HomeUiState,
    onAccount: () -> Unit,
) {
    NavigationRail(
        modifier = Modifier.width(92.dp).fillMaxHeight(),
        containerColor = MaterialTheme.colorScheme.surface,
        header = { DayPageMark(Modifier.padding(vertical = 12.dp)) },
    ) {
        Destination.entries.forEach { entry ->
            NavigationRailItem(
                selected = destination == entry,
                onClick = { onDestination(entry) },
                icon = { Icon(entry.icon, contentDescription = null) },
                label = { Text(stringResource(entry.label), maxLines = 1) },
            )
        }
        Spacer(Modifier.weight(1f))
        NavigationRailItem(
            selected = false,
            onClick = onAccount,
            icon = { Icon(Icons.Outlined.AccountCircle, contentDescription = null) },
            label = { Text(statusLabel(uiState), maxLines = 1) },
        )
        Spacer(Modifier.height(10.dp))
    }
}

@Composable
private fun DayPageMark(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(42.dp)
            .clip(RoundedCornerShape(13.dp))
            .background(MaterialTheme.colorScheme.primary),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "D",
            color = MaterialTheme.colorScheme.onPrimary,
            fontFamily = FontFamily.Serif,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.titleLarge,
        )
    }
}

@Composable
private fun AccountEntry(uiState: HomeUiState, onClick: () -> Unit) {
    val account = uiState.accountState.accountOrNull()
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(DayPageTokens.Radii.card))
            .clickable(onClick = onClick)
            .semantics { role = Role.Button },
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(DayPageTokens.Radii.card),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.AccountCircle, contentDescription = null)
            Column(Modifier.padding(start = 12.dp).weight(1f)) {
                Text(
                    account?.email ?: stringResource(R.string.local_profile),
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                )
                Text(
                    statusLabel(uiState),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun DestinationPage(
    modifier: Modifier,
    destination: Destination,
    uiState: HomeUiState,
    actions: DayPageActions,
    onAccount: () -> Unit,
) {
    when (destination) {
        Destination.Today -> CapturePage(modifier, uiState, actions.capture)
        Destination.Settings -> SettingsPage(modifier, uiState, onAccount)
        else -> PlaceholderPage(modifier, destination)
    }
}

@Composable
private fun CapturePage(
    modifier: Modifier,
    uiState: HomeUiState,
    onCapture: (String, () -> Unit) -> Unit,
) {
    var body by rememberSaveable { mutableStateOf("") }
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item {
            Column(
                modifier = Modifier.fillMaxWidth().widthIn(max = 720.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    stringResource(R.string.capture_title),
                    style = MaterialTheme.typography.headlineMedium,
                )
                Text(
                    stringResource(R.string.capture_body),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        item {
            Surface(
                shape = RoundedCornerShape(DayPageTokens.Radii.hero),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 0.dp,
                shadowElevation = 0.dp,
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    OutlinedTextField(
                        value = body,
                        onValueChange = { body = it },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp),
                        placeholder = { Text(stringResource(R.string.capture_placeholder)) },
                        shape = RoundedCornerShape(DayPageTokens.Radii.card),
                    )
                    Button(
                        onClick = { onCapture(body) { body = "" } },
                        enabled = body.isNotBlank(),
                        modifier = Modifier.fillMaxWidth().height(50.dp),
                        shape = RoundedCornerShape(DayPageTokens.Radii.pill),
                    ) {
                        Text(stringResource(R.string.save_noter))
                    }
                }
            }
        }
        item { SyncPill(uiState) }
        item {
            Text(stringResource(R.string.recent_noters), style = MaterialTheme.typography.titleLarge)
        }
        if (uiState.memos.isEmpty()) {
            item {
                Text(
                    stringResource(R.string.empty_noters),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 24.dp),
                )
            }
        } else {
            items(uiState.memos, key = MemoEntity::id) { memo -> MemoCard(memo) }
        }
    }
}

@Composable
private fun MemoCard(memo: MemoEntity) {
    Surface(
        modifier = Modifier.fillMaxWidth().widthIn(max = 720.dp),
        shape = RoundedCornerShape(DayPageTokens.Radii.card),
        color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(memo.body, style = MaterialTheme.typography.bodyLarge)
            Text(
                memo.createdAt.replace('T', ' ').take(16),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SyncPill(uiState: HomeUiState) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.primaryContainer,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            if (uiState.syncStatus is SyncStatus.Syncing) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Outlined.Sync, contentDescription = null, modifier = Modifier.size(16.dp))
            }
            Text(statusLabel(uiState), style = MaterialTheme.typography.labelLarge)
        }
    }
}

@Composable
private fun SettingsPage(modifier: Modifier, uiState: HomeUiState, onAccount: () -> Unit) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(stringResource(R.string.nav_settings), style = MaterialTheme.typography.displaySmall)
        AccountEntry(uiState, onAccount)
        Text(
            stringResource(R.string.privacy_note),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun PlaceholderPage(modifier: Modifier, destination: Destination) {
    Box(modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(destination.icon, contentDescription = null, modifier = Modifier.size(42.dp))
            Text(
                stringResource(destination.label),
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(top = 16.dp),
            )
            Text(
                stringResource(R.string.coming_soon),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AccountCenter(
    uiState: HomeUiState,
    actions: DayPageActions,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val account = uiState.accountState.accountOrNull()
    var email by rememberSaveable { mutableStateOf("") }
    var confirmSignOut by rememberSaveable { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 8.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            DayPageMark()
            Text(stringResource(R.string.account_center), style = MaterialTheme.typography.displaySmall)
            if (account == null) {
                Text(stringResource(R.string.sign_in_title), style = MaterialTheme.typography.titleLarge)
                Text(
                    stringResource(R.string.sign_in_body),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Button(
                    onClick = {
                        actions.appleAuthorizationUrl()?.let { url ->
                            CustomTabsIntent.Builder().setShowTitle(false).build()
                                .launchUrl(context, url.toUri())
                        }
                    },
                    enabled = uiState.accountState !is AccountState.Authenticating,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF171717),
                        contentColor = Color.White,
                    ),
                    shape = RoundedCornerShape(DayPageTokens.Radii.pill),
                ) {
                    Text(stringResource(R.string.continue_apple))
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text(stringResource(R.string.email)) },
                    placeholder = { Text(stringResource(R.string.email_hint)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(DayPageTokens.Radii.card),
                )
                FilledTonalButton(
                    onClick = { actions.sendEmailLink(email) },
                    enabled = email.isNotBlank() && uiState.accountState !is AccountState.Authenticating,
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(DayPageTokens.Radii.pill),
                ) {
                    if (uiState.accountState is AccountState.Authenticating) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.send_magic_link))
                    }
                }
                if (uiState.notice == HomeViewModel.MAGIC_LINK_SENT) {
                    Text(
                        stringResource(R.string.magic_link_sent),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            } else {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = RoundedCornerShape(DayPageTokens.Radii.hero),
                ) {
                    ListItem(
                        headlineContent = {
                            Text(account.email ?: account.userId, maxLines = 1)
                        },
                        supportingContent = { Text(statusLabel(uiState)) },
                        leadingContent = {
                            Icon(Icons.Outlined.AccountCircle, contentDescription = null)
                        },
                        colors = ListItemDefaults.colors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant,
                        ),
                    )
                }
                if (uiState.pendingCount > 0) {
                    Text(
                        pluralStringResource(
                            R.plurals.pending_count,
                            uiState.pendingCount,
                            uiState.pendingCount,
                        ),
                        style = MaterialTheme.typography.bodyLarge,
                    )
                }
                if (uiState.syncStatus is SyncStatus.ActionRequired ||
                    uiState.accountState is AccountState.ActionRequired
                ) {
                    FilledTonalButton(
                        onClick = actions.retrySync,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                    ) {
                        Icon(Icons.Outlined.Sync, contentDescription = null)
                        Text(stringResource(R.string.retry_sync), modifier = Modifier.padding(start = 8.dp))
                    }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Text(
                    stringResource(R.string.sign_out_explainer),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedButton(
                    onClick = { confirmSignOut = true },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(DayPageTokens.Radii.pill),
                ) {
                    Text(stringResource(R.string.sign_out_device))
                }
            }
            val error = (uiState.accountState as? AccountState.ActionRequired)?.message
                ?: uiState.notice?.takeUnless { it == HomeViewModel.MAGIC_LINK_SENT }
            if (!error.isNullOrBlank()) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(DayPageTokens.Radii.card),
                ) {
                    Text(
                        error,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(14.dp),
                    )
                }
            }
            Text(
                stringResource(R.string.privacy_note),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text(stringResource(R.string.sign_out_confirm_title)) },
            text = { Text(stringResource(R.string.sign_out_explainer)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmSignOut = false
                    actions.signOutThisDevice()
                }) { Text(stringResource(R.string.sign_out)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmSignOut = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

@Composable
private fun statusLabel(uiState: HomeUiState): String = when {
    uiState.accountState is AccountState.ActionRequired ||
        uiState.syncStatus is SyncStatus.ActionRequired -> stringResource(R.string.action_required)
    uiState.accountState is AccountState.LocalOnly -> stringResource(R.string.local_only)
    uiState.accountState is AccountState.Authenticating ||
        uiState.accountState is AccountState.BoundAndSyncing ||
        uiState.syncStatus is SyncStatus.Syncing -> stringResource(R.string.syncing)
    uiState.pendingCount > 0 -> pluralStringResource(
        R.plurals.offline_queued,
        uiState.pendingCount,
        uiState.pendingCount,
    )
    else -> stringResource(R.string.synced)
}

private fun AccountState.accountOrNull(): AccountIdentity? = when (this) {
    is AccountState.BoundAndSyncing -> account
    is AccountState.Synced -> account
    is AccountState.OfflineQueued -> account
    is AccountState.ActionRequired -> account
    AccountState.Authenticating,
    AccountState.LocalOnly,
    -> null
}
