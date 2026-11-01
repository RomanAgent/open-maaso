#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Maaso.World;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class MaasoHumanoidActionImporter
    {
        public const string ExternalActionFolderEnv = "MAASO_ACTION_FBX_DIR";

        private const string TargetDirectory = "Assets/MaasoAvatar/Animations/Humanoid";
        private const string ActionDirectory = TargetDirectory + "/Actions";
        private const string ControllerPath = TargetDirectory + "/MaasoHumanoid.controller";
        private const string ScenePath =
            MaasoDefaultAvatarSceneBuilder.ScenePath;
        private const string DefaultIdleClipId = "idle";
        private const string MainIdleStateId = "idle_shrug";

        private static readonly Dictionary<string, string> KnownClipIds = new(StringComparer.Ordinal)
        {
            { "Idle", DefaultIdleClipId },
            { "\u8d70\u5de6\u8f6c", "walk_left_turn" },
            { "\u6807\u51c6\u8d70", "standard_walk" },
            { "\u5973\u6027\u5f00\u59cb\u6b65\u884c", "female_start_walking" },
            { "\u5973\u6027\u505c\u6b62\u884c\u8d70", "female_stop_walking" },
            { "\u5077\u5077\u5730\u8d70", "sneaky_walk" },
            { "\u673a\u5668\u4eba\u8857\u821e", "robot_street_dance" },
            { "\u563b\u54c8\u821e\u8e48", "hip_hop_dance" },
            { "\u5413\u4e00\u8df3", "startled" },
            { "\u601d\u8003", "thinking" },
            { "\u7948\u7977", "praying" },
            { "\u6fc0\u52a8\u7684", "excited" },
            { "\u6df1\u601d\u719f\u8651\u7684\u70b9\u5934", "thoughtful_nod" },
            { "\u540c\u610f234", "agree_234" },
            { "\u54ed\u6ce3", "crying" },
            { "\u6325\u52a8\u7684\u624b\u52bf", "waving_gesture" },
            { "\u6325\u624b", "wave" },
            { "\u98de\u543b1", "blow_kiss_1" },
            { "\u8dfa\u811a", "stomp" },
            { "\u8038\u80a9", "shrug" },
            { "\u9ad8\u5174345", "happy_345" },
            { "\u770b234", "look_234" },
            { "\u5bb3\u7f9e\u7684", "shy" },
            { "\u540c\u610f", "agree" },
            { "\u95f2\u7f6e1", "idle_1" },
            { "\u95f2\u7f6e3456", "idle_3456" },
            { "\u7ad9\u5728\u90a3\u91cc\u65e0\u6240\u4e8b\u4e8b\u5730\u770b\u7740\u30021", "idle_look_around_1" },
            { "\u65e0\u4e8b\u53ef\u505a\u7684201", "idle_nothing_to_do_201" },
            { "\u95f2\u7f6e\u8038\u80a9", "idle_shrug" },
            { "\u5411\u53f3\u8f6c1", "idle_turn_right_1" },
        };

        private static readonly string[] RetiredActionPaths =
        {
            TargetDirectory + "/FemaleStandingIdle.fbx",
            TargetDirectory + "/FemaleStandingIdle.fbx.meta",
            TargetDirectory + "/FemaleStandingIdlePose.anim",
            TargetDirectory + "/FemaleStandingIdlePose.anim.meta",
            TargetDirectory + "/Idle1.fbx",
            TargetDirectory + "/Idle1.fbx.meta",
            TargetDirectory + "/MaasoOfficialStanding1Idle.fbx",
            TargetDirectory + "/MaasoOfficialStanding1Idle.fbx.meta",
            TargetDirectory + "/MaasoOfficialStanding1Idle.anim",
            TargetDirectory + "/MaasoOfficialStanding1Idle.anim.meta",
            TargetDirectory + "/MaasoOfficialStanding1Idle.pose.json",
            TargetDirectory + "/MaasoOfficialStanding1Idle.pose.json.meta",
            TargetDirectory + "/MaasoIdleSkirtSafe.mask",
            TargetDirectory + "/MaasoIdleSkirtSafe.mask.meta",
            ActionDirectory + "/Idle.fbx",
            ActionDirectory + "/Idle.fbx.meta",
            ActionDirectory + "/Idle.anim",
            ActionDirectory + "/Idle.anim.meta",
        };

        [MenuItem("Maaso/Actions/Reimport Action FBX Folder", false, 10)]
        public static void ImportDefaultActionFolder()
        {
            ImportActionFbxFolder(ResolveDefaultSourceFolder());
        }

        [MenuItem("Maaso/Actions/Normalize Shared FK Playback", false, 13)]
        public static void NormalizeSharedFkPlayback()
        {
            var controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
            if (controller == null) throw new InvalidOperationException("Missing shared Humanoid controller.");
            ConfigureActionPlaybackStates(controller, controller.layers.SelectMany(layer =>
                layer.stateMachine.states).Select(child => child.state.name));
            AssetDatabase.SaveAssets();
            MaasoOpenAnnieMotionImporter.NormalizeControllerSerialization();
            Debug.Log("[MaasoAvatar] Shared official motion states use authored FK playback.");
        }

        [MenuItem("Maaso/Actions/Rebuild Imported Action Clips", false, 11)]
        public static void RebuildImportedActionClips()
        {
            string[] clipPaths = AssetDatabase.FindAssets("t:AnimationClip", new[] { ActionDirectory })
                .Select(AssetDatabase.GUIDToAssetPath)
                .Where(path => path.EndsWith(".anim", StringComparison.OrdinalIgnoreCase))
                .OrderBy(path => path, StringComparer.Ordinal)
                .ToArray();
            if (clipPaths.Length == 0)
            {
                throw new InvalidOperationException("No imported action clips found in " + ActionDirectory);
            }

            // Keep existing assets and state references. Rebuild the clips and
            // their playback flags without pruning actions or saving the scene.
            foreach (string clipPath in clipPaths)
            {
                string fbxPath = Path.ChangeExtension(clipPath, ".fbx");
                if (!File.Exists(fbxPath))
                {
                    throw new FileNotFoundException("Action clip has no source FBX: " + clipPath, fbxPath);
                }
                MaasoHumanoidReferencePose.EnsureStraightLegReference(fbxPath);
                CreateOrReplaceClipFromFbx(fbxPath, clipPath, Path.GetFileNameWithoutExtension(clipPath));
            }
            ConfigureActionPlaybackStates(
                AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath),
                clipPaths.Select(Path.GetFileNameWithoutExtension));
            AssetDatabase.SaveAssets();
            Debug.Log("[MaasoHumanoidActionImporter] Rebuilt " + clipPaths.Length + " imported action clip(s).");
        }

        public static void ImportActionFbxFolder(string sourceFolder)
        {
            if (string.IsNullOrWhiteSpace(sourceFolder))
            {
                sourceFolder = ResolveDefaultSourceFolder();
            }

            if (!Directory.Exists(sourceFolder))
            {
                throw new DirectoryNotFoundException("Action FBX folder not found: " + sourceFolder);
            }

            string[] sourceFbxFiles = Directory.GetFiles(sourceFolder, "*.fbx", SearchOption.AllDirectories)
                .Where(path => !Path.GetFileName(path).StartsWith(".", StringComparison.Ordinal))
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToArray();
            if (sourceFbxFiles.Length == 0)
            {
                throw new InvalidOperationException("No FBX files found in action folder: " + sourceFolder);
            }

            EnsureAssetFolder(TargetDirectory);
            EnsureAssetFolder(ActionDirectory);
            DeleteRetiredActionAssets();

            EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
            Animator target = FindSceneAvatarAnimator();
            if (target.avatar == null || !target.avatar.isValid || !target.avatar.isHuman)
            {
                throw new InvalidOperationException("Action FBX import requires the scene avatar to have a valid Humanoid avatar.");
            }

            List<ActionClip> importedClips = ImportActionFiles(sourceFbxFiles);
            AnimatorController controller = CreateOrUpdateController(importedClips);
            BindControllerToSceneAvatar(target, controller);
            ConfigureUnityAvatarReceiver(importedClips);

            EditorSceneManager.SaveOpenScenes();
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            Debug.Log("[MaasoHumanoidActionImporter] Imported " + importedClips.Count + " FBX action(s) from " + sourceFolder);
        }

        internal static bool TryResolveDefaultSourceFolder(out string sourceFolder)
        {
            string fromEnv = Environment.GetEnvironmentVariable(ExternalActionFolderEnv);
            sourceFolder = string.IsNullOrWhiteSpace(fromEnv)
                ? null
                : fromEnv.Trim();
            return !string.IsNullOrEmpty(sourceFolder);
        }

        private static string ResolveDefaultSourceFolder()
        {
            if (TryResolveDefaultSourceFolder(out string sourceFolder))
            {
                return sourceFolder;
            }

            throw new InvalidOperationException(
                "Set " + ExternalActionFolderEnv +
                " before importing external action FBX files."
            );
        }

        private static List<ActionClip> ImportActionFiles(string[] sourceFbxFiles)
        {
            var expectedAssetPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var expectedClipPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var importedClips = new List<ActionClip>();
            var usedClipIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (string sourceFbxPath in sourceFbxFiles)
            {
                string clipId = ToClipId(sourceFbxPath);
                if (string.IsNullOrWhiteSpace(clipId))
                {
                    continue;
                }
                if (!ShouldImportClipId(clipId))
                {
                    continue;
                }

                clipId = MakeUniqueClipId(clipId, usedClipIds);

                string assetName = ToAssetName(clipId);
                string targetFbxPath = ActionDirectory + "/" + assetName + ".fbx";
                string targetClipPath = ActionDirectory + "/" + assetName + ".anim";
                expectedAssetPaths.Add(targetFbxPath);
                expectedClipPaths.Add(targetClipPath);

                File.Copy(sourceFbxPath, targetFbxPath, true);
                AssetDatabase.ImportAsset(targetFbxPath, ImportAssetOptions.ForceSynchronousImport);
                ConfigureFbxImporter(targetFbxPath, clipId);
                AnimationClip clip = CreateOrReplaceClipFromFbx(targetFbxPath, targetClipPath, clipId);
                importedClips.Add(new ActionClip(clipId, clip, targetClipPath));
            }

            PruneStaleActionAssets(expectedAssetPaths, expectedClipPaths);
            importedClips.Sort((a, b) => string.Compare(a.Id, b.Id, StringComparison.Ordinal));
            return importedClips;
        }

        private static bool ShouldImportClipId(string clipId)
        {
            return !IsIdleClipId(clipId) ||
                string.Equals(clipId, MainIdleStateId, StringComparison.Ordinal);
        }

        private static void ConfigureFbxImporter(string targetFbxPath, string clipId)
        {
            var importer = AssetImporter.GetAtPath(targetFbxPath) as ModelImporter;
            if (importer == null)
            {
                throw new InvalidOperationException("Action FBX must be imported by Unity's ModelImporter: " + targetFbxPath);
            }

            importer.importAnimation = true;
            importer.animationType = ModelImporterAnimationType.Human;
            importer.avatarSetup = ModelImporterAvatarSetup.CreateFromThisModel;
            importer.sourceAvatar = null;
            importer.materialImportMode = ModelImporterMaterialImportMode.None;
            importer.importCameras = false;
            importer.importLights = false;
            importer.SaveAndReimport();

            ModelImporterClipAnimation[] clips = importer.defaultClipAnimations;
            if (clips == null || clips.Length == 0)
            {
                throw new InvalidOperationException("Action FBX did not import any animation clips: " + targetFbxPath);
            }

            bool shouldLoop = ShouldLoopClip(clipId);
            for (int i = 0; i < clips.Length; i++)
            {
                clips[i].name = clipId;
                clips[i].loopTime = shouldLoop;
                clips[i].loopPose = shouldLoop;
                clips[i].keepOriginalOrientation = true;
                clips[i].keepOriginalPositionY = true;
                clips[i].keepOriginalPositionXZ = true;
                clips[i].lockRootRotation = true;
                clips[i].lockRootHeightY = true;
                clips[i].lockRootPositionXZ = true;
            }

            importer.clipAnimations = clips;
            importer.SaveAndReimport();
            MaasoHumanoidReferencePose.EnsureStraightLegReference(targetFbxPath);
        }

        private static AnimationClip CreateOrReplaceClipFromFbx(
            string targetFbxPath,
            string targetClipPath,
            string clipId)
        {
            AnimationClip importedClip = FindImportedClip(targetFbxPath, clipId);
            var clip = new AnimationClip();
            EditorUtility.CopySerialized(importedClip, clip);
            clip.name = clipId;
            clip.legacy = false;
            bool shouldLoop = ShouldLoopClip(clipId);
            clip.wrapMode = shouldLoop ? WrapMode.Loop : WrapMode.Once;
            RemoveUnsafeCurves(clip);
            ValidateHumanoidClip(clip, targetFbxPath);
            clip.EnsureQuaternionContinuity();

            var settings = AnimationUtility.GetAnimationClipSettings(clip);
            settings.loopTime = shouldLoop;
            settings.loopBlend = shouldLoop;
            // Preserve the authored body pose, including vertical motion and
            // turning. Extract horizontal travel so the navigation owner can
            // move the actor without the skeleton drifting inside its root.
            settings.loopBlendOrientation = true;
            settings.loopBlendPositionY = true;
            settings.loopBlendPositionXZ = false;
            settings.keepOriginalOrientation = true;
            settings.keepOriginalPositionY = true;
            settings.keepOriginalPositionXZ = true;
            AnimationUtility.SetAnimationClipSettings(clip, settings);

            var existingClip = AssetDatabase.LoadAssetAtPath<AnimationClip>(targetClipPath);
            if (existingClip == null)
            {
                AssetDatabase.CreateAsset(clip, targetClipPath);
            }
            else
            {
                // Keep the asset GUID and object identity so controller states
                // and other serialized references survive a curve-policy update.
                EditorUtility.CopySerialized(clip, existingClip);
                UnityEngine.Object.DestroyImmediate(clip);
                clip = existingClip;
                // Refresh derived motion data (including averageSpeed) after
                // copying into an existing asset, not just on the transient clip.
                AnimationUtility.SetAnimationClipSettings(clip, settings);
            }
            clip.name = clipId;
            EditorUtility.SetDirty(clip);
            return clip;
        }

        private static bool ShouldLoopClip(string clipId)
        {
            return IsIdleClipId(clipId) ||
                string.Equals(
                    clipId,
                    "standard_walk",
                    StringComparison.OrdinalIgnoreCase);
        }

        private static AnimationClip FindImportedClip(string targetFbxPath, string clipId)
        {
            UnityEngine.Object[] assets = AssetDatabase.LoadAllAssetsAtPath(targetFbxPath);
            AnimationClip fallback = null;
            for (int i = 0; i < assets.Length; i++)
            {
                if (assets[i] is not AnimationClip clip ||
                    clip.name.StartsWith("__preview__", StringComparison.Ordinal))
                {
                    continue;
                }

                if (clip.name == clipId)
                {
                    return clip;
                }

                fallback ??= clip;
            }

            if (fallback != null)
            {
                return fallback;
            }

            throw new InvalidOperationException("Action FBX did not contain a usable AnimationClip: " + targetFbxPath);
        }

        private static void RemoveUnsafeCurves(AnimationClip clip)
        {
            EditorCurveBinding[] bindings = AnimationUtility.GetCurveBindings(clip);
            for (int i = 0; i < bindings.Length; i++)
            {
                EditorCurveBinding binding = bindings[i];
                if (IsAllowedHumanoidCurve(binding))
                {
                    continue;
                }

                AnimationUtility.SetEditorCurve(clip, binding, null);
            }

            EditorCurveBinding[] objectBindings = AnimationUtility.GetObjectReferenceCurveBindings(clip);
            for (int i = 0; i < objectBindings.Length; i++)
            {
                AnimationUtility.SetObjectReferenceCurve(clip, objectBindings[i], null);
            }
        }

        private static void ValidateHumanoidClip(AnimationClip clip, string sourcePath)
        {
            EditorCurveBinding[] bindings = AnimationUtility.GetCurveBindings(clip);
            if (bindings.Length == 0)
            {
                throw new InvalidOperationException("Imported action clip is empty after humanoid filtering: " + sourcePath);
            }

            for (int i = 0; i < bindings.Length; i++)
            {
                EditorCurveBinding binding = bindings[i];
                if (!IsAllowedHumanoidCurve(binding))
                {
                    throw new InvalidOperationException("Action clip must contain only Humanoid body, muscle and IK goal curves: " + sourcePath + " " + binding.path + "/" + binding.propertyName);
                }
            }
        }

        private static bool IsAllowedHumanoidCurve(EditorCurveBinding binding)
        {
            if (binding.type != typeof(Animator) ||
                !string.IsNullOrEmpty(binding.path) ||
                string.IsNullOrEmpty(binding.propertyName))
            {
                return false;
            }

            // Humanoid muscles and IK goals are relative to this body pose.
            // Keeping the actor in place is a root-motion setting, not a reason
            // to discard its center of mass, orientation or authored IK goals.
            switch (binding.propertyName)
            {
                case "RootT.x": case "RootT.y": case "RootT.z":
                case "RootQ.x": case "RootQ.y": case "RootQ.z": case "RootQ.w":
                case "LeftFootT.x": case "LeftFootT.y": case "LeftFootT.z":
                case "LeftFootQ.x": case "LeftFootQ.y": case "LeftFootQ.z": case "LeftFootQ.w":
                case "RightFootT.x": case "RightFootT.y": case "RightFootT.z":
                case "RightFootQ.x": case "RightFootQ.y": case "RightFootQ.z": case "RightFootQ.w":
                case "LeftHandT.x": case "LeftHandT.y": case "LeftHandT.z":
                case "LeftHandQ.x": case "LeftHandQ.y": case "LeftHandQ.z": case "LeftHandQ.w":
                case "RightHandT.x": case "RightHandT.y": case "RightHandT.z":
                case "RightHandQ.x": case "RightHandQ.y": case "RightHandQ.z": case "RightHandQ.w":
                    return true;
            }

            // Finger bindings use serialized names such as
            // "LeftHand.Index.1 Stretched", while HumanTrait lists
            // "Left Index 1 Stretched". Normalize only for validation;
            // preserve the original binding and all of its keyframes.
            string muscleName = binding.propertyName;
            if (muscleName.StartsWith("LeftHand.", StringComparison.Ordinal))
            {
                muscleName = "Left " + muscleName.Substring("LeftHand.".Length).Replace('.', ' ');
            }
            else if (muscleName.StartsWith("RightHand.", StringComparison.Ordinal))
            {
                muscleName = "Right " + muscleName.Substring("RightHand.".Length).Replace('.', ' ');
            }

            return Array.IndexOf(HumanTrait.MuscleName, muscleName) >= 0 &&
                !IsUnsafeHumanoidMuscleName(muscleName);
        }

        private static bool IsUnsafeHumanoidMuscleName(string propertyName)
        {
            // Mouth, blink and gaze have independent runtime owners. Fingers
            // belong to the body animation and must keep their authored pose.
            return propertyName.Contains("Jaw", StringComparison.OrdinalIgnoreCase) ||
                propertyName.Contains("Eye", StringComparison.OrdinalIgnoreCase);
        }

        private static AnimatorController CreateOrUpdateController(List<ActionClip> clips)
        {
            if (clips.Count == 0)
            {
                throw new InvalidOperationException("No action clips were imported.");
            }

            AnimatorController controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
            if (controller == null)
            {
                controller = AnimatorController.CreateAnimatorControllerAtPath(ControllerPath);
            }

            AnimatorControllerLayer[] layers = controller.layers;
            layers[0].avatarMask = null;
            layers[0].defaultWeight = 1f;
            controller.layers = layers;

            AnimatorStateMachine stateMachine = controller.layers[0].stateMachine;
            HashSet<string> expectedStateNames = clips
                .Select(action => action.Id)
                .ToHashSet(StringComparer.Ordinal);
            var existingStates = new Dictionary<string, AnimatorState>(StringComparer.Ordinal);
            foreach (ChildAnimatorState child in stateMachine.states.ToArray())
            {
                AnimatorState state = child.state;
                // Independently imported official motion packs own their
                // namespaced states. Reimporting FBX must preserve them.
                if (state != null && state.name.StartsWith(OpenAnnieMotionLibrary.IdPrefix, StringComparison.Ordinal))
                {
                    continue;
                }
                if (state == null ||
                    !expectedStateNames.Contains(state.name) ||
                    existingStates.ContainsKey(state.name))
                {
                    stateMachine.RemoveState(state);
                    continue;
                }

                existingStates[state.name] = state;
            }

            AnimatorState mainIdleState = null;
            AnimatorState baseIdleState = null;
            for (int i = 0; i < clips.Count; i++)
            {
                ActionClip action = clips[i];
                if (!existingStates.TryGetValue(action.Id, out AnimatorState state))
                {
                    state = stateMachine.AddState(action.Id);
                }

                state.name = action.Id;
                // Reuse the serialized stride tree across imports. Its child
                // clips are refreshed below without accumulating subassets.
                if (action.Id != "standard_walk" || !(state.motion is BlendTree))
                    state.motion = action.Clip;
                state.writeDefaultValues = true;
                if (action.Id == MainIdleStateId)
                {
                    mainIdleState = state;
                }
                else if (action.Id == DefaultIdleClipId)
                {
                    baseIdleState = state;
                }
            }

            stateMachine.defaultState = mainIdleState ?? baseIdleState ?? stateMachine.states[0].state;
            ConfigureActionPlaybackStates(controller, expectedStateNames);
            EditorUtility.SetDirty(controller);
            return controller;
        }

        private static void ConfigureActionPlaybackStates(
            AnimatorController controller,
            IEnumerable<string> clipIds)
        {
            if (controller == null)
            {
                throw new InvalidOperationException("Missing Humanoid action controller: " + ControllerPath);
            }

            string speedParameter = WorldLocomotionPresentation.WorldWalkSpeedParameter;
            AnimatorControllerParameter[] parameters = controller.parameters;
            AnimatorControllerParameter walkSpeed = parameters.FirstOrDefault(
                parameter => parameter.name == speedParameter);
            if (walkSpeed == null)
            {
                controller.AddParameter(new AnimatorControllerParameter
                {
                    name = speedParameter,
                    type = AnimatorControllerParameterType.Float,
                    defaultFloat = 1f,
                });
            }
            else
            {
                if (walkSpeed.type != AnimatorControllerParameterType.Float)
                {
                    throw new InvalidOperationException(speedParameter + " must be a float parameter.");
                }
                walkSpeed.defaultFloat = 1f;
                controller.parameters = parameters;
            }

            var actionIds = new HashSet<string>(clipIds, StringComparer.Ordinal);
            foreach (AnimatorControllerLayer layer in controller.layers)
            {
                foreach (ChildAnimatorState child in layer.stateMachine.states)
                {
                    AnimatorState state = child.state;
                    if (state == null || !actionIds.Contains(state.name))
                    {
                        continue;
                    }
                    // The shared controller mixes FBX motions with native FK
                    // clips that have no Mecanim foot-goal tracks. During a
                    // crossfade, automatic Foot IK would blend an absent goal
                    // toward the body origin and fold the legs. Retain the
                    // authored FK pose consistently across every source.
                    state.iKOnFeet = false;
                    if (state.name == "standard_walk")
                    {
                        state.speedParameter = speedParameter;
                        state.speedParameterActive = true;
                        ConfigureWalkingStride(controller, state);
                    }
                    EditorUtility.SetDirty(state);
                }
            }
            EditorUtility.SetDirty(controller);
        }

        private static void ConfigureWalkingStride(AnimatorController controller, AnimatorState state)
        {
            string parameterName = WorldLocomotionPresentation.WorldWalkStrideParameter;
            AnimatorControllerParameter[] parameters = controller.parameters;
            AnimatorControllerParameter stride = parameters.FirstOrDefault(parameter => parameter.name == parameterName);
            if (stride == null)
                controller.AddParameter(new AnimatorControllerParameter {
                    name = parameterName, type = AnimatorControllerParameterType.Float, defaultFloat = 1f });
            else
            {
                if (stride.type != AnimatorControllerParameterType.Float)
                    throw new InvalidOperationException(parameterName + " must be a float parameter.");
                stride.defaultFloat = 1f;
                controller.parameters = parameters;
            }
            AnimationClip walk = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionDirectory + "/standard_walk.anim");
            AnimationClip idle = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionDirectory + "/idle_shrug.anim");
            if (walk == null || idle == null || walk.length <= 0f || idle.length <= 0f)
                throw new InvalidOperationException("Walking stride blend requires walk and idle clips.");
            BlendTree tree = state.motion as BlendTree;
            if (tree == null)
            {
                tree = new BlendTree { name = "WorldWalkStride", hideFlags = HideFlags.HideInHierarchy };
                AssetDatabase.AddObjectToAsset(tree, controller);
            }
            tree.blendType = BlendTreeType.Simple1D;
            tree.blendParameter = parameterName;
            tree.useAutomaticThresholds = false;
            // Match child durations so blending amplitude never changes the
            // observable half-cycle clock used to finish a step.
            tree.children = new[] {
                new ChildMotion { motion = idle, threshold = 0f, timeScale = idle.length / walk.length },
                new ChildMotion { motion = walk, threshold = 1f, timeScale = 1f },
            };
            state.motion = tree;
            EditorUtility.SetDirty(tree);
        }

        private static void BindControllerToSceneAvatar(
            Animator target,
            RuntimeAnimatorController controller)
        {
            target.runtimeAnimatorController = controller;
            ClearAnimatorWarningMessage(target);
            EditorUtility.SetDirty(target);
            EditorSceneManager.MarkSceneDirty(target.gameObject.scene);
            EditorSceneManager.SaveScene(target.gameObject.scene);
            Debug.Log("[MaasoHumanoidActionImporter] Bound " + ControllerPath + " to " + target.name);
        }

        private static void ConfigureUnityAvatarReceiver(IReadOnlyList<ActionClip> clips)
        {
            string[] idleVariants = BuildIdleVariantStateNames(clips);
            Component[] components = UnityEngine.Object.FindObjectsByType<Component>(FindObjectsInactive.Include);
            for (int i = 0; i < components.Length; i++)
            {
                Component component = components[i];
                if (component == null ||
                    component.GetType().FullName != "Maaso.Avatar.UnityAvatarCommandReceiver")
                {
                    continue;
                }

                var serialized = new SerializedObject(component);
                SerializedProperty prefer = serialized.FindProperty("preferDesignedIdle");
                SerializedProperty stateName = serialized.FindProperty("designedIdleStateName");
                if (prefer != null)
                {
                    prefer.boolValue = true;
                }
                if (stateName != null)
                {
                    stateName.stringValue = MainIdleStateId;
                }
                SerializedProperty variants = serialized.FindProperty("idleVariantStateNames");
                if (variants != null && variants.isArray)
                {
                    variants.arraySize = idleVariants.Length;
                    for (int variantIndex = 0; variantIndex < idleVariants.Length; variantIndex++)
                    {
                        variants.GetArrayElementAtIndex(variantIndex).stringValue = idleVariants[variantIndex];
                    }
                }
                serialized.ApplyModifiedPropertiesWithoutUndo();
                EditorUtility.SetDirty(component);
                EditorSceneManager.MarkSceneDirty(component.gameObject.scene);
            }
        }

        private static string[] BuildIdleVariantStateNames(IReadOnlyList<ActionClip> clips)
        {
            return clips
                .Select(clip => clip.Id)
                .Where(clipId =>
                    IsIdleClipId(clipId) &&
                    !string.Equals(clipId, MainIdleStateId, StringComparison.Ordinal))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
        }

        private static Animator FindSceneAvatarAnimator()
        {
            UnityAvatarCommandReceiver receiver =
                UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
            Animator activeAnimator = receiver?.ActiveAvatarRoot
                ?.GetComponentInChildren<Animator>(true);
            if (activeAnimator != null)
            {
                return activeAnimator;
            }

            Animator[] animators = UnityEngine.Object.FindObjectsByType<Animator>(
                FindObjectsInactive.Include);
            if (animators.Length > 0)
            {
                return animators[0];
            }

            throw new InvalidOperationException("No Animator found in scene: " + ScenePath);
        }

        private static void ClearAnimatorWarningMessage(Animator target)
        {
            var serialized = new SerializedObject(target);
            SerializedProperty warning = serialized.FindProperty("m_WarningMessage");
            if (warning != null)
            {
                warning.stringValue = string.Empty;
                serialized.ApplyModifiedPropertiesWithoutUndo();
            }
        }

        private static void DeleteRetiredActionAssets()
        {
            for (int i = 0; i < RetiredActionPaths.Length; i++)
            {
                string path = RetiredActionPaths[i];
                if (AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(path) != null)
                {
                    AssetDatabase.DeleteAsset(path);
                }
                else if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
        }

        private static void PruneStaleActionAssets(
            HashSet<string> expectedFbxPaths,
            HashSet<string> expectedClipPaths)
        {
            string[] guids = AssetDatabase.FindAssets("", new[] { ActionDirectory });
            for (int i = 0; i < guids.Length; i++)
            {
                string path = AssetDatabase.GUIDToAssetPath(guids[i]);
                if (Directory.Exists(path))
                {
                    continue;
                }

                string extension = Path.GetExtension(path).ToLowerInvariant();
                bool keep = extension switch
                {
                    ".fbx" => expectedFbxPaths.Contains(path),
                    ".anim" => expectedClipPaths.Contains(path),
                    ".meta" => true,
                    _ => false,
                };
                if (!keep)
                {
                    AssetDatabase.DeleteAsset(path);
                }
            }
        }

        private static void EnsureAssetFolder(string folderPath)
        {
            if (AssetDatabase.IsValidFolder(folderPath))
            {
                return;
            }

            string parent = Path.GetDirectoryName(folderPath)?.Replace("\\", "/");
            string name = Path.GetFileName(folderPath);
            if (!string.IsNullOrEmpty(parent))
            {
                EnsureAssetFolder(parent);
                AssetDatabase.CreateFolder(parent, name);
            }
        }

        private static bool IsIdleClipId(string clipId)
        {
            return string.Equals(clipId, DefaultIdleClipId, StringComparison.OrdinalIgnoreCase) ||
                clipId.StartsWith(DefaultIdleClipId + "_", StringComparison.OrdinalIgnoreCase);
        }

        private static string ToClipId(string sourceFbxPath)
        {
            string displayName = Path.GetFileNameWithoutExtension(sourceFbxPath).Trim();
            if (KnownClipIds.TryGetValue(displayName, out string knownId))
            {
                return knownId;
            }

            string clipId = ToLowerSnakeAscii(displayName);
            bool idleFamily = IsIdleSourcePath(sourceFbxPath);
            if (string.IsNullOrWhiteSpace(clipId))
            {
                clipId = idleFamily ? DefaultIdleClipId : "action";
            }

            if (idleFamily && clipId == "ldle")
            {
                clipId = DefaultIdleClipId;
            }

            if (idleFamily &&
                !string.Equals(clipId, DefaultIdleClipId, StringComparison.OrdinalIgnoreCase) &&
                !clipId.StartsWith(DefaultIdleClipId + "_", StringComparison.OrdinalIgnoreCase))
            {
                clipId = DefaultIdleClipId + "_" + clipId;
            }

            return clipId;
        }

        private static bool IsIdleSourcePath(string sourceFbxPath)
        {
            string parent = Path.GetFileName(Path.GetDirectoryName(sourceFbxPath) ?? string.Empty);
            string parentId = ToLowerSnakeAscii(parent);
            string fileId = ToLowerSnakeAscii(Path.GetFileNameWithoutExtension(sourceFbxPath));
            return parentId == "idle" ||
                parentId == "ldle" ||
                parentId.Contains("idle", StringComparison.OrdinalIgnoreCase) ||
                fileId == DefaultIdleClipId ||
                fileId.StartsWith(DefaultIdleClipId + "_", StringComparison.OrdinalIgnoreCase);
        }

        private static string MakeUniqueClipId(string clipId, HashSet<string> usedClipIds)
        {
            if (string.IsNullOrWhiteSpace(clipId))
            {
                return string.Empty;
            }

            if (usedClipIds.Add(clipId))
            {
                return clipId;
            }

            int suffix = 2;
            string candidate;
            do
            {
                candidate = clipId + "_" + suffix;
                suffix++;
            }
            while (!usedClipIds.Add(candidate));

            return candidate;
        }

        private static string ToLowerSnakeAscii(string value)
        {
            string text = value.Trim();
            if (string.IsNullOrEmpty(text))
            {
                return string.Empty;
            }

            var chars = new List<char>();
            bool previousWasSeparator = false;
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                bool isAsciiUpper = c >= 'A' && c <= 'Z';
                bool isAsciiLower = c >= 'a' && c <= 'z';
                bool isAsciiDigit = c >= '0' && c <= '9';
                if (isAsciiUpper || isAsciiLower || isAsciiDigit)
                {
                    bool insertSeparator = i > 0 &&
                        isAsciiUpper &&
                        chars.Count > 0 &&
                        !previousWasSeparator &&
                        char.IsLower(chars[chars.Count - 1]);
                    if (insertSeparator)
                    {
                        chars.Add('_');
                    }
                    chars.Add(char.ToLowerInvariant(c));
                    previousWasSeparator = false;
                }
                else if (!previousWasSeparator && chars.Count > 0)
                {
                    chars.Add('_');
                    previousWasSeparator = true;
                }
            }

            while (chars.Count > 0 && chars[chars.Count - 1] == '_')
            {
                chars.RemoveAt(chars.Count - 1);
            }

            return new string(chars.ToArray());
        }

        private static string ToAssetName(string clipId)
        {
            if (string.IsNullOrWhiteSpace(clipId))
            {
                return "Action";
            }

            return clipId;
        }

        private readonly struct ActionClip
        {
            public readonly string Id;
            public readonly AnimationClip Clip;

            public ActionClip(string id, AnimationClip clip, string path)
            {
                Id = id;
                Clip = clip;
                Path = path;
            }

            public readonly string Path;
        }
    }
}
#endif
