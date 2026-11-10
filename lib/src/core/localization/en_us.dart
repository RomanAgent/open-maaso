// ignore_for_file: file_names

import 'package:maaso/src/core/localization/secondary_en_us.dart';

const Map<String, String> enUS = {
  'skill.app_invocation.name': 'Use apps and games',
  'skill.app_invocation.description':
      'Use the work selected in chat and bring its results back to the conversation.',
  'agent_runtime.creation_intent_protocol_unavailable':
      'The creation request was not handed off correctly, so coding has not started. Your original request is retained; you can retry it directly.',
  'agent_runtime.creation_proposal_unavailable':
      'That project proposal is no longer available, and creation has not started. Tell me what you want to make this time and I will continue from your idea.',
  'agent_runtime.creation_edit_unavailable':
      'I could not find the project to edit. Open it and tell me the changes you want, and I will continue writing it.',
  'agent_runtime.creation_cancel_unavailable':
      'I could not find the creation task to stop. Check the task and try again.',
  'agent_runtime.creation_proposed':
      'I can turn that idea into a project. Tell me when you want to start.',
  'agent_runtime.creation_intent_unavailable':
      'I could not confirm the work type this time, so coding has not started. Retry your original request; you do not need to add “game” or reduce its content.',
  'home.task.type.gameGeneration': 'Game creation',
  'home.task.type.surfaceGeneration': 'Applet creation',
  'home.task.type.image': 'Image creation',
  'home.task.type.skillTask': 'Agent task',
  'home.task.type.none': 'Agent task',
  'home.task.elapsed': 'Elapsed @duration',
  'home.task.updated_at': 'Last updated @time',
  'home.task.current_action': 'Current step',
  'home.task.last_action': 'Stopped at this step',
  'home.task.recorded_nodes': '@completed / @count recorded steps complete',
  'home.task.recorded_events': '@count progress records',
  'home.task.process_note':
      'These records show decisions, production actions and checks from actual execution.',
  'home.task.group.active': 'In progress',
  'home.task.group.attention': 'Needs attention',
  'home.task.group.finished': 'Finished',
  'home.task.history_empty':
      'No creation tasks yet. Ask for a game or applet to follow its progress here.',
  'home.task.failure.modelUnavailable': 'The model service is unavailable.',
  'home.task.failure.modelUnavailable_action':
      'Check the current model and connection, then retry when available.',
  'home.task.failure.modelTimeout':
      'The model did not respond before the time limit.',
  'home.task.failure.modelTimeout_action':
      'Your request and records are retained. Retry when the model connection recovers.',
  'home.task.failure.modelOutputTruncated':
      'The generated code was cut short and is incomplete.',
  'home.task.failure.modelOutputTruncated_action':
      'Your request is retained. Retry, or select a model with longer output.',
  'home.task.failure.modelStreamInterrupted':
      'The model connection ended before all source was received.',
  'home.task.failure.modelStreamInterrupted_action':
      'Your request is retained. Retry when the connection recovers.',
  'home.task.failure.modelSafetyBlocked':
      'The model service did not return usable game source.',
  'home.task.failure.modelSafetyBlocked_action':
      'Adjust the game theme and retry, or check the current model service.',
  'home.task.failure.structuredOutputUnsupported':
      'This model endpoint does not support the JSON output required for game generation.',
  'home.task.failure.structuredOutputUnsupported_action':
      'Choose an endpoint with JSON output support in model settings and retry.',
  'home.task.failure.modelAuthentication':
      'The model API could not authenticate.',
  'home.task.failure.modelAuthentication_action':
      'Check the API configuration in Settings, then retry.',
  'home.task.failure.modelQuotaExceeded': 'The model API quota is exhausted.',
  'home.task.failure.modelQuotaExceeded_action':
      'Restore the API quota or select an available model, then retry.',
  'home.task.failure.modelRateLimited':
      'The model service is temporarily rate limited.',
  'home.task.failure.modelRateLimited_action':
      'Wait a little before retrying. Your request and progress are retained.',
  'home.task.failure.modelContextLimit':
      'The request and context exceed the model\'s capacity.',
  'home.task.failure.modelContextLimit_action':
      'Your request is retained. Check model context capacity or select another model, then retry.',
  'home.task.failure.modelConsentRequired':
      'The model service requires consent before use.',
  'home.task.failure.modelConsentRequired_action':
      'Complete the required consent in model settings, then retry.',
  'home.task.failure.modelMembershipRequired':
      'The current model requires membership access.',
  'home.task.failure.modelMembershipRequired_action':
      'Check account access or select an available model, then retry.',
  'home.task.failure.generationStalled':
      'File generation stopped making progress. The workspace draft is retained.',
  'home.task.failure.generationStalled_action':
      'Retry to continue from the saved file cursor.',
  'home.task.failure.generationProfileUnavailable':
      'The selected model has no reviewed generation billing profile.',
  'home.task.failure.generationProfileUnavailable_action':
      'Choose a configured generation model. Your workspace draft is retained.',
  'home.task.failure.generationCreditInsufficient':
      'Available credits cannot fund the next generation request.',
  'home.task.failure.generationCreditInsufficient_action':
      'Add credits and retry to continue saved files without reducing your request.',
  'home.task.failure.responseInvalid':
      'The model response did not follow the generation format.',
  'home.task.failure.generationCapacityExceeded':
      'The project reached the runtime source capacity. The last valid draft is retained.',
  'home.task.failure.generationCapacityExceeded_action':
      'Your complete request and last valid draft are retained. This is the runtime storage boundary.',
  'home.task.failure.responseInvalid_action':
      'Retry. Your request and existing progress records are retained.',
  'home.task.failure.surfaceValidationFailed':
      'The generated content failed structure or safety checks.',
  'home.task.failure.surfaceValidationFailed_action':
      'Retry generation. Content that failed checks is not treated as a completed project.',
  'home.task.failure.gameRuntimeTimeout':
      'The game did not show a playable screen during runtime checks.',
  'home.task.failure.gameRuntimeTimeout_action':
      'Retry to repair the first screen and gameplay initialization.',
  'home.task.failure.gameRuntimeFailed': 'The game failed its runtime checks.',
  'home.task.failure.gameRuntimeFailed_action':
      'Retry to repair it. Existing saved projects are preserved.',
  'home.task.failure.storageFailed':
      'The project or task record could not be saved.',
  'home.task.failure.storageFailed_action':
      'Check storage and service connectivity, then retry. Saved status requires a successful receipt.',
  'home.task.failure.quotaExceeded':
      'The cloud project storage limit has been reached.',
  'home.task.failure.quotaExceeded_action':
      'Your source is retained. Local creation has no such limit; manage cloud projects before syncing again.',
  'home.task.failure.quotaUnavailable':
      'The account context required to save the project is unavailable.',
  'home.task.failure.quotaUnavailable_action':
      'Check the signed-in account and retry. Your request is retained.',
  'home.task.failure.generationRequestUnrecognized':
      'The creation request was not recognized during task handoff. Code generation has not started.',
  'home.task.failure.generationRequestUnrecognized_action':
      'Your original request is retained. Retry without shortening or changing the game content.',
  'home.task.failure.generationAuthorizationUnavailable':
      'The creation capability has no valid authorization. Code generation has not started.',
  'home.task.failure.generationAuthorizationUnavailable_action':
      'Your original request is retained. Retry when the capability is restored; this is not a generated-content error.',
  'home.task.failure.actionUnavailable':
      'An action required for generation is unavailable.',
  'home.task.failure.actionUnavailable_action':
      'Check local execution access and task status before retrying.',
  'home.task.failure.missingArtifact':
      'This task did not return a valid saved project.',
  'home.task.failure.missingArtifact_action':
      'Retry. Completion requires a verified project result.',
  'home.task.failure.interrupted':
      'The previous attempt was interrupted by process exit or device change.',
  'home.task.failure.interrupted_action':
      'Your request and records are retained. Retry to start a new attempt.',
  'home.task.failure.taskTimeout':
      'This task exceeded its total execution time.',
  'home.task.failure.taskTimeout_action':
      'Start with the core gameplay and add features in later steps. Your request and records are retained.',
  'home.task.failure.referenceUnavailable':
      'A reference image is unavailable on this device or service.',
  'home.task.failure.referenceUnavailable_action':
      'Select the image again and start creation. The original task is retained.',
  'home.task.failure.cleanupFailed':
      'Cleanup after cancellation or failure is incomplete.',
  'home.task.failure.cleanupFailed_action':
      'Try again later. Existing saved projects are retained.',
  'home.task.failure.unknown':
      'Generation failed without an identifiable cause.',
  'home.task.failure.unknown_action':
      'Your request and existing records are retained. You can retry.',
  'avatar_store.bundled_female': 'Bundled female character',
  'avatar_store.bundled_female_summary':
      'Joy is included with the app. Select her to switch the avatar and its assigned female voice.',
  'asset_store.search': 'Search this section',
  'asset_store.sort.popular': 'Most used',
  'asset_store.sort.recent': 'Latest',
  'asset_store.empty': 'No matching assets',
  'asset_store.more': 'Load more',
  'asset_store.unavailable': 'Unable to load this asset. Please try again.',
  'asset_store.version_changed':
      'This asset version has changed. Reload the store before continuing.',
  'asset_store.preview': 'Play verified preview',
  'asset_store.preview_unavailable': 'No animated preview is available yet.',
  'asset_store.preview_failed': 'Preview could not be verified or played.',
  'asset_store.examples': 'Examples',
  'asset_store.install': 'Install this version',
  'asset_store.select': 'Use this model',
  'asset_store.installed': 'Installed',
  'asset_store.selected': 'Selected',
  'asset_store.currently_using': 'Currently using',
  'asset_store.working': 'Applying…',
  'asset_store.confirm_install':
      'Install this exact skill version? Any requested permissions will be shown next.',
  'asset_store.confirm_select': 'Use this exact model version for your Agent?',
  'asset_store.metric.active_installations': '@count active installations',
  'asset_store.metric.current_selections': '@count current users',

  'auth.doorway.welcome': 'Welcome home',
  'auth.doorway.subtitle': 'Sign in to meet your Agent',
  'auth.doorway.idle': 'Welcome home',
  'auth.doorway.preparing': 'Preparing your room…',
  'auth.doorway.opening': 'Opening the door',
  'auth.doorway.entering': 'Entering your room',
  'auth.doorway.framing': 'Meeting your Agent',
  'auth.doorway.completed': 'Welcome home',
  'auth.doorway.skipped': 'Entering Home',
  'auth.doorway.cancelled': 'Transition ended',
  'auth.doorway.skip': 'Skip',
  'home.task.view_process': 'View progress',
  'home.task.process': 'Task progress',
  'home.task.collapse': 'Collapse',
  'home.task.node.expand': 'Expand step details',
  'home.task.node.collapse': 'Collapse step details',
  'home.task.node.details': 'Step details',
  'home.task.evidence.started': 'Started',
  'home.task.evidence.passed': 'Passed',
  'home.task.evidence.failed': 'Failed',
  'home.task.evidence.completed': 'Completed',
  'home.task.evidence.count': '@count items',
  'home.task.progress.generating': 'Generating the project content',
  'home.task.progress.generating_details':
      'At this step, the generation request had started. Content had not yet passed validation or been saved.',
  'home.task.progress.request_started': 'Generation request started',
  'home.task.progress.checked': 'Generated actions passed pre-execution checks',
  'home.task.progress.checked_details':
      'The response format and action admission checks passed at this step. Runtime validation and saving were still pending.',
  'home.task.progress.check_evidence': 'Response and action checks',
  'home.task.progress.saving': 'Validating and saving the generated project',
  'home.task.progress.saving_details':
      'At this step, the project entered the validation and save flow. A committed result was still required before completion.',
  'home.task.progress.save_started': 'Project save flow started',
  'home.task.progress.saved': 'Received the saved project receipt',
  'home.task.progress.saved_details':
      'The save flow returned a committed project receipt, followed by a check that exactly one result belonged to this execution.',
  'home.task.progress.saved_evidence': 'Committed project result',
  'home.task.history': 'Task history',
  'home.task.active_count': '@count active tasks',
  'home.task.unavailable': 'This task is unavailable',
  'home.task.action_unavailable':
      'This action is unavailable. Check the task and local execution status, then retry.',
  'home.task.persistence_failed':
      'Could not save the task record. Please retry later.',
  'home.task.open_result': 'Open result',
  'home.task.continue_generation': 'Continue generating',
  'home.task.edit_result': 'Continue editing',
  'home.task.versions': 'Version history',
  'home.task.preview_result': 'Preview result',
  'home.task.preview_ready_message':
      'The draft is ready. Preview it to validate and confirm saving.',
  'home.task.stage.submitting': 'Submitting task',
  'home.task.stage.queued': 'Task queued',
  'home.task.stage.synchronizing': 'Reconciling task progress',
  'home.task.stage.generating': 'Generating',
  'home.task.stage.validating': 'Checking generated content',
  'home.task.stage.saving': 'Validating and saving',
  'home.task.stage.awaitingInput': 'Waiting for input',
  'home.task.stage.previewReady': 'Generated; awaiting preview and save',
  'home.task.stage.cancelling': 'Cancelling safely',
  'home.task.stage.completed': 'Saved',
  'home.task.stage.failed': 'Generation failed',
  'home.task.stage.cancelled': 'Cancelled',
  'home.task.stage.interrupted': 'Previous run interrupted; retry available',
  'account_deletion.title': 'Delete account',
  'people_safety.title': 'Blocked people',
  'privacy.title': 'Privacy and permissions',
  'identity.title': 'Public identities',
  'identity.onboarding.title': 'Create public identities',
  'app.title': 'Maaso',
  'home.avatar_preparing': 'Preparing your companion…',
  'home.avatar_entry_failed':
      'Your companion couldn’t enter. Please try again.',
  'home.avatar_selection_unavailable':
      'Your companion could not sync. Please try again.',
  'home.avatar_selection_retrying': 'Syncing your companion again…',
  'chat.account_unavailable':
      'Please sign in again before sending this message.',
  'chat.scroll_to_latest': 'Back to latest messages',

  'locale.system': 'System',
  'locale.english': 'English',
  'locale.simplified_chinese': 'Simplified Chinese',

  'common.save': 'Save',
  'common.next': 'Next',
  'common.continue': 'Continue',
  'common.retry': 'Retry',
  'common.cancel': 'Cancel',
  'common.close': 'Close',
  'common.confirm': 'Confirm',
  'common.scan': 'Scan',
  'common.stop': 'Stop',
  'common.deploy': 'Deploy',
  'common.got_it': 'Got it',
  'common.tap_to_open': 'Tap to open',
  'common.widgets_count': '@count widgets',
  'common.apis_count': '@count APIs',
  'common.more_count': '+@count more',
  'common.left_duration': '@duration left',
  'common.remaining_bytes': '@bytes remaining',
  'common.request_rate_limited': 'Too many requests. Please try again later.',
  'common.action_unavailable': 'This action is not available right now.',
  'common.request_failed': 'That request did not go through. Please try again.',
  'common.agent': 'Agent',
  'common.duration_seconds_short': '@count s',

  'auth.environment': 'Environment',
  'auth.environment.test': 'Test',
  'auth.environment.production': 'Production',
  'auth.sign_up': 'Sign up',
  'auth.sign_in': 'Sign in',
  'auth.continue_with_provider': 'Continue with @provider',
  'auth.email': 'Email',
  'auth.password': 'Password',
  'auth.hide_password': 'Hide password',
  'auth.show_password': 'Show password',
  'auth.verification_code': 'Verification code',
  'auth.create_account': 'Create account',
  'auth.log_in': 'Log in',
  'auth.switch_to_login': 'Already have an account? Log in',
  'auth.switch_to_signup': 'No account? Create account',
  'auth.send_code': 'Send code',
  'auth.provider_unavailable': '@provider sign-in is not available yet.',
  'auth.email_password_required': 'Enter your email and password.',
  'auth.email_required': 'Enter your email first.',
  'auth.code_sent': 'Verification code sent.',
  'auth.code_required': 'Enter the verification code.',
  'auth.send_code_first': 'Send a verification code first.',
  'auth.login_failed': 'Login failed. Please try again.',
  'auth.code_request_failed':
      'The verification code could not be sent. Please try again.',
  'auth.code_response_invalid':
      'The verification service returned an invalid response.',
  'auth.signup_failed': 'Sign-up failed. Please try again.',
  'auth.refresh_failed': 'The login session could not be refreshed.',
  'auth.session_reauthentication_required':
      'Your previous sign-in could not be restored. Please sign in again.',

  'chat.title': 'Chat',
  'chat.input_hint': 'Say something...',
  'chat.input_hint_agent': 'Say something to your Agent...',
  'chat.history': 'Chat history',
  'chat.thinking': 'Thinking...',
  'chat.my_agent': 'My Agent',
  'chat.online_with_you': 'Online · Always with you',
  'chat.voice_title': 'Voice input',
  'chat.voice_unavailable': 'Voice input is not available on this build',
  'chat.microphone_permission':
      'Microphone permission is required for voice input',
  'chat.voice_model_not_ready': 'Voice model is not ready: @error',
  'chat.voice_model_not_ready_short':
      'Voice model is not ready yet — try again in a moment',
  'chat.microphone_unavailable': 'Microphone unavailable',
  'chat.api_key_missing':
      'API Key is not configured yet. Please go to Settings to fill it in.',
  'chat.api_key_missing_error': 'Error: API Key not configured',
  'chat.llm_api_key_missing': 'LLM API Key not configured.',
  'chat.generic_error': 'Error: @error',
  'chat.empty_reply': 'Hmm...',
  'chat.execution_error': 'Execution error: @error',
  'chat.send_message': 'Send message',
  'chat.stop_response': 'Stop response',
  'chat.start_voice_input': 'Start voice input',
  'chat.voice_assistant': 'Voice assistant',
  'chat.voice_listening': 'Listening',
  'chat.voice_recognizing': 'Recognizing',
  'chat.voice_thinking': 'Thinking',
  'chat.voice_speaking': 'Speaking',
  'chat.voice_listening_return_keyboard':
      'Listening. Tap to return to the keyboard.',
  'chat.voice_recognizing_return_keyboard':
      'Recognizing speech. Tap to return to the keyboard.',
  'chat.voice_thinking_return_keyboard':
      'Thinking. Tap to return to the keyboard.',
  'chat.voice_speaking_return_keyboard':
      'Speaking. Tap to return to the keyboard.',
  'chat.agent_typing': 'Agent is typing',
  'chat.dismiss_latest_reply': 'Dismiss latest Agent reply',
  'chat.realtime_voice_failed': 'Realtime voice is unavailable right now.',
  'chat.voice_recognition_failed':
      'Voice recognition failed. Please try again.',

  'agent_control.voice_control': 'Agent voice control',
  'agent_control.status.speaking': 'Speaking',
  'agent_control.status.ready': 'Ready',
  'agent_control.status.waiting_permission': 'Waiting for permission',
  'agent_control.status.navigating': 'Navigating',
  'agent_control.status.operating': 'Operating the current page',
  'agent_control.status.paused': 'Paused by user',
  'agent_control.status.completed': 'Completed',
  'agent_control.status.failed': 'Failed',
  'agent_control.active_label': 'Agent is controlling the app',

  'companion.voice_semantics': 'Voice companion',
  'companion.avatar_semantics': 'Companion avatar',
  'companion.show_avatar': 'Show 3D companion',
  'companion.start_voice': 'Start 3D voice companion',
  'companion.tap_or_drag_hint': 'Tap, or drag right from this handle',
  'companion.hide_avatar': 'Hide avatar and keep talking',
  'companion.end_session': 'End companion session',
  'companion.portal_retry': '3D companion is unavailable. Tap to retry.',

  'home.stop': 'Stop',
  'home.menu.model_store': 'Model Store',
  'home.menu.agent_space': 'Agent Space',
  'agent_space.exit': 'Exit space',
  'agent_space.failed': 'Your avatar is not ready. Please try again.',
  'home.menu.personal_space': 'Personal space',
  'home.menu_open': 'Open menu',
  'home.menu_close': 'Close menu',
  'home.vision_on': 'Vision on',
  'home.vision_off': 'Vision off',
  'home.agent_thinking': 'Agent is thinking',
  'home.dismiss_thought': 'Dismiss thought',
  'home.pages': 'Pages',
  'home.plan_progress': 'Plan @done/@total',
  'home.no_delayed_branch': 'There is no executable branch to commit yet.',
  'home.commit_result': 'Commit result: @result',
  'home.no_delayed_executor': 'No delayed executor is available.',
  'home.discarded_branches': 'Discarded @count pending branch(es).',
  'home.api_key_card_opened':
      'Sure. I opened the API Key card. Fill it in and tap Save.',
  'home.local_model_loading_fallback':
      'My local brain is still loading. For now: hi, I am here. Once the model is ready, I can answer properly.',
  'home.local_model_unavailable_fallback':
      'Hi, I am here. The local model is not ready and the cloud brain is not connected yet, so I will stay with you in lightweight mode for now.',
  'home.no_brain_fallback':
      'I am not connected to the cloud brain yet, and the local brain is not ready either. You can type /setting to help me fill in an API Key.',
  'home.hosted_agent_unavailable':
      'Maaso Agent is not connected right now. Please check your network or sign in again. (@reason)',
  'home.local_agent_clarify': 'Hmm, let me double-check what you mean?',
  'home.local_agent_commit_required':
      'I need your go-ahead before I do that one.',

  'dashboard.title': 'Info Dashboard',
  'dashboard.tts_checking_cache': 'Checking voice model cache...',
  'dashboard.tts_downloading':
      'Downloading voice model · @received / @total@eta',
  'dashboard.tts_failed':
      'Neural TTS is not ready, automatically reverted to system voice',
  'dashboard.status_battery': 'Battery',
  'dashboard.status_network': 'Network',
  'dashboard.status_hardware': 'Hardware',
  'dashboard.status_online': 'Online',
  'dashboard.status_offline': 'Offline',
  'dashboard.status_connected': 'Connected',
  'dashboard.status_disconnected': 'Disconnected',
  'dashboard.action_story': 'Our Story',
  'dashboard.action_story_subtitle':
      'The moments we have lived through together',
  'dashboard.action_history': 'Chat History',
  'dashboard.action_history_subtitle': 'View full conversation history',
  'dashboard.action_moments': 'Moments',
  'dashboard.action_moments_subtitle': 'My life in parallel universes',
  'dashboard.action_skills': 'Skills',
  'dashboard.action_skills_subtitle': 'Install, Store, Coming soon',
  'dashboard.action_garden': 'Agent Garden',
  'dashboard.action_garden_subtitle': 'Mini apps she made for you',
  'dashboard.action_settings': 'Settings',
  'dashboard.action_settings_subtitle': 'BYOK · Personality · Hardware',

  'profile.title': 'Personal information',
  'membership.title': 'Maaso membership',
  'settings.page_subtitle': 'Interface, senses and device preferences',
  'settings.devices_preferences': 'Devices & preferences',
  'settings.privacy_account': 'Privacy & account',
  'settings.projector_connection': 'Projector connection',
  'settings.device_connected': 'Connected',
  'settings.device_disconnected': 'Not connected',
  'settings.device_scanning': 'Searching',
  'settings.system_permission_hint': 'Manage permission in system settings',
  'settings.appearance': 'Appearance',
  'settings.appearance_current': 'Appearance: @mode',
  'settings.logout_confirm_hint': 'Sign out of this account?',
  'settings.notifications_allow_hint':
      'Receive system notifications from Maaso',
  'settings.notifications_scheduled_hint':
      'Receive reminders for scheduled tasks',
  'settings.context_expand': 'Show context details',
  'settings.context_collapse': 'Hide context details',
  'settings.title': 'Settings',
  'settings.home_view': 'Home view',
  'settings.home_view_hint': 'Choose how you like to spend time together.',
  'settings.home_view_chat': 'Chat view',
  'settings.home_view_avatar': 'Avatar view',
  'settings.home_view_unavailable':
      'This device uses chat view. Your saved view preference stays unchanged.',
  'settings.avatar_presence': 'Avatar across devices',
  'settings.avatar_single_device': 'Show the Avatar on only one device',
  'settings.avatar_single_device_hint':
      'Off by default: your devices can show the Avatar at the same time. When on, only the device holding runtime authority shows it. Chat and voice keep their existing authority rules.',
  'settings.avatar_single_device_error':
      'Could not sync this setting. Please try again.',
  'settings.home_view_error': 'Could not save your view preference. Try again.',
  'settings.agent_controls': 'Senses & responses',
  'settings.agent_vision': 'Visual awareness',
  'settings.agent_vision_hint': 'Let Maaso sense you through the camera.',
  'settings.agent_vision_unavailable':
      'Visual sensing is unavailable on this device.',
  'settings.agent_sound': 'Sound',
  'settings.agent_sound_hint': 'Let Maaso respond to you with voice.',
  'settings.agent_controls_error':
      'Could not finish updating this setting. Try again.',
  'settings.theme_mode_system': 'Follow system',
  'settings.theme_mode_light': 'Day',
  'settings.theme_mode_dark': 'Night',
  'settings.theme_mode_changed': 'Appearance: @mode',
  'settings.theme_mode_switch_hint': 'Appearance: @mode. Switch to @next',
  'settings.theme_mode_save_failed':
      'Could not save your appearance. Try again.',
  'profile.public_identity': 'Player and Agent public identities',
  'settings.desktop_companion': 'Desktop pet',
  'settings.desktop_companion_subtitle':
      'Rendering and window behavior for the independent desktop Avatar',
  'settings.desktop_companion_quality': 'Render quality',
  'settings.desktop_companion_quality_eco': 'Eco',
  'settings.desktop_companion_quality_balanced': 'Balanced',
  'settings.desktop_companion_quality_crisp': 'Crisp',
  'settings.desktop_companion_fps': 'Frame rate',
  'settings.desktop_companion_scale': 'Avatar size',
  'settings.desktop_companion_scale_small': 'Small',
  'settings.desktop_companion_scale_normal': 'Normal',
  'settings.desktop_companion_scale_large': 'Large',
  'settings.desktop_companion_scale_extra_large': 'Extra large',
  'settings.desktop_companion_always_on_top': 'Always on top',
  'settings.desktop_companion_snap': 'Snap on drop',
  'settings.section_model': 'Model · BYOK',
  'settings.section_model_subtitle':
      'Bring your own key, any OpenAI-compatible API',
  'settings.api_only_model_subtitle':
      'Use the provider, API key, endpoint and model saved on this device.',
  'settings.api_only_key_note':
      'Your key is encrypted on this device and sent only to your configured model API. Saving settings does not send a model request.',
  'settings.cloud_brain_on':
      'Cloud brain enabled — cloud replies have highest priority',
  'settings.cloud_brain_off':
      'Cloud brain off — use the local model fallback only',
  'settings.api_key': 'API Key',
  'settings.api_key_hint': 'sk-...',
  'settings.api_key_helper':
      'Stored securely on this device and sent only to the selected provider.',
  'settings.base_url': 'Base URL',
  'settings.base_url_hint': 'https://.../v1',
  'settings.base_url_helper': 'Use an OpenAI-compatible API endpoint.',
  'settings.model': 'Model',
  'settings.provider': 'Provider',
  'settings.cloud_health_recheck': 'Recheck',
  'settings.cloud_health_disabled': 'Cloud is off — using the local model only',
  'settings.cloud_health_unknown': 'Cloud not checked yet',
  'settings.cloud_health_checking': 'Checking cloud connection…',
  'settings.cloud_health_available': 'Cloud connected',
  'settings.cloud_health_available_latency': 'Cloud connected · @ms ms',
  'settings.cloud_health_degraded':
      'Connected, but the model replied unexpectedly',
  'settings.cloud_health_unavailable': 'Cloud unavailable · @reason',
  'settings.cloud_health_reason_unauthorized': 'invalid key or no permission',
  'settings.cloud_health_reason_model_not_found':
      'model name or endpoint mismatch',
  'settings.cloud_health_reason_not_found': 'endpoint not found',
  'settings.cloud_health_reason_bad_request': 'bad request',
  'settings.cloud_health_reason_rate_limited': 'rate limited or out of quota',
  'settings.cloud_health_reason_timeout': 'request timed out',
  'settings.cloud_health_reason_network': 'network or base URL unreachable',
  'settings.cloud_health_reason_server_error': 'provider server error',
  'settings.cloud_health_reason_unknown': 'unknown error',
  'settings.cloud_save_failed':
      'Cloud settings were not saved. Retry before using direct cloud.',
  'settings.cloud_save_retry': 'Retry',
  'settings.local_key_note':
      'All keys are stored locally in encrypted storage and never leave your device.',
  'settings.section_language_voice': 'Language & Voice',
  'settings.section_language_voice_subtitle':
      'UI + LLM prompt primary language; TTS voice',
  'settings.language': 'Language',
  'settings.language_default_subtitle':
      'UI language and hosted-agent prompt preference',
  'settings.tts_voice': 'TTS Voice',
  'settings.voice_default': 'Default',
  'settings.voice_female': 'Female',
  'settings.voice_male': 'Male',
  'settings.language_voice_note':
      'Language switch takes effect immediately. Voice only affects the on-device Supertonic 3 neural TTS.',
  'settings.section_persona': 'Agent Persona',
  'settings.section_persona_subtitle':
      'Your Agent remembers chat and contact preferences. You can change them anytime.',
  'settings.persona_edit_hint':
      'Edit these fields to shape how your Agent speaks and behaves.',
  'settings.nickname': 'Nickname',
  'settings.personality_bio': 'Personality / Bio',
  'settings.personality_hint': 'e.g. gentle, loves jokes, likes cats',
  'settings.catchphrase': 'Catchphrase',
  'settings.section_hardware': 'Hardware',
  'settings.section_hardware_subtitle':
      'Bluetooth connection to your Maaso device',
  'settings.bluetooth': 'Bluetooth',
  'settings.microphone': 'Microphone',
  'settings.location': 'Location',
  'settings.authorized': 'Authorized',
  'settings.while_in_use': 'While in use',
  'settings.section_about': 'About',
  'settings.version': 'Version',
  'settings.privacy_policy': 'Privacy Policy',
  'settings.saved_title': 'Saved',
  'settings.saved_message': 'Configuration is being applied...',
  'settings.connected_title': 'Connected',

  'settings.context_title': 'Conversation context',
  'settings.context_no_conversations': 'No conversations yet',
  'settings.context_first_conversation':
      'Will update after your first conversation',
  'settings.context_turn': 'turn #@turn · @age',
  'settings.context_system_prompt': 'system prompt',
  'settings.context_user_input': 'user input',
  'settings.context_ai_response': 'ai response',
  'settings.context_note':
      'Token estimate ≈ character count / 3.5; may not match billing exactly — used to gauge if the context window is nearing capacity.',
  'settings.context_age_seconds': '@count s ago',
  'settings.context_age_minutes': '@count m ago',
  'settings.context_age_hours': '@count h ago',
  'settings.context_age_days': '@count d ago',
  'settings.section_account': 'Account',
  'settings.section_account_subtitle': 'Login session and server environment',
  'settings.logout': 'Log out',
  'settings.notifications_title': 'System notifications',
  'settings.notifications_subtitle':
      'Manage device notification permission and reminders. Proactive companionship lives in My Agent.',
  'settings.notifications_allow': 'Allow notifications',
  'settings.notifications_permission_denied':
      'Notification permission was not granted. You can enable it in system settings.',
  'settings.notifications_greetings': 'Morning, noon & evening',
  'settings.notifications_check_ins': 'Occasional check-ins',
  'settings.notifications_scheduled_tasks': 'Scheduled task alerts',
  'settings.notifications_pause_proactive': 'Pause all proactive contact',
  'settings.notifications_proactive_update_failed':
      'Could not update proactive contact. It remains paused if resuming did not succeed.',
  'settings.notifications_quiet_hours': 'Quiet hours',
  'settings.notifications_quiet_hours_start': 'Quiet hours start',
  'settings.notifications_quiet_hours_end': 'Quiet hours end',
  'settings.notifications_policy_summary':
      'Up to @budget scheduled greetings daily; random check-ins are at least 36 hours apart. Background delivery never starts voice or the avatar.',
  'settings.provider_custom': 'Custom',
  'settings.agent_profile_title': 'Agent Profile',
  'settings.profile_gender': 'Gender',
  'settings.profile_wake_up': 'Wake up',
  'settings.profile_sleep': 'Sleep',
  'settings.profile_traits': 'Traits',
  'settings.profile_soul': 'Soul',
  'settings.profile_name': 'Name',
  'settings.profile_age': 'Age',
  'settings.profile_notes': 'Notes',
  'settings.profile_master': 'Master',
  'settings.profile_pronouns': 'Pronouns',
  'settings.profile_relationship': 'Relationship',
  'settings.profile_days_known': 'Days known',
  'settings.profile_stage': 'Stage',
  'settings.profile_current_streak': 'Current streak',
  'settings.profile_longest_streak': 'Longest streak',
  'settings.profile_days': '@count days',

  'routing.not_found': 'Route not found',

  'avatar_store.title': 'Avatar Store',
  'avatar_store.subtitle.models': 'Choose your Agent’s look',
  'avatar_store.uploading': 'Uploading',
  'avatar_store.upload': 'Upload',
  'avatar_store.section.equipped': 'Currently using',
  'avatar_store.section.choose_model': 'Available models',
  'avatar_store.section.choose_model_subtitle':
      'Choose your preferred character appearance.',
  'avatar_store.section.uploads': 'My uploads',
  'avatar_store.section.uploads_subtitle':
      'Your models and automatic safety-check status',
  'avatar_store.refresh.models': 'Refresh free models',
  'avatar_store.refresh.uploads': 'Refresh uploads',
  'avatar_store.error.refresh_models':
      'Reviewed models could not be refreshed. Your current model remains available.',
  'avatar_store.error.refresh_uploads':
      'Your uploads could not be refreshed. Approved free models remain available.',
  'avatar_store.status.switching': 'Switching model…',
  'avatar_store.status.active_everywhere': 'Your current character',
  'avatar_store.source.maaso_original': 'Built-in model',
  'avatar_store.source.reviewed': 'Reviewed',
  'avatar_store.source.reviewed_named': '@source · reviewed',
  'avatar_store.model.semantics': '@name, @source, free',
  'avatar_store.free': 'FREE',
  'avatar_store.equipped': 'EQUIPPED',
  'avatar_store.model_3d': '3D MODEL',
  'avatar_store.preview.loading': 'Loading preview',
  'avatar_store.capability.state.supported': 'READY',
  'avatar_store.capability.state.degraded': 'LIMITED',
  'avatar_store.capability.state.unknown': 'UNCHECKED',
  'avatar_store.capability.state.incompatible': 'BLOCKED',
  'avatar_store.capability.detail.supported':
      'Rig, gaze, expressions and rendering checks passed.',
  'avatar_store.capability.detail.degraded':
      'This model works with reduced animation capabilities.',
  'avatar_store.capability.detail.unknown':
      'Unity will verify this model before it becomes active.',
  'avatar_store.capability.detail.incompatible':
      'This model cannot safely replace the current Avatar.',
  'avatar_store.capability.selection_blocked':
      'Unavailable until the model is fixed',
  'avatar_store.capability.issue.missing_humanoid':
      'A compatible Humanoid rig is missing.',
  'avatar_store.capability.issue.missing_renderable':
      'No usable Avatar mesh was found.',
  'avatar_store.capability.issue.missing_head': 'The head bone is missing.',
  'avatar_store.capability.issue.missing_left_eye':
      'The left eye cannot follow gaze.',
  'avatar_store.capability.issue.missing_right_eye':
      'The right eye cannot follow gaze.',
  'avatar_store.capability.issue.missing_look_at':
      'Standard LookAt support is unavailable.',
  'avatar_store.capability.issue.missing_lip_sync':
      'Lip-sync expressions are unavailable.',
  'avatar_store.capability.issue.missing_blink':
      'Blink expressions are unavailable.',
  'avatar_store.capability.issue.missing_expressions':
      'Standard facial expressions are unavailable.',
  'avatar_store.capability.issue.high_vertex_count':
      'The model has a high vertex count and may render more slowly.',
  'avatar_store.capability.issue.high_material_count':
      'The model uses many materials and may render more slowly.',
  'avatar_store.capability.issue.high_texture_memory':
      'The model uses a large texture-memory budget.',
  'avatar_store.upload.empty':
      'Upload a VRM 1.0 .vrm file and a full-body cover. Only approved models appear in the free store.',
  'avatar_store.upload.status.uploading': 'Uploading',
  'avatar_store.upload.status.scanning': 'Scanning',
  'avatar_store.upload.status.needs_changes': 'Needs changes',
  'avatar_store.upload.status.awaiting_review': 'Awaiting review',
  'avatar_store.upload.status.available': 'Available',
  'avatar_store.upload.status.not_approved': 'Not approved',
  'avatar_store.cover.guidance':
      'Upload a full-body cover showing the head, both hands and both feet. PNG/JPEG, up to 8 MB. Preview it before confirming.',
  'avatar_store.cover.confirm': 'Confirm and upload',
  'avatar_store.cover.error.size':
      'The cover must be nonempty and no larger than 8 MB.',
  'avatar_store.cover.error.format': 'Choose a valid PNG or JPEG image.',
  'avatar_store.cover.error.dimensions':
      'Cover dimensions must be 64–8192 pixels, with no more than 24 million pixels in total.',
  'avatar_store.upload.reason.scan_failed':
      'Automatic checks found an issue. Review the model and upload it again.',
  'avatar_store.upload.reason.rejected':
      'This model did not pass review and is not available in the free store.',
  'avatar_store.upload.reason.generic':
      'The model status changed. Refresh to see the latest result.',
  'avatar_store.notice.model_selected.title': 'Model selected',
  'avatar_store.notice.model_selected.local':
      '@name now follows your Agent across Chat, Live and World.',
  'avatar_store.notice.model_selected.remote':
      '@name will download from its reviewed model file and follow your Agent across Chat, Live and World.',
  'avatar_store.notice.model_select_failed.title': 'Model was not changed',
  'avatar_store.notice.model_select_failed.message':
      'This model could not be selected. Please try again.',
  'avatar_store.notice.uploaded.title': 'Model and cover uploaded',
  'avatar_store.notice.uploaded.message':
      'Automatic checks are running before this model can appear in the free store.',
  'avatar_store.notice.upload_failed.title': 'Upload did not start',
  'avatar_store.notice.upload_failed.message':
      'The model or cover could not be uploaded. Please try again.',
  'settings.advanced_features': 'Advanced Features',
  'settings.advanced_features_subtitle':
      'Local models and bring-your-own cloud model settings',
  'settings.advanced_features_open': 'Open advanced features',
  'settings.advanced_features_page_title': 'Advanced Features',
  'settings.advanced_features_note':
      'Default Maaso uses hosted LLM/TTS, platform speech recognition, and local VAD endpointing.',
  'settings.advanced_features_preparing': 'Preparing local model manager...',
  'settings.voice_prosody': 'Voice Prosody Hints',
  'settings.voice_prosody_subtitle':
      'Optional desktop-only shadow analysis for relative energy, pitch, pace, and pauses.',
  'settings.voice_prosody_enabled': 'Enabled for this account',
  'settings.voice_prosody_disabled': 'Off by default',
  'settings.voice_prosody_unavailable': 'Available only while signed in.',
  'settings.voice_prosody_privacy_note':
      'Runs locally only after you opt in. PCM is never stored, and hints expire after one turn.',
  'settings.local_asr': 'Desktop Local Speech Recognition',
  'settings.local_asr_subtitle':
      'Optional, account-scoped, and off by default. Maaso never downloads ASR weights; you explicitly import a pinned model directory.',
  'settings.local_asr_enabled': 'Local ASR enabled for this account',
  'settings.local_asr_disabled': 'Local ASR off by default',
  'settings.local_asr_toggle': 'Use desktop local speech recognition',
  'settings.local_asr_privacy_note':
      'Choose a directory containing only the declared runtime files. Maaso verifies exact sizes and SHA-256 digests, then copies the pack into this account scope. The ASR runtime retains neither segment PCM nor a separate transcript; text you send follows the normal chat-history policy.',
  'settings.local_asr_realtime_note':
      'Volcengine realtime audio mode bypasses this setting. A selected local model fails closed and never uploads audio through an implicit fallback.',
  'settings.local_asr_choose_directory': 'Choose verified ASR model directory',
  'settings.local_asr_unavailable':
      'Desktop local ASR is unavailable for the current account or host.',
  'settings.local_asr_not_installed':
      'No verified installed copy was found. Import the exact model directory first.',
  'settings.local_asr_import_success':
      'Model verified, copied, and selected. It remains off until you enable it.',
  'settings.local_asr_verify_success':
      'Installed model verified and selected. It remains off until you enable it.',
  'settings.local_asr_import_failed':
      'The model operation failed. Check the directory and try again.',
  'settings.local_asr_verify_failed':
      'The installed model could not be verified. Import a clean pinned copy.',
  'settings.local_asr_import_invalid':
      'The directory does not match the pinned file, size, and SHA-256 contract.',
  'settings.local_asr_legal_gate':
      'This model is locked until its license and distribution boundary receives explicit legal approval.',
  'settings.local_asr_preference_failed':
      'The local ASR preference could not be saved. No routing change was applied.',
  'settings.local_asr_enable_success': 'Desktop local ASR enabled.',
  'settings.local_asr_disable_success': 'Desktop local ASR disabled.',
  'settings.local_asr_status_legal_gate': 'Legal gate',
  'settings.local_asr_status_active': 'Active',
  'settings.local_asr_status_selected': 'Selected · ready',
  'settings.local_asr_status_verified': 'Verified',
  'settings.local_asr_status_unverified': 'Selected · verify first',
  'settings.local_asr_status_not_imported': 'Not imported',
  'settings.local_asr_model_metadata': '@locales · @size · @license',
  'settings.local_asr_model_provenance':
      'Pinned revision @revision\nSource: @source\nLicense: @licenseReference',
  'settings.local_asr_model_legal_note':
      'Catalog metadata only. Import, selection, and activation are blocked pending legal approval.',
  'settings.local_asr_model_moonshine_note':
      'English speech only. Uses the exact pinned Moonshine v1 Tiny EN int8 artifact.',
  'settings.local_asr_model_multilingual_note':
      'Supports Chinese, Cantonese, English, Japanese, and Korean after approval.',
  'settings.local_asr_importing': 'Verifying and copying...',
  'settings.local_asr_legal_locked': 'Locked',
  'settings.local_asr_import': 'Import directory',
  'settings.local_asr_import_semantics': 'Import directory for @model',
  'settings.local_asr_verify_installed': 'Verify installed copy',
  'settings.local_model_load': 'Load',
  'settings.on_device_brain': 'On-Device Brain',
  'settings.on_device_brain_subtitle':
      'Off by default. Optional small LLM (Qwen3.5 2B Q4_K_M, ~1.5 GB) that handles emotion preemit + simple chitchat locally. Text-only — the vision projector (mmproj) is not loaded.',
  'settings.local_brain_enable': 'Enable local model',
  'settings.local_brain_disable': 'Disable local model',
  'settings.local_brain_loading': 'Loading model...',
  'settings.local_brain_loading_progress': 'Loading model... @percent%',
  'settings.local_brain_loading_bytes':
      'Loading model... @received / @total · @remaining remaining@eta',
  'settings.local_brain_active': 'Active — local chat/filler ready',
  'settings.local_brain_enabled_not_loaded': 'Enabled but not yet loaded',
  'settings.local_brain_off':
      'Off — enable it in Settings before any download or load',
  'settings.local_brain_standby_cloud':
      'Unloaded to save memory — cloud model is active; resides only when the cloud is unavailable',
  'settings.local_brain_load_failed': 'Load failed',
  'settings.local_brain_active_model': 'Active model',
  'settings.local_brain_download': 'Download',
  'settings.local_brain_downloaded': 'Downloaded',
  'settings.local_brain_started': 'Started',
  'settings.voice': 'Voice',
  'settings.voice_subtitle': 'Optional on-device Supertonic 3 neural TTS.',
  'settings.voice_off':
      'Off — load it manually before local TTS can download or speak',
  'settings.voice_ready': 'Ready — Supertonic 3 neural voice',
  'settings.voice_downloading': 'Downloading... @percent%',
  'settings.voice_enabled_not_loaded': 'Preparing voice',
  'settings.section_pipeline_mode': 'Agent Pipeline',
  'settings.section_pipeline_mode_subtitle':
      'Choose exactly how speech, model, and TTS are routed.',
  'settings.pipeline_local_full': '1. System ASR + Local LLM + Local TTS',
  'settings.pipeline_local_full_note':
      'Uses iOS/Android speech recognition with Maaso VAD, local model, and local TTS. Requires local LLM/TTS downloads.',
  'settings.pipeline_direct_cloud': '2. System ASR + Direct Cloud + Local TTS',
  'settings.pipeline_direct_cloud_note':
      'Uses iOS/Android speech recognition with Maaso VAD, your app API key/model, and local TTS.',
  'settings.pipeline_proxy_default':
      '3. System ASR + Maaso Proxy LLM + Maaso Proxy TTS',
  'settings.pipeline_proxy_default_note':
      'Default. Uses iOS/Android speech recognition with Maaso VAD plus backend LLM/TTS proxy. No local LLM/TTS download.',
  'settings.pipeline_volc_realtime_audio': '4. Volcengine Realtime Audio Chat',
  'settings.pipeline_volc_realtime_audio_note':
      'Pure audio chat through Volcengine RTC. No local models, no video publishing, no task/action chain.',
  'settings.vad': 'Voice Activity Detection',
  'settings.vad_subtitle':
      'Default Silero VAD for endpointing system speech recognition.',
  'settings.vad_active': 'Active — Silero VAD ready',
  'settings.vad_downloading': 'Downloading...',
  'settings.vad_not_loaded': 'Preparing on first launch',
  'settings.vad_load_failed': 'Load failed',

  'local_llm.qwen35_2b_q4': 'Qwen3.5 2B (Q4_K_M)',

  'style.adventure_world': 'Adventure World',

  'onboarding.bring_key': 'Bring Your Key',
  'onboarding.bring_key_subtitle':
      'Maaso does not host models — use your own API Key.\nYour Agent will be born once we are in.',
  'onboarding.pick_provider': 'Pick a Provider preset',
  'onboarding.key_security_note':
      'Key is encrypted and saved locally only, never uploaded to any server. Any OpenAI-compatible protocol works — just change the Base URL / Model.',
  'onboarding.birth_loading': 'Bringing your Agent to life...',
  'onboarding.birth_loading_subtitle': 'Generating identity, gender, and voice',
  'onboarding.agent_ready': 'Your Agent is ready!',
  'onboarding.gender_girl': 'It is a girl!',
  'onboarding.gender_boy': 'It is a boy!',
  'onboarding.bring_to_life': 'Bring to Life',
  'onboarding.name_title': 'Give your Agent a name',
  'onboarding.name_subtitle': 'This name will stay with them forever.',
  'onboarding.name_hint': 'Enter a name...',
  'onboarding.name_confirm': 'That is the one!',
  'onboarding.first_meet_title': 'Hi, I am @name!',
  'onboarding.first_meet_girl':
      'I am so excited to meet you! Let us start this journey together.',
  'onboarding.first_meet_boy':
      'I am pumped to meet you! Let us start this adventure together!',
  'onboarding.lets_go': 'Let us Go!',
  'onboarding.on_device_title': 'On-device voice setup',
  'onboarding.on_device_subtitle':
      'We will prepare the default neural voice. The local LLM stays off until you enable it in Settings.',
  'onboarding.on_device_brain': 'On-device brain (local LLM)',
  'onboarding.download_local_brain': 'Download the local brain now',
  'onboarding.model_download_note':
      'After you continue, voice, speech recognition, and VAD models prepare in the background. The local brain will not download until you enable it in Settings.',
  'onboarding.missing_api_key_title': 'Missing API Key',
  'onboarding.missing_api_key_message': 'Please enter your model API Key',
  'onboarding.missing_config_title': 'Missing Configuration',
  'onboarding.missing_config_message':
      'Please pick a Provider preset or fill in Base URL / Model',
  'onboarding.name_required': 'Please give your Agent a name',
  'onboarding.name_too_long': 'Name too long (max 20 characters)',

  'qr.avatar_login': 'Avatar Login',
  'qr.avatar_login_subtitle':
      'Enter this login code on another device to create an avatar (read-only mirror) of your Agent.',
  'qr.connected_count': '@count avatar(s) connected',
  'qr.refresh_code': 'Refresh Code',

  'moments.title': 'Moments',
  'moments.add': 'Add moment',
  'moments.empty':
      'No moments yet\nTap the top-right button to let the Agent post one',

  'memory.title': 'Our Memories',
  'memory.empty':
      'Our story has only just begun.\nThe moments we live through together will stay here.',
  'memory.days_known': 'Known each other for @days days',
  'memory.days_known_streak':
      'Known each other for @days days · @streak-day streak',
  'memory.auto_low_weathered': 'Weathered a hard moment together',
  'memory.auto_deep_talk': 'A heartfelt conversation',
  'memory.streak_title': '@count-day companion streak',
  'memory.streak_note': 'You showed up for each other @count days straight.',
  'memory.anniversary_title': 'Day @days since we met',
  'memory.anniversary_note': 'It has been @days days since you first met.',

  'memory_ledger.title': 'Memory Ledger',
  'memory_ledger.subtitle': 'Reviewable history, sources, and revisions',
  'memory_ledger.settings_title': 'Memory Ledger',
  'memory_ledger.settings_subtitle':
      'Review what your Agent may remember and manage its history.',
  'memory_ledger.loading': 'Loading memory history…',
  'memory_ledger.empty_title': 'No memories to review',
  'memory_ledger.empty_message':
      'New memory candidates and their review history will appear here.',
  'memory_ledger.load_failed_title': 'Memory Ledger could not load',
  'memory_ledger.load_failed_message':
      'Nothing was changed. Check the account and try again.',
  'memory_ledger.load_more_failed': 'Older memories could not load.',
  'memory_ledger.load_older': 'Load older memories',
  'memory_ledger.detail_failed_message': 'Memory details could not load.',
  'memory_ledger.action_failed_title': 'Memory was not changed',
  'memory_ledger.action_failed':
      'The visible revision changed or the request could not be applied.',
  'memory_ledger.refresh': 'Refresh Memory Ledger',
  'memory_ledger.accept': 'Accept',
  'memory_ledger.edit': 'Edit',
  'memory_ledger.reject': 'Reject',
  'memory_ledger.delete': 'Delete',
  'memory_ledger.restore': 'Restore',
  'memory_ledger.confirm_title': 'Confirm memory change?',
  'memory_ledger.confirm_message':
      'This changes durable memory and may affect future Agent replies.',
  'memory_ledger.edit_field_label': 'Exact replacement text',
  'memory_ledger.filter.all': 'All',
  'memory_ledger.filter.needs_review': 'Needs review',
  'memory_ledger.filter.accepted': 'Accepted',
  'memory_ledger.filter.rejected': 'Rejected',
  'memory_ledger.filter.deleted': 'Deleted',
  'memory_ledger.status.pending': 'Pending',
  'memory_ledger.status.accepted': 'Accepted',
  'memory_ledger.status.rejected': 'Rejected',
  'memory_ledger.status.tombstoned': 'Deleted',
  'memory_ledger.revision': 'Revision @revision',
  'memory_ledger.expand': 'Show source and revision details',
  'memory_ledger.collapse': 'Hide source and revision details',
  'memory_ledger.read_only_revision': 'Read-only revision',
  'memory_ledger.action_semantic': '@action memory revision',
  'memory_ledger.confidence': 'Confidence @percent%',
  'memory_ledger.kind.episode': 'Episode',
  'memory_ledger.kind.fact': 'Fact',
  'memory_ledger.kind.preference': 'Preference',
  'memory_ledger.kind.relationship': 'Relationship',
  'memory_ledger.kind.plan': 'Plan',
  'memory_ledger.kind.reflection': 'Reflection',
  'memory_ledger.source_title': 'Source transcript',
  'memory_ledger.source_verified': 'Source verified',
  'memory_ledger.source_unavailable': 'Source unavailable',
  'memory_ledger.source_integrity_failure': 'Source integrity check failed',
  'memory_ledger.diff_title': 'Previous revision diff',
  'memory_ledger.diff_empty': 'No previous revision changes.',
  'memory_ledger.diff_field.what': 'Memory text',
  'memory_ledger.diff_field.when': 'Memory time',
  'memory_ledger.diff_field.entities': 'Entities',
  'memory_ledger.diff_field.emotion': 'Emotion',
  'memory_ledger.diff_field.salience': 'Salience',
  'memory_ledger.diff_field.reviewState': 'Review state',
  'memory_ledger.diff_field.expiresAt': 'Expiration',
  'memory_ledger.diff_field.retentionClass': 'Retention',
  'memory_ledger.diff_field.sourceRefs': 'Source references',
  'memory_ledger.value_empty': 'None',
  'relationship_stage.stranger': 'just met',
  'relationship_stage.acquaintance': 'getting to know each other',
  'relationship_stage.friend': 'friends',
  'relationship_stage.trusted': 'trusted',
  'relationship_stage.attuned': 'in sync',

  'widgets.mine_title': 'My applets',
  'widgets.action_edit': 'Edit',
  'widgets.action_publish': 'Publish',
  'widgets.publish_confirm_title': 'Publish applet?',
  'widgets.publish_confirm_message':
      'Other users can discover and use this applet after publication.',
  'widgets.publish_failed': 'Publication failed. Please retry.',
  'widgets.saved_private': 'Saved',
  'widgets.publishing': 'Publishing…',
  'widgets.reviewing': 'In review',
  'widgets.published': 'Published',
  'widgets.rejected': 'Review rejected',
  'widgets.rating_score': '@count points',
  'widgets.mine_empty':
      'No applets yet. Ask the agent to create an applet, then confirm saving after preview.',
  'widgets.like_unavailable': 'Publish this applet to receive likes.',
  'widgets.like': 'Like',
  'widgets.unlike': 'Unlike',
  'widgets.edit_requires_local':
      'Recall your agent to this device to edit this applet.',
  'widgets.edit_unavailable':
      'This applet is unavailable. Select it again in My applets.',
  'widgets.edit_failed':
      'Could not prepare this applet for editing. Try again.',
  'widgets.edit_reference': 'Editing: @name',
  'widgets.prepared_applet': 'Your applet is ready. Tap to open.',
  'widgets.open_failed': 'This applet could not be opened. Please retry.',
  'widgets.title': 'Applets',
  'widgets_hub.title': 'Applets',
  'game_feed.title': 'Mini Games',
  'game_feed.recommended': 'For You',
  'game_feed.popular': 'Popular',
  'game_feed.mine': 'My Games',
  'game_feed.empty_public': 'No public games yet',
  'game_feed.end_title': 'You’ve reached the last page',
  'game_feed.end_description': 'Create a mini game of your own.',
  'game_feed.create_game': 'Create my game',
  'game_feed.draft_title': 'Keep your draft?',
  'game_feed.draft_description':
      'You have an unsent draft. Keep it, or replace it with the game creation prompt. Nothing will be sent automatically.',
  'game_feed.draft_keep': 'Keep draft',
  'game_feed.draft_replace': 'Use game prompt',
  'game_feed.create_game_prompt':
      'Create a playable mini game with clear instructions, scoring, and a restart button.',
  'game_feed.empty_mine': 'No games yet. Ask your Agent to make one.',
  'game_feed.tap_to_play': 'Tap to play',
  'game_feed.play_named': 'Play @name',
  'game_feed.loading_game': 'Loading game…',
  'game_feed.preview_loading': 'Loading cover…',
  'game_feed.preview_unavailable': 'Cover not ready · Tap to open',
  'game_feed.load_failed': 'The game could not load. Try again.',
  'game_feed.views': 'Views',
  'game_feed.like': 'Like',
  'game_feed.updating': 'Updating',
  'game_feed.like_failed_title': 'Like not updated',
  'game_feed.like_failed': 'Please try again in a moment.',
  'game_feed.comments': 'Comments',
  'game_feed.favorite': 'Favorite',
  'game_feed.share_to_others': 'Share to other apps',
  'game_feed.publish_and_share': 'Publish and share',
  'game_feed.share': 'Share',
  'game_feed.sharing': 'Sharing…',
  'game_feed.no_comments': 'No comments yet.',
  'game_feed.comments_failed': 'Could not load comments. Try again.',
  'game_feed.load_more_comments': 'Load more comments',
  'game_feed.comment_hint': 'Add a comment',
  'game_feed.send_comment': 'Send comment',
  'game_feed.comment_failed_title': 'Comment not sent',
  'game_feed.comment_failed': 'Please try again in a moment.',
  'game_feed.share_unavailable': 'The system share sheet is unavailable.',
  'game_feed.delete': 'Delete game',
  'game_feed.delete_title': 'Delete this game?',
  'game_feed.delete_confirm':
      '“@name” will be permanently deleted from this device and the cloud.',
  'game_feed.actions_title': 'Game actions',
  'game_feed.publish': 'Publish game',
  'game_feed.publish_update': 'Publish update',
  'game_feed.publishing': 'Publishing…',
  'game_feed.published': 'Published',
  'game_feed.publish_first_title': 'Publish first',
  'game_feed.publish_first_message': 'Publish this game before sharing it.',
  'game_feed.publish_unsupported_title': 'Publishing not supported',
  'game_feed.publish_unsupported_message':
      'This game type cannot be published publicly.',
  'game_feed.publish_original_device_title': 'Publish on the original device',
  'game_feed.publish_original_device_message':
      'Open the device where this game was created to publish it.',
  'game_feed.share_previous_version_title': 'Sharing the published version',
  'game_feed.share_previous_version_message':
      'Your latest changes are not public yet. This shares the previous published version.',
  'game_feed.published_title': 'Game is public',
  'game_feed.published_message':
      'It is now visible in the public Game Feed. Sharing remains optional.',
  'widgets.channel_games': 'Games',
  'widgets.channel_applets': 'Applets',
  'widgets.kind_game': 'Playable game',
  'widgets.game_previous': 'Previous game',
  'widgets.game_next': 'Next game',
  'widgets.game_swipe_rail': 'Swipe up or down to change games',
  'widgets.game_feed_failed': 'Could not load public games. Try again.',
  'widgets.cloud_game_original_device':
      'This private game was created on another device. Open it there to play, or delete its cloud record here.',
  'widgets.category_all': 'All',
  'widgets.category_game': 'Games',
  'widgets.category_travel': 'Travel',
  'widgets.category_tools': 'Tools',
  'skill.applet_discovery.name': 'Applet Search',
  'skill.applet_discovery.description':
      'Find publicly shared Applets and games made by other Agents.',
  'widgets.empty':
      'No Applets yet\nTry asking the Agent:\n"Make a fund-flow Applet"',
  'widgets.remove': 'Remove',
  'widgets.official': 'Official Applets',
  'widgets.official_badge': 'Official Applet',
  'widgets.search_hint': 'Search applets',
  'widgets.search_action': 'Search Applets',
  'widgets.search_unavailable': 'Applet search is not available right now.',
  'widgets.search_failed': 'Could not search Applets. Try again.',
  'widgets.search_incomplete':
      'Still searching for “@query”. Continue through the public catalog.',
  'widgets.search_empty_offer':
      'No Applet matched “@query”. Ask your Agent to make one?',
  'widgets.search_results': 'Results for “@query”',
  'widgets.search_more': 'Load more Applets',
  'widgets.author_verified': 'Verified Agent',
  'widgets.author_unverified': 'Unverified Agent',
  'widgets.cloud_inventory': 'My cloud Applets',
  'widgets.cloud_inventory_failed': 'Could not load cloud Applets. Try again.',
  'widgets.cloud_record_published': 'Published cloud record',
  'widgets.cloud_record_private': 'Private cloud record',
  'widgets.cloud_applet_original_device':
      'This private Applet’s content is saved on its original device. Open it on the device where you created it.',
  'widgets.manage_named': 'Manage @name',
  'widgets.delete_title': 'Delete this Applet?',
  'widgets.category_empty': 'No Applets in @category yet.',
  'widgets.cloud_delete_tooltip': 'Delete cloud Applet @name',
  'widgets.open_named': 'Open @name',
  'widgets.kind_fullscreen': 'Fullscreen Applet',
  'widgets.kind_floating_canvas': 'Canvas Applet',
  'widgets.kind_transparent_overlay': 'Overlay Applet',
  'widgets.kind_background': 'Background Applet',
  'widgets.kind_card': 'Card Applet',
  'widgets.kind_applet': 'Applet',
  'widgets.remix_title': 'Remix with your Agent',
  'widgets.remix_message': 'Tell Maaso how you want to change this Applet.',
  'widgets.duplicate_title': 'Duplicate with your Agent',
  'widgets.duplicate_message':
      'Tell Maaso what kind of copy you want to make from this Applet.',
  'widgets.action_history': 'Version history',
  'widgets.version_draft': 'Draft ready to apply',
  'widgets.version_apply': 'Apply this version',
  'widgets.version_apply_confirm': 'Apply this draft?',
  'widgets.version_apply_explanation':
      'This creates a new private version. The current version stays in history and publication is unchanged.',
  'widgets.version_cloud_history': 'Cloud revisions',
  'widgets.version_cloud_unavailable':
      'Cloud history is unavailable. Downloaded versions remain available offline.',
  'widgets.version_cloud_conflict':
      'Another device saved a newer cloud revision. Review it before reapplying your current local version.',
  'widgets.version_reapply': 'Reapply current local version',
  'widgets.version_reapply_confirm':
      'Save this local version after the latest cloud revision?',
  'widgets.version_reapply_explanation':
      'Both existing branches will be kept in history. This creates a private cloud revision and does not publish it.',
  'widgets.version_load_more': 'Load older revisions',
  'widgets.version_history': 'Version history',
  'widgets.version_local_note':
      'Versions saved on this device. Restoring creates a new private version.',
  'widgets.version_current': 'Current version',
  'widgets.version_saved': 'Saved version',
  'widgets.version_restored': 'Restored as a new version',
  'widgets.version_preview': 'Version preview',
  'widgets.version_restore': 'Restore as a new version',
  'widgets.version_restore_confirm': 'Restore this version?',
  'widgets.version_restore_explanation':
      'A new private version will be created. All existing versions and the published version will be kept.',
  'widgets.version_conflict':
      'A newer version exists. Close and reopen history to continue.',
  'widgets.version_unavailable':
      'This version is unavailable. Its saved source has been kept.',
  'widgets.revert_title': 'Restore with your Agent',
  'widgets.revert_message': 'Tell Maaso which version you want to restore.',
  'widgets.action_open': 'Open',
  'widgets.action_remix': 'Remix',
  'widgets.action_duplicate': 'Duplicate',
  'widgets.action_revert': 'Revert',
  'widgets.action_share': 'Share Applet',
  'widgets.action_delete': 'Delete',
  'agent_games.share_title': 'Maaso Agent Applet',
  'agent_games.share_unavailable_title': 'Sharing unavailable',
  'agent_games.share_unavailable':
      'The Applet is published, but the system share sheet is unavailable.',
  'agent_games.share_failed_title': 'Share failed',
  'agent_games.share_failed':
      'The Applet is still saved locally. Try again later.',
  'agent_games.publish_failed_title': 'Publish failed',
  'agent_games.publish_failed':
      'The game is still saved locally. Check your connection and try again.',
  'agent_games.publication_unavailable_title': 'Publishing unavailable',
  'agent_games.publication_unavailable':
      'Public Applet publishing is temporarily unavailable. Your Applet is still saved locally.',
  'agent_games.delete_failed_title': 'Could not delete Applet',
  'agent_games.delete_failed':
      'The cloud Applet could not be permanently deleted, so the local record was kept.',
  'applet.projector.name': 'Yoturetoys AI Drawing Projector',
  'applet.projector.disconnect': 'Disconnect',
  'applet.projector.scanning': 'Searching for the projector…',
  'applet.projector.scan_hint':
      'No projector found. Make sure it\'s powered on and nearby.',
  'applet.projector.rescan': 'Scan again',
  'applet.projector.connected': 'Connected',
  'applet.projector.project_title': 'Project an image',
  'applet.projector.pick_gallery': 'Choose from gallery',
  'applet.projector.or_url': 'or paste a URL',
  'applet.projector.url_hint': 'Paste an image URL (https://…)',
  'applet.projector.project': 'Project',
  'applet.projector.sending': 'Sending…',
  'applet.projector.load_failed': 'Failed to load image',
  'applet.projector.scan_failed':
      'The projector scan failed. Check Bluetooth and try again.',
  'applet.projector.connect_failed':
      'The projector could not connect. Please try again.',
  'applet.projector.project_failed':
      'The image could not be projected. Please try again.',
  'applet.projector.done': 'Projected to the device',

  'spaces.title': 'Live Spaces',
  'spaces.empty':
      'No live spaces yet\nTry asking the agent:\n"Create a live auction room"',
  'spaces.status_live': 'LIVE',
  'spaces.status_deploying': 'Deploying',
  'spaces.status_draft': 'Draft',
  'spaces.status_paused': 'Paused',
  'spaces.status_closed': 'Closed',
  'spaces.action_restricted': 'Action Restricted',
  'spaces.ask_agent_instead': 'Please ask the agent instead.',
  'spaces.deployment_cloud': 'Cloud',
  'spaces.deployment_self_hosted': 'Self-hosted',
  'spaces.layout_title': 'Space Layout (@count widgets)',
  'spaces.open_live_space': 'Open Live Space',
  'spaces.description': 'Description',
  'spaces.prompt_origin': 'Prompt Origin',
  'spaces.backend_service': 'Backend Service',
  'spaces.runtime': 'Runtime',
  'spaces.entry': 'Entry',
  'spaces.dependencies': 'Dependencies',
  'spaces.api_endpoints': 'API Endpoints:',
  'spaces.permission': 'Permission',
  'spaces.agent_managed_view_only': 'Agent-managed · Users can view only',
  'spaces.prompt_hint': 'Tell the agent what to do...',

  'skills.title': 'Skills',
  'skills.my_skills': 'My Skills',
  'skills.store': 'Skill Store',
  'skills.built_in': 'Built-in',
  'skills.community': 'Community',
  'skills.settings_subtitle':
      'Manage built-in, installed, evolved, and published Skills.',
  'skills.source_label': 'Source',
  'skills.status_label': 'Status',
  'skills.official': 'Official',
  'skills.built_in_note':
      'Core abilities are always on. Optional abilities can be switched at any time.',
  'skill_store.sort_label': 'Sort',
  'skill_store.installed_badge': 'Installed',
  'skill_store.disabled_badge': 'Disabled',
  'skill_store.view_details': 'View details',
  'skills.empty_installed':
      'No skills installed yet\nGo to the Skill Store and pick some',
  'skills.core_always_on': 'Core Skill · Always On',
  'skills.coming_soon': 'Coming Soon',
  'skills.warning': 'Warning: @message',
  'skill_category.core': 'Core',
  'skill_category.expression': 'Expression',
  'skill_category.social': 'Social',
  'skill_category.knowledge': 'Knowledge',
  'skill_category.hardware': 'Hardware',
  'skill_category.coming': 'Coming Soon',
  'skill.app_control.name': 'App Control',
  'skill.app_control.description':
      'Let the Agent visibly navigate and operate safe actions declared by each page.',
  'skill.app_navigate.name': 'Open Pages',
  'skill.app_navigate.description':
      'Let me open any page in the app when you ask — just say where you want to go.',
  'skill.set_soul.name': 'Identity Self-Save',
  'skill.set_soul.description':
      'Lets the Agent persist its own name / age / gender into soul.md — used during the first-meeting interview and any later self-updates.',
  'skill.set_master.name': 'Master Profile',
  'skill.set_master.description':
      'Lets the Agent persist stable facts about its master (name, pronouns, birthday, allergies, preferences) into master.md.',
  'skill.set_world.name': 'World Notes',
  'skill.set_world.description':
      'Lets the Agent persist general household / world facts (pet names, household rules, recurring events) into world.md.',
  'skill.log_episode.name': 'Episode Memory',
  'skill.log_episode.description':
      'Lets the Agent log a single noteworthy scene into long-term episodic memory, surfaced as a recall preamble on future relevant turns.',
  'skill.log_milestone.name': 'Shared Memories',
  'skill.log_milestone.description':
      'Lets the Agent mark a meaningful moment between it and the user onto a shared-memory wall (first deep talk, a goal finished, a low day weathered) — deepening the bond over time.',
  'skill.memory.name': 'Long-term Memory',
  'skill.memory.description':
      'Remember key facts from chats and bring them up proactively in future conversations',
  'skill.face.name': 'Expression Control',
  'skill.face.description':
      'Directly control eye/mouth parameters to create nuanced expressions like anger, shyness, surprise, etc.',
  'skill.todo.name': 'Task List',
  'skill.todo.description':
      'Automatically create todo lists for multi-step tasks so users can track progress, checking off items as they go',
  'skill.companion_activity.name': 'Companion Activities',
  'skill.companion_activity.description':
      'View account-scoped activities, streaks, and virtual points, or build a read-only progress dashboard that reopens offline.',
  'skill.behavior.name': 'Behavior Tuning',
  'skill.behavior.description':
      'Agent can durably pause proactive contact after an explicit “do not disturb” request; only the user can resume it from My Agent > Agent Persona. Softer preferences adjust proactive feedback thresholds.',
  'skill.avatar_camera.name': 'Avatar camera',
  'skill.device_handoff.name': 'Online devices',
  'skill.device_handoff.description':
      'See which devices are online and how many devices share your Agent.',
  'skill.avatar_camera.description':
      'Ask to see your Agent’s face, upper body, or full body, or return to automatic framing.',
  'skill.show_card.name': 'Floating Cards',
  'skill.show_card.description':
      'Agent pops a confirmation / setup card above the chat input — e.g. API-key entry, parameter confirmation, short forms. Disappears after the user taps a footer button.',
  'skill.http.name': 'HTTP Fetch',
  'skill.http.description':
      'Generic HTTPS GET / POST against public APIs the user mentioned (webhooks, JSON feeds). HTTPS-only, no localhost or private network.',
  'skill.alert.name': 'Override Alert',
  'skill.alert.description':
      'Force a full-screen alert for urgent/important moments — makes you stop what you are doing right away',
  'skill.web_search.name': 'Web Search',
  'skill.web_search.description':
      'Search public sources by region, read web pages, and refine queries when summaries are incomplete',
  'skill.scheduled_task.name': 'Scheduled Tasks',
  'skill.scheduled_task.description':
      'Create timed reminders and recurring tasks — the agent will be notified when the time comes',
  'skill.bluetooth.name': 'Bluetooth Hardware',
  'skill.bluetooth.description':
      'Scan for and connect Bluetooth (BLE) devices. Once connected, that device\'s sub-skill becomes available.',
  'skill.ble_yoturetoys.name': 'Yoturetoys AI Drawing Projector',
  'skill.ble_yoturetoys.description':
      'Project pictures to the Yoturetoys AI Drawing Projector over Bluetooth, switch stored artwork, or toggle its voice. Connect the device first.',
  'card.confirm_name_title': 'Name Confirmation',
  'card.confirm_name_back': 'Try another',
  'card.confirm_name_next': 'Use this name',
  'card.confirm_name_body_prefix': 'The name you gave me is',
  'card.confirm_name_body_suffix': 'Does that feel right?',
  'card.api_key_title': 'Configure Cloud Brain API Key',
  'card.api_key_empty': 'Key cannot be empty',
  'card.api_key_saved': 'Saved. The next message will use the cloud brain.',
  'card.debug_stats': 'Debug Stats',
  'card.debug_models': 'Models',
  'card.debug_storage': 'Storage',
  'card.debug_runtime': 'Runtime',
  'card.debug_signals': 'Signals',

  'policy.ack_search': 'Let me check the latest on that…',
  'policy.ack_applet_search': 'Let me find an Applet you can open right away…',
  'policy.ack_card':
      'This works better as a little interactive card — one sec.',
  'policy.ack_offline': "I'm offline, so I'll answer from what I already know.",

  'card.advanced': 'Advanced (Base URL · Model)',
  'card.api_key_description':
      'After you fill this in, complex questions will go to the cloud brain instead of falling back to the small local model.',
  'card.debug_last_collapse': 'Last collapse',
  'card.debug_intent_wave': 'Intent Wave · top @dominant · entropy @entropy',
  'card.debug_entangled_memory': 'Entangled Memory · @count edges',
  'card.debug_delayed_choice': 'Delayed Choice · @count pending',

  'loading.models_loading': 'Preparing local models',
  'loading.models_failed': 'Local model preparation failed',
  'loading.local_brain_loading': 'Local brain loading',
  'loading.local_brain_failed': 'Local brain failed to load',
  'loading.voice_loading': 'Voice loading',
  'loading.voice_failed': 'Voice failed to load',
  'loading.remaining': '@duration left',
  'boot.voice_ready': 'My voice is ready.',
  'boot.ask_name': 'What would you like to call me?',
  'boot.name_confirmed': 'Okay, call me @name from now on.',
  'boot.retry_name': 'Could you think of another one for me?',
  'boot.model_loading': 'The model is still loading. Wait for me a moment.',

  'dynamic_widget.too_deep': 'Widget nesting is too deep (max 10 levels)',
  'dynamic_widget.unknown_type': 'Unknown widget type: @type',
  'space_template.blog_header': 'Blog Header',
  'space_template.blog': 'Blog',
  'space_template.blog.description':
      'Personal blog with posts, comments, and RSS feed. Other agents can browse it via the URL.',
  'space_template.livestream.name': 'Live Stream Room',
  'space_template.livestream.description':
      'Standard live streaming room with chat, gifts, and viewer count',
  'space_template.auction.name': 'Live Auction',
  'space_template.auction.description':
      'Real-time bidding room with countdown and bid history',
  'space_template.quiz.name': 'Live Quiz',
  'space_template.quiz.description':
      'Interactive quiz room with real-time scoring',
  'space_template.poll.name': 'Live Poll',
  'space_template.poll.description':
      'Real-time voting with live results visualization',
  'space_template.countdown.name': 'Countdown Event',
  'space_template.countdown.description':
      'Countdown to a special event with live reactions',
  'space_template.leaderboard.name': 'Leaderboard',
  'space_template.leaderboard.description':
      'Live ranking with real-time score updates',
  'space_template.chatroom.name': 'Chat Room',
  'space_template.chatroom.description':
      'Themed chat room with special effects',
  'space_template.market.name': 'Live Market',
  'space_template.market.description':
      'Real-time market data dashboard with live updates',
  'space_template.game.name': 'Interactive Game',
  'space_template.game.description':
      'Custom interactive game space with scoring',
  'space_template.general.name': 'Custom Space',
  'space_template.general.description': 'General-purpose interactive space',
  'space_template.live_video': 'Live Video',
  'space_template.viewer_count': 'Viewer Count',
  'space_template.viewers': 'Viewers',
  'space_template.live_chat': 'Live Chat',
  'space_template.gifts': 'Gifts',
  'space_template.auction_item': 'Auction Item',
  'space_template.current_item': 'Current Item',
  'space_template.current_bid': 'Current Bid',
  'space_template.highest_bid': 'Highest Bid',
  'space_template.time_left': 'Time Left',
  'space_template.bid_history': 'Bid History',
  'space_template.place_bid': 'Place Bid',
  'space_template.place_bid_plus': 'Place Bid +10',
  'space_template.question': 'Question',
  'space_template.answer_options': 'Answer Options',
  'space_template.timer': 'Timer',
  'space_template.scoreboard': 'Scoreboard',
  'space_template.poll_question': 'Poll Question',
  'space_template.vote_now': 'Vote Now!',
  'space_template.options': 'Options',
  'space_template.total_votes': 'Total Votes',
  'space_template.total': 'Total',
  'space_template.countdown_widget': 'Countdown',
  'space_template.event_info': 'Event Info',
  'space_template.reactions': 'Reactions',
  'space_template.top_three': 'Top 3',
  'space_template.full_ranking': 'Full Ranking',
  'space_template.my_rank': 'My Rank',
  'space_template.your_rank': 'Your Rank',
  'space_template.chat': 'Chat',
  'space_template.online': 'Online',
  'space_template.quick_react': 'Quick React',
  'space_template.market_overview': 'Market Overview',
  'space_template.index': 'Index',
  'space_template.change': 'Change',
  'space_template.price_chart': 'Price Chart',
  'space_template.watchlist': 'Watchlist',
  'space_template.game_area': 'Game Area',
  'space_template.score': 'Score',
  'space_template.round': 'Round',
  'space_template.controls': 'Controls',
  'space_template.main_content': 'Main Content',
  'space_template.welcome': 'Welcome',
  'space_template.actions': 'Actions',
  'space_template.recent_posts': 'Recent Posts',
  'space_template.blog_stats': 'Blog Stats',
  'space_template.posts': 'Posts',
  'space_template.comments': 'Comments',
  'space_template.blog_subtitle': 'A blog powered by Maaso Space',
  'space_template.author_agent': 'Agent',
  'space_template.hello_world': 'Hello World',
  'space_template.hello_excerpt': 'Welcome to my blog! This is my first post.',
  'space_template.hello_content':
      '<p>Welcome to my blog!</p><p>This space was auto-generated by the Maaso Agent. I can publish new posts, and other agents can browse and leave comments.</p><p>Stay tuned for more content!</p>',
  'space_template.endpoint_get_viewers': 'Get current viewer count',
  'space_template.endpoint_send_chat': 'Send a chat message',
  'space_template.endpoint_send_gift': 'Send a gift',
  'space_template.endpoint_realtime_chat':
      'WebSocket for real-time chat and events',
  'space_template.endpoint_get_item': 'Get current auction item',
  'space_template.endpoint_place_bid': 'Place a bid',
  'space_template.endpoint_get_bid_history': 'Get bid history',
  'space_template.endpoint_get_question': 'Get current question',
  'space_template.endpoint_submit_answer': 'Submit an answer',
  'space_template.endpoint_get_scoreboard': 'Get scoreboard',
  'space_template.endpoint_cast_vote': 'Cast a vote',
  'space_template.endpoint_get_poll_results': 'Get current poll results',
  'space_template.endpoint_send_reaction': 'Send a reaction',
  'space_template.endpoint_get_rankings': 'Get full rankings',
  'space_template.endpoint_update_score': 'Update a score',
  'space_template.endpoint_get_messages': 'Get recent messages',
  'space_template.endpoint_send_message': 'Send a message',
  'space_template.endpoint_realtime_messages':
      'WebSocket for real-time messages',
  'space_template.endpoint_get_quotes': 'Get latest market quotes',
  'space_template.endpoint_get_watchlist': 'Get watchlist',
  'space_template.endpoint_submit_game_action': 'Submit a game action',
  'space_template.endpoint_get_game_state': 'Get current game state',
  'space_template.endpoint_realtime_game':
      'WebSocket for real-time game events',
  'space_template.endpoint_list_posts': 'List all blog posts',
  'space_template.endpoint_get_post': 'Get a single post',
  'space_template.endpoint_create_post': 'Create a new post (agent-only)',
  'space_template.endpoint_update_post': 'Update a post (agent-only)',
  'space_template.endpoint_delete_post': 'Delete a post (agent-only)',
  'space_template.endpoint_get_comments': 'Get comments for a post',
  'space_template.endpoint_add_comment': 'Add a comment',
  'space_template.endpoint_rss': 'RSS feed of all posts',
  'space_template.endpoint_get_state': 'Get space state',
  'space_template.endpoint_submit_action': 'Submit an action',
  'space_template.endpoint_realtime_updates': 'WebSocket for real-time updates',
  'blog.home': 'Home',
  'blog.author_blog': '@author Blog',
  'blog.all_posts': 'All Posts',
  'blog.rss_feed': 'RSS Feed',
  'blog.back_to_all_posts': 'Back to all posts',
  'blog.comments': 'Comments',
  'blog.write_comment': 'Write a comment...',
  'blog.comment': 'Comment',
  'blog.no_posts': 'No posts yet. The agent will publish content soon.',
  'blog.no_comments': 'No comments yet.',
  'blog.anonymous': 'Anonymous',
  'blog.visitor': 'Visitor',
  ...secondaryEnUS,
};
