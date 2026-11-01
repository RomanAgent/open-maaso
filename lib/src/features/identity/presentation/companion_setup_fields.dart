import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_palette.dart';
import '../application/companion_setup_controller.dart';
import '../domain/companion_profile.dart';
import 'companion_avatar.dart';

class CompanionSetupFields extends StatelessWidget {
  const CompanionSetupFields({
    super.key,
    required this.controller,
    required this.step,
  });
  final CompanionSetupController controller;

  /// 0 = user avatar, 1 = Agent model and gender, 2 = explicit interests.
  final int step;
  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final draft = controller.draft.value;
    if (draft == null) return const SizedBox.shrink();
    final busy = controller.busy.value;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (step == 0) ...[
          Center(child: CompanionAvatar(profile: draft, size: 96)),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final preset in CompanionProfile.avatarPresets)
                Semantics(
                  selected: draft.avatarPreset == preset,
                  label: companionPresetLabel(preset, zh),
                  button: true,
                  child: IconButton.filledTonal(
                    key: ValueKey('companion-avatar-$preset'),
                    tooltip: companionPresetLabel(preset, zh),
                    isSelected: draft.avatarPreset == preset,
                    iconSize: 24,
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(56),
                    ),
                    onPressed: busy
                        ? null
                        : () => controller.setAvatarPreset(preset),
                    icon: Icon(CompanionAvatar.iconFor(preset)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            key: const ValueKey('companion-upload-avatar'),
            onPressed: busy
                ? null
                : () async {
                    try {
                      final file = await ImagePicker().pickImage(
                        source: ImageSource.gallery,
                        maxWidth: 1024,
                        maxHeight: 1024,
                        imageQuality: 90,
                        requestFullMetadata: false,
                      );
                      if (file == null || !controller.active) return;
                      if (await file.length() > 8 * 1024 * 1024) {
                        controller.issue.value = 'invalid_image';
                        return;
                      }
                      final bytes = await file.readAsBytes();
                      if (controller.active) {
                        await controller.setAvatarImage(bytes);
                      }
                    } catch (_) {
                      if (controller.active) {
                        controller.issue.value = 'invalid_image';
                      }
                    }
                  },
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(zh ? '从相册选择' : 'Choose from photos'),
          ),
        ],
        if (step == 1) ...[
          Text(
            zh ? 'Agent 性别' : 'Agent gender',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final gender in CompanionProfile.genders)
                ChoiceChip(
                  key: ValueKey('companion-gender-$gender'),
                  label: Text(companionGenderLabel(gender, zh)),
                  selected: draft.agentGender == gender,
                  side: BorderSide.none,
                  onSelected: busy ? null : (_) => controller.setGender(gender),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            zh ? '人物形象' : 'Character',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth < 340
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final option in controller.avatars.catalog)
                    SizedBox(
                      width: width,
                      child: Semantics(
                        selected:
                            option.id == controller.avatars.selectedId.value,
                        child: Material(
                          color:
                              option.id == controller.avatars.selectedId.value
                              ? colors.primaryContainer
                              : AppSecondaryPalette.of(context).surface,
                          borderRadius: BorderRadius.circular(20),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('companion-model-${option.id}'),
                            onTap: busy
                                ? null
                                : () => controller.selectModel(option.id),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: [
                                  SizedBox(
                                    height: 144,
                                    width: double.infinity,
                                    child: option.previewAssetPath != null
                                        ? Image.asset(
                                            option.previewAssetPath!,
                                            fit: BoxFit.contain,
                                          )
                                        : Uri.tryParse(
                                                option.previewImageUrl ?? '',
                                              )?.scheme ==
                                              'https'
                                        ? Image.network(
                                            option.previewImageUrl!,
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, _, _) =>
                                                const Icon(
                                                  Icons.person_outline,
                                                  size: 48,
                                                ),
                                          )
                                        : const Icon(
                                            Icons.person_outline,
                                            size: 48,
                                          ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          option.name,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      if (option.id ==
                                          controller.avatars.selectedId.value)
                                        Icon(
                                          Icons.check_circle_rounded,
                                          color: colors.primary,
                                          size: 20,
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (controller.modelIssue.value)
            TextButton(
              onPressed: controller.refreshModels,
              child: Text(zh ? '重新加载更多形象' : 'Reload more characters'),
            ),
        ],
        if (step == 2) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final interest in CompanionProfile.interestIds)
                FilterChip(
                  key: ValueKey('companion-interest-$interest'),
                  label: Text(companionInterestLabel(interest, zh)),
                  selected: draft.interests.contains(interest),
                  side: BorderSide.none,
                  onSelected: busy
                      ? null
                      : (_) => controller.toggleInterest(interest),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            zh
                ? '可以多选，也可以留空。之后随时修改。'
                : 'Choose any, or leave these empty. You can change them later.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
        if (controller.issue.value != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              companionIssueLabel(controller.issue.value!, zh),
              style: TextStyle(color: colors.error),
            ),
          ),
      ],
    );
  });
}

String companionPresetLabel(String value, bool zh) => switch (value) {
  'star' => zh ? '星星' : 'Star',
  'moon' => zh ? '月亮' : 'Moon',
  'leaf' => zh ? '绿叶' : 'Leaf',
  'wave' => zh ? '海浪' : 'Wave',
  'spark' => zh ? '星光' : 'Spark',
  _ => zh ? '星球' : 'Orbit',
};
String companionGenderLabel(String value, bool zh) => switch (value) {
  'female' => zh ? '女性' : 'Female',
  'male' => zh ? '男性' : 'Male',
  'nonbinary' => zh ? '非二元' : 'Nonbinary',
  _ => '',
};
String companionInterestLabel(String value, bool zh) => switch (value) {
  'music' => zh ? '音乐' : 'Music',
  'gaming' => zh ? '游戏' : 'Gaming',
  'travel' => zh ? '旅行' : 'Travel',
  'fitness' => zh ? '运动' : 'Fitness',
  'books' => zh ? '阅读' : 'Books',
  'art' => zh ? '艺术' : 'Art',
  'technology' => zh ? '科技' : 'Technology',
  'food' => zh ? '美食' : 'Food',
  'nature' => zh ? '自然' : 'Nature',
  'movies' => zh ? '电影' : 'Movies',
  _ => value,
};
String companionIssueLabel(String value, bool zh) => switch (value) {
  'invalid_image' =>
    zh ? '这张图片暂时无法使用，请选择另一张。' : 'This photo could not be used. Choose another.',
  'conflict' =>
    zh
        ? '另一台设备更新了资料，请确认最新内容后再保存。'
        : 'Another device updated your profile. Review the latest choices before saving.',
  'model_unavailable' =>
    zh ? '形象暂时未能切换，请重试。' : 'The character could not be changed. Try again.',
  _ => zh ? '资料暂时无法同步，请重试。' : 'Your profile could not sync. Try again.',
};
