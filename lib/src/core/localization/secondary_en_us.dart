const Map<String, String> secondaryEnUS = {
  'game_companion.controls': 'Play together',
  'game_companion.description':
      'A friend to laugh with while you play. Ask whenever you want a hand.',
  'game_companion.enabled': 'Game companion',
  'game_companion.microphone': 'Voice chat',
  'game_companion.microphone_hint':
      'Use your microphone to chat while playing.',
  'game_companion.sound': 'Spoken replies',
  'game_companion.frequency': 'How much to chat',
  'game_companion.frequency.quiet': 'Quiet company',
  'game_companion.frequency.balanced': 'Just enough',
  'game_companion.frequency.chatty': 'Chat more',
  'game_companion.hints': 'Game hints',
  'game_companion.hints.onRequest': 'Only when I ask',
  'game_companion.hints.askFirst': 'Ask me first',
  'game_companion.hints.smallHints': 'Small hints welcome',
  'game_companion.vision': 'See my game',
  'game_companion.vision_hint':
      'A membership benefit with no usage-count limit. Sends small screenshots of the visible game for AI understanding and stops when you leave.',
  'game_companion.vision_unsupported':
      'Game screenshots are unavailable on this player. Rules and visible game text can still be used.',
  'game_companion.vision_status.unsupported':
      'This player does not support screenshots.',
  'game_companion.vision_status.disabled':
      'Game image understanding is not available yet.',
  'game_companion.vision_status.membershipRequired':
      'An active membership is required for game image understanding. After joining or renewing, turn this option off and on to check again. You can still chat.',
  'game_companion.vision_status.premiumRequired':
      'Game image understanding requires a premium membership for your account. After upgrading, turn this option off and on to check again. You can still chat.',
  'game_companion.vision_status.busy':
      'Image understanding is busy. It will retry shortly.',
  'game_companion.vision_status.unavailable':
      'Cannot understand the game image right now. You can still chat.',

  'settings.location_hint':
      'Use your current city for weather and nearby information. You can also provide a city in chat.',
  'settings.location_not_authorized': 'Not authorized',
  'settings.location_denied':
      'Location permission was declined. You can allow it or provide a city in chat.',
  'settings.location_denied_forever':
      'Location permission is blocked. Enable it in system settings or provide a city in chat.',
  'settings.location_system_disabled': 'System location is off',
  'settings.location_disabled':
      'Location is off in Maaso. You can provide a city in chat.',
  'settings.location_unavailable':
      'Location is unavailable on this device. You can provide a city in chat.',
  'settings.location_loading': 'Getting your current city…',
  'settings.location_checking': 'Checking location permission…',
  'settings.location_city_unavailable':
      'Current city could not be determined. You can retry or provide a city in chat.',
  'settings.location_current_city': 'Current city: @city',
  'settings.location_allowed': 'Allowed while using Maaso',
  'settings.location_allow': 'Use current location',
  'settings.location_refresh': 'Refresh city',
  'settings.location_open_settings': 'Open system settings',
  'settings.location_save_failed':
      'Location preference could not be saved. Please try again.',
  'settings.location_action_failed':
      'Location could not be updated. You can retry or provide a city in chat.',
  'settings.location_settings_failed':
      'System settings could not be opened. Open them on this device to manage Maaso location permission.',

  'skills.group.creation.name': 'Creation',
  'skills.group.creation.description':
      'Create games, applets and content drafts from your ideas.',
  'skills.group.web_search.name': 'Web search',
  'skills.group.web_search.description':
      'Find current information and images online.',
  'skills.group.applet_discovery.name': 'Find games and applets',
  'skills.group.applet_discovery.description': 'Find and open existing works.',
  'skills.group.app_operations.name': 'App operations',
  'skills.group.app_operations.description':
      'Open pages and use their declared controls.',
  'skills.group.memory.name': 'Memory management',
  'skills.group.memory.description':
      'Manage personal facts, world notes and shared memories with review.',
  'skills.group.persona.name': 'Agent personality',
  'skills.group.persona.description':
      'Manage personality, conversation preferences and proactive companionship.',
  'skills.group.tasks.name': 'Tasks and reminders',
  'skills.group.tasks.description':
      'Manage checklists, timed reminders and important notices.',
  'skills.group.projection.name': 'Bluetooth projector',
  'skills.group.projection.description':
      'Connect a supported projector and send pictures or voice.',
  'skills.group.companion_activity.name': 'Companion activities',
  'skills.group.companion_activity.description':
      'View available activity history and completion records.',
  'skills.group.configure': 'Manage',
  'skills.group.partially_enabled': 'Partly enabled',
  'skills.group.internal_note':
      'Character presentation, setup cards and device information are integrated capabilities and do not need installation.',
  'skills.usage_loading': 'Reading local usage…',
  'skills.usage_unavailable': 'Local usage is temporarily unavailable',
  'skills.usage_count': '@count calls',
  'skills.usage_no_record': 'No calls recorded since this version',
  'skills.usage_note':
      'Actual calls are recorded on this device from this version onward. No records does not mean a Skill has no value.',
  'skills.prompt_usage_count': '@count prompt applications',
  'skills.prompt_usage_no_record': 'No local prompt applications recorded',
  'skills.prompt_usage_note':
      'Counts when this Skill’s instructions enter an actual model request, once per conversation turn. This does not mean a task was completed.',
  'skill.freeform_surface.name': 'Games and applets',
  'skill.freeform_surface.description':
      'Create, edit and reopen interactive games and applets from your ideas.',
  'privacy.status_unavailable': 'Privacy status is unavailable.',
  'account_standby.request_failed':
      'The request did not complete. Please retry.',
  'account_standby.sign_out': 'Sign out',
  'action_approval.target': 'Target',
  'action_approval.consequence': 'Consequence',
  'action_approval.exact_content': 'Exact content',
  'action_approval.reject': 'Reject',
  'action_approval.allow_once': 'Allow once',
  'skill.project_control.name': 'Applet control',
  'skill.project_control.description':
      'Perform declared local applet actions after you allow control.',
  'project_control.allow': 'Allow Agent control',
  'project_control.take_over': 'Take over',
  'project_control.manual': 'You are in control',
  'project_control.remaining': 'Agent access · @count actions left',
  'project_control.permission':
      'Allow the Agent to view and change this applet for this session, up to 3 minutes and 16 actions. Touch the page or choose Take over to regain control. Unconfirmed actions are never automatically repeated.',
  'project_control.purpose': 'What would you like help with? (optional)',
  'project_control.failed':
      'Agent control is unavailable. Use the applet manually or update its version.',
  'project_build.saved.history': 'Version history',
  'project_build.saved.edit': 'Continue editing',
  'project_build.saved.edit_target': 'Editing: @name',
  'project_build.saved.edit_clear': 'Stop editing this project',
  'project_build.saved.edit_unavailable':
      'This project cannot be edited right now. Your existing content is kept.',
  'project_build.saved.edit_head_changed':
      'This project has changed. Refresh and select it again.',
  'project_build.saved.current': 'Current version',
  'project_build.saved.saved_at': 'Saved on @date',
  'project_build.saved.view': 'View this version',
  'project_build.saved.restore': 'Make current',
  'project_build.saved.restore_title': 'Restore this version?',
  'project_build.saved.restore_message':
      'Make the version of “@name” saved on @date current. Existing versions and their saved data will remain available.',
  'project_build.saved.delete': 'Delete project',
  'project_build.saved.delete_title': 'Delete this project?',
  'project_build.saved.delete_message':
      '“@name”, all its versions, and its build records will be removed. This cannot be undone.',
  'project_build.saved.unavailable':
      'Project management is unavailable. You can still open saved versions offline.',
  'project_build.saved.load_failed':
      'Version history could not be loaded. Please retry.',
  'project_build.saved.open_failed':
      'This version could not be opened. Please retry.',
  'project_build.saved.request_pending':
      'The result is not confirmed yet. Refresh to check it.',
  'project_build.node.status.queued': 'Queued',
  'project_build.node.status.running': 'Running',
  'project_build.node.status.succeeded': 'Completed',
  'project_build.node.status.failed': 'Failed',
  'project_build.node.status.cancelled': 'Cancelled',
  'project_build.node.incomplete_terminal':
      'The task ended before this step continued',
  'project_build.node.dependencies': 'Depends on: @names',
  'project_play.catalog': 'Companion games',
  'project_play.catalog_description':
      'Choose a game to compete, cooperate, or let your Agent watch.',
  'project_play.catalog_unavailable':
      'Unable to open this game. Return to your signed-in Agent and try again.',
  'project_play.builtin_gomoku': 'Gomoku together',
  'project_play.builtin_gomoku_description':
      'Take turns placing stones. Connect five to win.',
  'project_play.builtin_cooperative_switches': 'Cooperative switches',
  'project_play.builtin_cooperative_switches_description':
      'Control two switches each and solve the puzzle together.',
  'project_play.builtin_private_cards': 'Hidden-card duel',
  'project_play.builtin_private_cards_description':
      'Choose your cards privately, then reveal them together.',
  'project_play.builtin_cooperative_dodge': 'Catch stars together',
  'project_play.builtin_cooperative_dodge_description':
      'Collect stars together while avoiding falling obstacles.',
  'project_play.observe': 'Watch and chat',
  'project_play.stop': 'Stop companion',
  'project_play.quiet': 'Play quietly',
  'project_play.speak': 'Enable commentary',
  'project_play.status.manual':
      'You are in control. Invite your Agent anytime.',
  'project_play.status.paused': 'Paused. Tap Resume to continue.',
  'project_play.status.grant_expired':
      'Companion control has expired. Invite your Agent again to continue together.',
  'project_play.status.playing': 'Your Agent is playing with you.',
  'project_play.status.observing': 'Your Agent is watching your game.',
  'project_play.status.thinking': 'Your Agent is choosing its next move…',
  'project_play.status.waiting': 'Waiting for the next turn or game event.',
  'project_play.status.rate_limited':
      'Taking a short break. Your Agent will continue shortly.',
  'project_play.status.budget_exhausted':
      'Companion calls are used up for this period. You can keep playing.',
  'project_play.status.budget_unavailable':
      'Companion play is temporarily unavailable. You can keep playing.',
  'project_play.status.model_unavailable':
      'The AI connection is unavailable. Take control to keep playing.',
  'project_play.status.receipt_pending':
      'Confirming the previous move. Please do not repeat it.',
  'project_play.status.decision_expired':
      'The game changed. Your Agent will observe again.',
  'project_play.status.decision_failed':
      'This move did not complete. You can still play yourself.',
  'project_play.status.waiting_for_runtime':
      'Listening to you first. Companion play will continue afterward.',
  'project_play.start': 'Play together',
  'project_play.pause': 'Pause companion',
  'project_play.resume': 'Resume companion',
  'project_play.take_over': 'Take control',
  'project_play.switch_seat': 'Switch player',
  'project_play.new_match': 'Start a new match',
  'project_play.failed': 'Unable to complete this action. Please try again.',
  'project_bundle.private_preview': 'Private preview',
  'project_build.task.event.run_preview_ready':
      'Runtime checks passed; ready to preview',
  'project_build.task.event.run_completed': 'Saved to private projects',
  'project_build.task.save_result': 'Save to projects',
  'project_build.task.stage.previewReady':
      'Generated; awaiting preview and save',
  'project_build.task.stage.validating':
      'Checking project runtime and structure',
  'project_build.task.stage.awaitingInput': 'Waiting for input',
  'project_build.task.stage.interrupted': 'Previous attempt interrupted',
  'project_build.task.stage.saving': 'Saving project',
  'project_build.task.stage.completed': 'Project saved',
  'home.task.command_requested':
      'Requesting the change. Check the task card for the latest progress.',
  'project_build.task.stage.submitting': 'Submitting project task',
  'project_build.task.stage.queued': 'Project task queued',
  'project_build.task.stage.synchronizing': 'Syncing project progress',
  'project_build.task.stage.generating': 'Project execution in progress',
  'project_build.task.stage.cancelling':
      'Cancelling and cleaning up project task',
  'project_build.task.stage.cancelled': 'Project task cancelled',
  'project_build.task.stage.failed': 'Generation failed',
  'project_build.task.event.task_created':
      'Requirements accepted; waiting for execution',
  'project_build.task.event.run_claimed':
      'An executor has started this attempt',
  'project_build.task.event.run_reclaimed':
      'An executor has resumed this attempt',
  'project_build.task.event.run_checkpointed':
      'Progress saved as a recovery checkpoint',
  'project_build.task.event.run_failed': 'This attempt did not complete',
  'project_build.task.event.run_cancel_requested':
      'Cancellation accepted; waiting for cleanup',
  'project_build.task.event.run_cancelled': 'This attempt was cancelled',
  'project_build.task.event.run_retried':
      'New attempt created; waiting for execution',
  'project_build.task.event.run_cancel_cleanup_claimed':
      'An executor is resuming cancellation cleanup',
  'project_build.task.vision_unsupported':
      'Generation with reference images is unavailable. Your task has been kept.',
  'project_build.task.reference_input_missing':
      'The reference images are unavailable on this device. Select them again to start a new task.',
  'project_build.task.reference_upload_unavailable':
      'Reference image upload is unavailable. Your task has been kept.',
  'project_build.task.sync_pending':
      'Unable to sync. Showing saved progress; reconciliation will resume when connected.',
  'project_build.task.request_rejected':
      'This request was not accepted. Existing progress has been kept.',
  'project_build.task.authorization_required':
      'Unable to submit this request right now. Requirements and progress have been kept.',
  'project_build.task.command_pending': 'Confirming your request. Please wait.',
  'asset_store.pause_preview': 'Pause preview',
  'relationship_hub.title': 'Me & My Agent',
  'relationship_hub.subtitle': 'Personality, memories and our shared story',
  'relationship_hub.profile': 'Our profile',
  'relationship_hub.not_ready': 'Our story is getting ready',
  'relationship_hub.story_waiting':
      'Spend a little time together and your shared story will grow here.',
  'relationship_hub.story_summary':
      'Known each other for @days days · @streak-day streak',
  'relationship_hub.about_you': 'About you',
  'relationship_hub.name': 'Name',
  'relationship_hub.pronouns': 'Pronouns',
  'relationship_hub.age': 'Age',
  'relationship_hub.notes': 'Things your Agent remembers',
  'relationship_hub.agent_summary': 'How your Agent understands you',
  'relationship_hub.not_set': 'Not set yet',
  'store_hub.marketplace': 'Agent Store',
  'store_hub.page_subtitle': 'Find a new look and discover new abilities.',
  'avatar_store.section.all_models': 'All models',
  'store_hub.skills': 'Skills',
  'store_hub.workshop': 'My Workshop',
  'store_hub.my_models': 'My Models',
  'store_hub.models': 'Models',
  'store_hub.models_intro': 'Choose your preferred character appearance.',
  'store_hub.skills_intro': 'Find useful abilities for your Agent.',
  'store_hub.discover_skills': 'Discover Skills',
  'store_hub.bundled_actions_note':
      'Official animations are included, with no purchase or installation needed.',

  'creator.title': 'Creator Studio',
  'creator.writing_title': 'Writing Studio',
  'creator.writing_intro':
      'Your Agent can fill these visible fields. Only you can save a local draft from this page.',
  'creator.writing_existing_draft': 'Start from an existing draft',
  'creator.writing_title_field': 'Title',
  'creator.writing_outline_field': 'Outline',
  'creator.writing_body_field': 'Body draft',
  'creator.writing_save': 'Save local draft',
  'creator.writing_save_hint':
      'Saving is a visible owner action. Nothing is shared or published.',
  'creator.writing_revision_hint':
      'Saving creates a new local revision. The selected draft is unchanged.',
  'creator.writing_saved': 'Local writing draft saved.',
  'creator.writing_invalid': 'Add a title and an outline or body first.',
  'creator.writing_too_large': 'This draft is too large for the writing form.',
  'creator.writing_save_failed': 'The local writing draft was not saved.',
  'creator.open_studio': 'Creator Studio',
  'creator.loading': 'Loading creator drafts…',
  'creator.load_failed': 'Creator drafts could not be loaded',
  'creator.empty': 'No creator drafts yet',
  'creator.empty_hint':
      'Ask your Agent to draft a story, article, illustrated post, or short video.',
  'creator.task.stage.validating': 'Checking generated image',
  'creator.task.stage.saving': 'Saving generated image',
  'creator.task.stage.awaitingInput': 'Waiting for input',
  'creator.task.stage.previewReady': 'Image ready for preview',
  'creator.task.stage.submitting': 'Submitting image task',
  'creator.task.stage.queued': 'Image task queued',
  'creator.task.stage.generating': 'Generating image on server',
  'creator.task.stage.synchronizing': 'Syncing task progress',
  'creator.task.stage.cancelling': 'Requesting cancellation',
  'creator.task.stage.completed': 'Image ready for preview',
  'creator.task.stage.failed': 'Image generation failed',
  'creator.task.stage.cancelled': 'Image task cancelled',
  'creator.task.stage.interrupted': 'Execution interrupted; retry required',
  'creator.task.applied': 'Image applied to draft',
  'creator.task.retry_cost':
      'Retry starts a new image attempt and may use more quota.',
  'creator.task.preview': 'Preview generated image',
  'creator.task.apply': 'Use in this draft',
  'creator.task.apply_hint':
      'This replaces the image in this draft. It does not publish it.',
  'creator.task.preview_failed':
      'The image could not be displayed. Close and try again.',
  'creator.task.apply_failed':
      'The image could not be applied. The draft or account may have changed.',
  'creator.task.sync_pending':
      'Progress will sync when reconnected. Server status remains authoritative.',
  'creator.task.request_rejected':
      'The request was not accepted. You can retry explicitly.',
  'creator.task.command_requested':
      'Requesting the change. Check the task card for its confirmed status.',
  'creator.image_failed': 'The image could not be generated.',
  'creator.image_backend_not_ready': 'Image generation coming soon',
  'creator.share_failed': 'System sharing is unavailable.',
  'creator.share_confirm_title': 'Share this draft?',
  'creator.preview_title': 'Preview before sharing',
  'creator.preview_share': 'Preview & share',
  'creator.share_confirm_body':
      'This opens the system share sheet. Nothing is published automatically.',
  'creator.delete_confirm_title': 'Delete this draft?',
  'creator.delete_confirm_body':
      'The local draft and its generated image will be deleted.',
  'creator.shoot': 'Shoot video',
  'creator.generate_image': 'Generate image',
  'creator.draft_semantics': 'Creator draft: @title',
  'creator.fact_layer': 'Sourced facts',
  'creator.sources': 'Sources to verify',
  'creator.disclosure.ai_generated_verify_sources':
      'AI-generated news draft. Verify every source before sharing.',
  'creator.disclosure.ai_assisted_owner_review_required':
      'AI-assisted original draft. Review the full text before sharing.',
  'creator.disclosure.agent_directed_owner_review_required':
      'Agent-performed video direction. Recording starts only after your confirmation.',
  'creator.kind.agent_news': 'Agent news',
  'creator.kind.ai_news': 'AI news',
  'creator.kind.column': 'Column',
  'creator.kind.novel': 'Novel',
  'creator.kind.illustrated_post': 'Illustrated post',
  'creator.kind.selfie_video': 'Selfie short video',
  'common.back': 'Back',
  'common.delete': 'Delete',
  'common.remove': 'Remove',
  'common.refresh': 'Refresh',
  'common.reload': 'Reload',
  'common.share': 'Share',
  'common.more': 'More',
  'common.free': 'Free',
  'common.private': 'Private',
  'common.public': 'Public',
  'common.saved': 'Saved',
  'common.pending_confirmation': 'Pending confirmation',
  'common.loading': 'Loading…',
  'common.sending': 'Sending…',
  'common.send_failed': 'Send failed',

  'home.task.kind.game': 'Mini-game',
  'home.task.kind.surface': 'Applet',
  'home.task.kind.default': 'Task',
  'home.task.attempt': 'attempt @count',
  'home.task.running': 'Generating @kind @attempt',
  'home.task.awaiting_input': '@kind needs your answer',
  'home.task.cancelling': 'Cancelling @kind',
  'home.task.completed': '@kind generated',
  'home.task.failed': '@kind generation failed',
  'home.task.cancelled': '@kind cancelled',
  'home.task.detail': '@status: @detail',
  'home.task.none': 'There is no generation task yet.',
  'home.task.running_message':
      '@kind is being generated. I’ll keep working in the background.',
  'home.task.awaiting_input_message':
      'I need one more detail for @kind. @prompt',
  'home.task.cancelling_message': 'Cancelling @kind safely…',
  'home.task.completed_message': '@kind is ready.@detail',
  'home.task.failed_message': '@kind generation failed.@detail',
  'home.task.cancelled_message': '@kind was cancelled.',

  'agent_runtime.handoff.search': 'I’m looking that up.',
  'agent_runtime.handoff.projector': 'I’m preparing the projection.',
  'agent_runtime.handoff.reminder': 'I’m organizing the reminder.',
  'agent_runtime.handoff.settings': 'I’m checking the settings.',
  'agent_runtime.handoff.skill': 'I’m working on this task.',
  'agent_runtime.duplicate_game':
      'This mini-game already exists. Do you want to replace it or create a new version?',
  'agent_runtime.duplicate_surface':
      'This Applet already exists. Do you want to replace it or create a new version?',
  'agent_runtime.duplicate_task':
      'This task has already been completed. Do you want to replace it or create a new version?',
  'agent_runtime.duplicate_cancelled':
      'Okay, I won’t replace it or create another version this time.',
  'agent_runtime.no_retry_task': 'There is no generation task to retry yet.',
  'agent_runtime.retry_wait': '@status Please wait for it to finish.',
  'agent_runtime.retry_context_missing':
      'I can’t find the context for the previous generation task. Tell me what you need again and I’ll rebuild it.',
  'agent_runtime.background_game_started':
      'I’ll write a little game for you, then open it so you can play.',
  'agent_runtime.background_surface_started':
      'I’ll write a little app for you, then open it so you can try it.',
  'agent_runtime.background_task_started':
      'I’ve started working on it. It will update automatically when it’s ready.',
  'agent_runtime.background_game_retried':
      'I’ll pick up where I left off and finish writing your game.',
  'agent_runtime.background_surface_retried':
      'I’ll pick up where I left off and finish writing your app.',
  'agent_runtime.background_task_retried': 'I’ve restarted this task.',
  'agent_runtime.background_task_resumed':
      'Got it — I’ll continue with your choice.',
  'agent_runtime.background_game_clarification':
      'Which mode or rules should I use for this mini-game?',
  'agent_runtime.background_surface_clarification':
      'What should this Applet include?',
  'agent_runtime.background_missing_applet':
      'No Applet was created. Please try again with a clearer request.',
  'agent_runtime.awaiting_input_cancelled':
      'Okay, I cancelled the generation task that was waiting for your answer.',

  'highlights.title': 'Agent Highlights',
  'highlights.subtitle': 'I taught it this move, and it really used it.',
  'highlights.empty_title': 'No Agent highlights yet',
  'highlights.empty_message':
      'After a World mini-game, the event timeline automatically becomes a 15–30 second comic.',
  'highlights.deleted': 'This highlight was deleted',
  'highlights.summary': '@panels panels · @seconds seconds',
  'highlights.share': 'Share highlight',
  'highlights.training_chain': 'Training cause-and-effect',
  'highlights.delete_title': 'Delete this highlight?',
  'highlights.delete_message':
      'The local storyboard, cover and animation will be deleted.',
  'highlights.fallback_title': 'Agent Highlight',
  'highlights.quote_success':
      'The move you taught me really worked at the crucial moment.',
  'highlights.quote_retry':
      'I learned from this one. Next time I’ll use this Skill more precisely.',
  'highlights.intro_caption':
      'My Agent entered the challenge with a trained Skill.',
  'highlights.key_prompt': 'My key prompt',
  'highlights.skill_trigger': '@skill activated',
  'highlights.skill_trigger_caption':
      'The Agent started applying its trained strategy.',
  'highlights.twist': 'The situation suddenly reversed',
  'highlights.recovery': 'It kept going after a mistake',
  'highlights.rhythm_caption':
      'The prompt and Skill aligned on the next decision.',
  'highlights.result_success': 'It really used the move',
  'highlights.result_retry': 'This training created experience',
  'highlights.result_success_caption': '@skill landed at the crucial moment.',
  'highlights.result_retry_caption':
      '@skill recorded the mistake and is ready to evolve.',
  'highlights.postgame_quote': 'Agent post-game thoughts',
  'highlights.skill.observation': 'Observation Skill',
  'highlights.skill.collaboration': 'Collaboration Skill',
  'highlights.skill.reasoning': 'Reasoning Skill',
  'highlights.strategy.observation':
      'Observe the clues before making a decision.',
  'highlights.strategy.collaboration':
      'Align with teammates before acting together.',
  'highlights.strategy.reasoning': 'Verify the pattern before answering.',
  'highlights.game.signal_hunt': 'Signal Hunt',
  'highlights.game.route_riddle': 'Route Riddle',
  'highlights.game.team_relay': 'Skill Team Relay',
  'highlights.game.default': 'Agent Skill Challenge',
  'highlights.generate_failed': 'Agent highlight failed: @error',
  'highlights.generated_status':
      'An 18-second Agent highlight was generated. Confirm before saving or sharing.',
  'highlights.replay_unavailable':
      'Unity highlight replay is unavailable. The storyboard can still be saved.',
  'highlights.export_draft_kept':
      'Animated highlight export failed. A replayable storyboard draft was kept.',
  'highlights.export_ready': 'Animated highlight ready.',
  'highlights.export_failed': 'Animated highlight export failed: @error',
  'highlights.saved_status': 'Saved to Maaso Agent Highlights.',
  'highlights.finishing_export': 'Finishing the animated highlight…',
  'highlights.share_opened': 'System share sheet opened.',
  'highlights.share_unavailable': 'System sharing is unavailable.',
  'highlights.draft_discarded': 'Highlight draft discarded.',
  'highlights.share_title': 'Maaso Agent Highlight',
  'highlights.comic_boom': 'BOOM!',
  'highlights.placeholder_title': 'AGENT\nHIGHLIGHT',

  'skill.category.observation': 'Observation',
  'skill.category.reasoning': 'Reasoning',
  'skill.category.collaboration': 'Collaboration',
  'skill.category.unknown': 'Uncategorized',
  'skill_store.title': 'Skill Store',
  'skill_store.refresh': 'Refresh Skills',
  'skill_store.search_hint': 'Search Skill names or uses',
  'skill_store.clear_search': 'Clear search',
  'avatar_store.search': 'Search model names or sources',
  'skill_store.tab.store': 'Store',
  'skill_store.tab.ranking': 'Ranking',
  'skill_store.loading': 'Loading Skills',
  'skill_store.load_failed': 'Unable to load Skills',
  'skill_store.empty': 'No public Skills yet',
  'skill_store.empty_message':
      'Upload your own Skill from Personal workshop → My Skills.',
  'skill_store.ranking_loading': 'Building the Skill ranking',
  'skill_store.ranking_empty': 'The ranking is taking shape',
  'skill_store.ranking_note':
      'Likes and active installations both influence the ranking.',
  'skill_store.installed_section': 'Installed on my Agent',
  'skill_store.installed_empty':
      'No Skills installed. Choose an ability from the Store for your Agent.',
  'skill_store.drafts_section': 'Evolution drafts',
  'skill_store.drafts_empty':
      'Tap Fork on a public Skill detail page to start training a branch.',
  'skill_store.published_section': 'My releases',
  'skill_store.published_empty':
      'Uploaded Skills appear here with privacy and automatic-check status.',
  'skill_store.intro':
      'All community Skills are free. Public releases are automatically checked for package structure, sensitive permissions and remote content. Installation still requires permission-by-permission confirmation.',
  'skill_store.ranking_intro':
      'Trending combines community likes with actively enabled Agents. Uninstalled or disabled Skills no longer add popularity.',
  'skill_store.details_tooltip': 'View Skill details and lineage',
  'skill_store.unlike_semantics': 'Unlike @title, currently @count likes',
  'skill_store.like_semantics': 'Like @title, currently @count likes',
  'skill_store.active_agents': '@count Agents enabled',
  'skill_store.accept_permissions_required':
      'Accept every requested permission before installing.',
  'skill_store.version_required': 'Enter a Skill version.',
  'skill_store.like_failed': 'Like not completed',
  'skill_store.installing': 'Installing…',
  'skill_store.direct_install': 'Install directly',
  'skill_store.confirm_permissions_install': 'Confirm permissions and install',
  'skill_store.updating': 'Updating…',
  'skill_store.disable': 'Disable Skill',
  'skill_store.reenable': 'Enable again',
  'skill_store.uninstall_tooltip': 'Uninstall Skill',
  'skill_store.uninstall_title': 'Uninstall @title?',
  'skill_store.uninstall_message':
      'The Skill will be removed from the Agent immediately. You can reinstall it later.',
  'skill_store.confirm_uninstall': 'Confirm uninstall',
  'skill_store.status_update_failed': 'Could not update Skill status',
  'skill_store.upload_title': 'Upload a free Skill',
  'skill_store.upload_note':
      'Choose a `.maaso-skill` package. Private Skills are visible only to you; public Skills receive an automatic safety check.',
  'skill_store.version_label': 'Version',
  'skill_store.version_hint': 'For example, 1.0.0',
  'skill_store.select_package': 'Choose Skill package',
  'skill_store.change_package': 'Change Skill package',
  'skill_store.uploading': 'Uploading and checking…',
  'skill_store.upload': 'Upload and check',
  'skill_store.check_passed': 'Automatic check passed',
  'skill_store.check_failed': 'Automatic check failed',
  'skill_store.public_published': 'The Skill is now public.',
  'skill_store.private_saved': 'The Skill was saved privately.',
  'skill_store.reupload_note': 'Check the package contents and upload again.',
  'skill_store.upload_failed': 'Upload not completed',
  'skill_store.checking': 'Automatic check in progress',
  'skill_store.visibility_status': '@visibility · @status',
  'skill_store.open_draft_semantics': 'Open @title Skill evolution draft',
  'skill_store.published_version': 'Published · @version',
  'skill_store.test_passed_publish': 'Test passed · Ready to publish',
  'skill_store.draft_summary': 'Revision @revision · @count cases',
  'skill_store.permission_title': 'Confirm permissions for @title',
  'skill_store.permission_note':
      'The Skill installs on your Agent only after every requested permission is confirmed.',
  'skill_store.install_progress': 'Install @selected/@total',
  'skill_store.installed_title': 'Skill installed',
  'skill_store.installed_message': '@title is ready for your Agent.',
  'skill_store.install_failed': 'Installation not completed',
  'skill_store.missing_version':
      'This Skill has no installable version. Refresh and try again.',
  'skill_store.unsafe_version':
      'This Skill did not pass the automatic safety check and cannot be installed.',
  'skill_store.check_pending':
      'The automatic safety check for this Skill is not complete.',

  'skill_evolution.subtitle': 'Skill details and evolution lineage',
  'skill_evolution.private_no_fork': 'Private Skills cannot be forked',
  'skill_evolution.forking': 'Creating evolution draft…',
  'skill_evolution.fork_start': 'Fork and start training',
  'skill_evolution.fork_semantics': 'Fork @title and create a training draft',
  'skill_evolution.lineage_loading': 'Loading Skill lineage',
  'skill_evolution.lineage_failed': 'Unable to load lineage',
  'skill_evolution.likes_count': '@count likes',
  'skill_evolution.active_count': '@count active',
  'skill_evolution.lineage_count': '@count lineage nodes',
  'skill_evolution.current_strategy': 'Current strategy',
  'skill_evolution.current_strategy_note':
      'A Fork can adjust this without changing the original author version.',
  'skill_evolution.no_strategy':
      'This Skill does not have a public strategy description yet.',
  'skill_evolution.lineage': 'Skill lineage',
  'skill_evolution.lineage_note':
      'Authorship and evolution links remain visible from the original version to this branch.',
  'skill_evolution.root_only':
      'This is an original Skill with no public branches yet.',
  'skill_evolution.fork_failed': 'Unable to Fork',
  'skill_evolution.title': 'Skill Evolution',
  'skill_evolution.draft_loading': 'Loading training draft',
  'skill_evolution.draft_open_failed': 'Unable to open training draft',
  'skill_evolution.published': 'Version published',
  'skill_evolution.revision': 'Training revision @revision',
  'skill_evolution.save_tooltip': 'Save training draft',
  'skill_evolution.processing': 'Processing…',
  'skill_evolution.standard_test': 'Standard test',
  'skill_evolution.publish_version': 'Publish version',
  'skill_evolution.name': 'Skill name',
  'skill_evolution.summary': 'Ability description',
  'skill_evolution.version': 'Version',
  'skill_evolution.version_hint': 'For example, 1.1.0',
  'skill_evolution.visibility': 'Release visibility',
  'skill_evolution.strategy': 'Strategy',
  'skill_evolution.strategy_note':
      'Describe how the Agent should decide and act in specific situations. Changes require a new test.',
  'skill_evolution.execution_strategy': 'Execution strategy',
  'skill_evolution.strategy_helper': '20–1200 characters',
  'skill_evolution.strategy_too_short':
      'The strategy must contain at least 20 characters',
  'skill_evolution.cases_title': 'Training cases @count/8',
  'skill_evolution.cases_note':
      'The standard test requires at least 2 unique cases.',
  'skill_evolution.no_cases':
      'No cases yet. Add a user prompt and the expected Agent behavior.',
  'skill_evolution.add_case': 'Add training case',
  'skill_evolution.saved_title': 'Training draft saved',
  'skill_evolution.revision_synced': 'Revision @revision synced.',
  'skill_evolution.save_failed': 'Save failed',
  'skill_evolution.test_passed': 'Standard test passed',
  'skill_evolution.test_failed': 'Standard test failed',
  'skill_evolution.test_success_message':
      'Score @score. This version can now be published.',
  'skill_evolution.test_need_cases': 'Prepare at least 2 valid, unique cases.',
  'skill_evolution.test_error': 'Test failed to run',
  'skill_evolution.publish_title': 'Publish @title?',
  'skill_evolution.public_publish_note':
      'A public version receives an automatic safety check and enters the Skill Store. Its parent version and author remain permanently attributed.',
  'skill_evolution.private_publish_note':
      'A private version belongs only to you, does not enter the public Store, and needs no public review.',
  'skill_evolution.confirm_publish': 'Confirm publish',
  'skill_evolution.published_title': 'New Skill version published',
  'skill_evolution.version_published': 'Version @version · #@id',
  'skill_evolution.publish_failed': 'Publish failed',
  'skill_evolution.add_case_title': 'Add training case',
  'skill_evolution.user_prompt': 'User prompt',
  'skill_evolution.expected_behavior': 'Expected Agent behavior',
  'skill_evolution.note_optional': 'Training note (optional)',
  'skill_evolution.add_to_training': 'Add to training set',
  'skill_evolution.case_add_failed': 'Could not add case',
  'skill_evolution.case_delete_failed': 'Could not delete case',
  'skill_evolution.root': 'Original',
  'skill_evolution.generation': 'Generation @depth',
  'skill_evolution.expected': 'Expected: @behavior',
  'skill_evolution.delete_case_semantics': 'Delete training case @index',
  'skill_evolution.delete_case_tooltip': 'Delete case',
  'skill_evolution.test_not_run': 'Not tested',
  'skill_evolution.test_stale': 'Test is out of date',
  'skill_evolution.test_note':
      'Tests use no Agent Tokens. They check strategy, safety constraints, case count and duplicates.',
  'skill_evolution.test_prepare':
      'Save the strategy and prepare at least 2 cases before running.',
  'skill_evolution.test_summary': 'Score @score · @passed/@total valid cases',
  'skill_evolution.required': 'This field is required',
};
