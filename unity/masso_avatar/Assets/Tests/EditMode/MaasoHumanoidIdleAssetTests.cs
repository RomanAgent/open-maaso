using System;
using System.IO;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;
using UnityEngine.TestTools;

public sealed class MaasoHumanoidIdleAssetTests
{
    private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
    private const string ActionDirectory = "Assets/MaasoAvatar/Animations/Humanoid/Actions";
    private const string DefaultIdleClipId = "idle_shrug";
    private const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";

    private static readonly string[] ExpectedActionClipIds =
    {
        "agree",
        "agree_234",
        "blow_kiss_1",
        "crying",
        "excited",
        "female_start_walking",
        "female_stop_walking",
        "happy_345",
        "hip_hop_dance",
        "idle_shrug",
        "look_234",
        "praying",
        "robot_street_dance",
        "shrug",
        "shy",
        "sneaky_walk",
        "standard_walk",
        "startled",
        "stomp",
        "thinking",
        "thoughtful_nod",
        "walk_left_turn",
        "wave",
        "waving_gesture",
    };

    private static readonly string[] ExpectedPreviewClipIds =
    {
        "idle_shrug",
        "agree",
        "agree_234",
        "blow_kiss_1",
        "crying",
        "excited",
        "female_start_walking",
        "female_stop_walking",
        "happy_345",
        "hip_hop_dance",
        "look_234",
        "praying",
        "robot_street_dance",
        "shrug",
        "shy",
        "sneaky_walk",
        "standard_walk",
        "startled",
        "stomp",
        "thinking",
        "thoughtful_nod",
        "walk_left_turn",
        "wave",
        "waving_gesture",
    };

    private static readonly string[] ExpectedIdleVariantStateIds = Array.Empty<string>();

    private static readonly string[] RetiredActionPaths =
    {
        "Assets/MaasoAvatar/Animations/Humanoid/FemaleStandingIdle.fbx",
        "Assets/MaasoAvatar/Animations/Humanoid/FemaleStandingIdle.fbx.meta",
        "Assets/MaasoAvatar/Animations/Humanoid/FemaleStandingIdlePose.anim",
        "Assets/MaasoAvatar/Animations/Humanoid/FemaleStandingIdlePose.anim.meta",
        "Assets/MaasoAvatar/Animations/Humanoid/Idle1.fbx",
        "Assets/MaasoAvatar/Animations/Humanoid/Idle1.fbx.meta",
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoOfficialStanding1Idle.fbx",
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoOfficialStanding1Idle.fbx.meta",
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoOfficialStanding1Idle.anim",
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoOfficialStanding1Idle.anim.meta",
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoIdleSkirtSafe.mask",
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoIdleSkirtSafe.mask.meta",
    };

    private static readonly string[] RetiredActionFileNames =
    {
        "Idle.fbx",
        "Idle.fbx.meta",
        "Idle.anim",
        "Idle.anim.meta",
    };

    [Test]
    public void DownloadedActionFolderFbxFilesAreImportedWithEnglishNames()
    {
        foreach (string clipId in ExpectedActionClipIds)
        {
            string fbxPath = ActionFbxPath(clipId);
            var importer = AssetImporter.GetAtPath(fbxPath) as ModelImporter;

            Assert.That(importer, Is.Not.Null, clipId + " should be imported from /path/to/local-checkout");
            Assert.That(importer.importAnimation, Is.True, clipId);
            Assert.That(importer.animationType, Is.EqualTo(ModelImporterAnimationType.Human), clipId);
            Assert.That(importer.avatarSetup, Is.EqualTo(ModelImporterAvatarSetup.CreateFromThisModel), clipId);
            Assert.That(AssetDatabase.LoadAllAssetsAtPath(fbxPath), Has.Some.TypeOf<AnimationClip>(), clipId);
        }
    }

    [Test]
    public void ImportedActionClipsAreAnimatorStatesWithShrugAsDefault()
    {
        var controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
        var defaultClip = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath(DefaultIdleClipId));

        Assert.That(controller, Is.Not.Null);
        Assert.That(defaultClip, Is.Not.Null);
        Assert.That(defaultClip.name, Is.EqualTo(DefaultIdleClipId));

        AnimatorState defaultState = controller.layers[0].stateMachine.defaultState;
        Assert.That(defaultState, Is.Not.Null);
        Assert.That(defaultState.name, Is.EqualTo(DefaultIdleClipId));
        Assert.That(AssetDatabase.GetAssetPath(defaultState.motion), Is.EqualTo(ActionClipPath(DefaultIdleClipId)));

        ChildAnimatorState[] states = controller.layers[0].stateMachine.states
            .Where(state => !state.state.name.StartsWith("annie_", StringComparison.Ordinal)).ToArray();
        Assert.That(
            states.Select(state => state.state.name),
            Is.EquivalentTo(ExpectedActionClipIds));

        foreach (ChildAnimatorState child in states)
        {
            Assert.That(child.state.name, Does.Match("^[a-z0-9_]+$"));
            Assert.That(child.state.iKOnFeet, Is.False,
                child.state.name + " must blend its authored FK pose with native clips that have no foot-goal tracks");
            if (child.state.name == "standard_walk")
            {
                var stride = child.state.motion as BlendTree;
                Assert.That(stride, Is.Not.Null, "Walking must adapt stride amplitude to ground distance.");
                Assert.That(stride.blendParameter, Is.EqualTo("WorldWalkStride"));
                Assert.That(stride.children, Has.Length.EqualTo(2));
                ChildMotion idle = stride.children.Single(motion => motion.threshold == 0f);
                ChildMotion fullWalk = stride.children.Single(motion => motion.threshold == 1f);
                Assert.That(AssetDatabase.GetAssetPath(fullWalk.motion), Is.EqualTo(ActionClipPath("standard_walk")));
                Assert.That(AssetDatabase.GetAssetPath(idle.motion), Is.EqualTo(ActionClipPath(DefaultIdleClipId)));
                Assert.That(idle.motion.averageDuration / idle.timeScale,
                    Is.EqualTo(fullWalk.motion.averageDuration / fullWalk.timeScale).Within(.00001f),
                    "Changing stride amplitude must preserve the footfall phase clock.");
                continue;
            }
            Assert.That(
                AssetDatabase.GetAssetPath(child.state.motion),
                Is.EqualTo(ActionClipPath(child.state.name)),
                child.state.name);
        }

        AnimatorControllerParameter[] walkSpeedParameters = controller.parameters
            .Where(parameter => parameter.name == "WorldWalkSpeed")
            .ToArray();
        Assert.That(walkSpeedParameters, Has.Length.EqualTo(1));
        Assert.That(walkSpeedParameters[0].type, Is.EqualTo(AnimatorControllerParameterType.Float));
        Assert.That(walkSpeedParameters[0].defaultFloat, Is.EqualTo(1f));
        AnimatorState walk = states.Single(child => child.state.name == "standard_walk").state;
        Assert.That(walk.speedParameterActive, Is.True);
        Assert.That(walk.speedParameter, Is.EqualTo("WorldWalkSpeed"));
    }

    [Test]
    public void OnlyContinuousMovementClipsLoopForFlutterCommands()
    {
        foreach (string clipId in ExpectedActionClipIds)
        {
            var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath(clipId));

            Assert.That(clip, Is.Not.Null, clipId);
            Assert.That(clip.name, Is.EqualTo(clipId));
            Assert.That(clipId, Does.Match("^[a-z0-9_]+$"));
            if (clipId == DefaultIdleClipId || clipId == "standard_walk")
            {
                Assert.That(clip.isLooping, Is.True, clipId);
            }
            else
            {
                Assert.That(clip.isLooping, Is.False, clipId);
            }
        }
        Assert.That(
            ExpectedActionClipIds,
            Has.Exactly(1).EqualTo(DefaultIdleClipId),
            "Only the current default idle should stay available.");
    }

    [Test]
    public void ExportedActionClipsAllowSourceFingerMusclesButExcludeFaceAndTransformTracks()
    {
        foreach (string clipId in ExpectedActionClipIds)
        {
            AnimationClip source = LoadFbxActionClip(clipId);
            var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath(clipId));
            Assert.That(clip, Is.Not.Null, clipId);

            EditorCurveBinding[] sourceFingers = FingerBindings(source);
            EditorCurveBinding[] bindings = AnimationUtility.GetCurveBindings(clip);
            Assert.That(bindings, Is.Not.Empty, clipId);
            foreach (EditorCurveBinding binding in bindings)
            {
                string context = clipId + ": " + binding.path + "/" + binding.propertyName;
                Assert.That(binding.type, Is.EqualTo(typeof(Animator)), context);
                Assert.That(binding.path, Is.Empty, context);
                Assert.That(binding.propertyName, Does.Not.Contain("Jaw").IgnoreCase, context);
                Assert.That(binding.propertyName, Does.Not.Contain("Eye").IgnoreCase, context);
                Assert.That(
                    HumanTrait.MuscleName.Contains(binding.propertyName) ||
                    sourceFingers.Contains(binding) ||
                    HumanoidBodyAndGoalPropertyNames.Contains(binding.propertyName),
                    Is.True,
                    context + " must be a Humanoid muscle, source finger, Body transform, or IK goal.");
            }
            Assert.That(AnimationUtility.GetObjectReferenceCurveBindings(clip), Is.Empty, clipId);
            AssertBodyAndGoalCurvesMatchSource(source, clip, clipId);
        }
    }

    [TestCase("wave", true)]
    [TestCase("praying", true)]
    [TestCase("shrug", false)]
    public void FbxFingerKeyframesArePreservedInExportedActionClips(string clipId, bool hasDynamicFingers)
    {
        AnimationClip source = LoadFbxActionClip(clipId);
        var exported = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath(clipId));
        Assert.That(exported, Is.Not.Null, clipId);

        EditorCurveBinding[] sourceFingers = FingerBindings(source);
        Assert.That(sourceFingers, Is.Not.Empty, clipId + " must exercise real FBX finger curves.");
        Assert.That(
            sourceFingers.Any(binding => !HumanTrait.MuscleName.Contains(binding.propertyName)),
            Is.True,
            "The fixture must exercise Unity's serialized hand-binding aliases, not only HumanTrait names.");
        Assert.That(
            sourceFingers.Any(binding =>
            {
                Keyframe[] keys = AnimationUtility.GetEditorCurve(source, binding).keys;
                return keys.Length > 1 && keys.Max(key => key.value) - keys.Min(key => key.value) > 0.001f;
            }),
            Is.EqualTo(hasDynamicFingers),
            clipId + " must cover the expected dynamic or static source hand pose.");

        AssertFingerCurvesMatchSource(source, exported, clipId);
    }

    [Test]
    public void ExportedClipsExtractHorizontalTravelAndKeepHeightAndRotationInPose()
    {
        foreach (string clipId in ExpectedActionClipIds)
        {
            var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath(clipId));
            Assert.That(clip, Is.Not.Null, clipId);
            AnimationClipSettings settings = AnimationUtility.GetAnimationClipSettings(clip);
            Assert.That(settings.loopBlendPositionXZ, Is.False, clipId + " horizontal root extraction");
            Assert.That(settings.keepOriginalPositionXZ, Is.True, clipId + " original horizontal basis");
            Assert.That(settings.loopBlendPositionY, Is.True, clipId + " height remains in the body pose");
            Assert.That(settings.keepOriginalPositionY, Is.True, clipId + " original height basis");
            Assert.That(settings.loopBlendOrientation, Is.True, clipId + " turn remains in the body pose");
            Assert.That(settings.keepOriginalOrientation, Is.True, clipId + " original orientation basis");
        }
    }

    [TestCase("standard_walk", 0f)]
    [TestCase("walk_left_turn", 15f)]
    [TestCase("hip_hop_dance", 15f)]
    [TestCase("robot_street_dance", 15f)]
    public void RealMovementClipsKeepBodyHeightAndTurnWithoutAccumulatingWorldTravel(
        string clipId,
        float minimumTurnAngle)
    {
        AnimationClip source = LoadFbxActionClip(clipId);
        var exported = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath(clipId));
        Assert.That(exported, Is.Not.Null, clipId);
        AnimationClip reference = UnityEngine.Object.Instantiate(source);
        try
        {
            AnimationClipSettings settings = AnimationUtility.GetAnimationClipSettings(reference);
            settings.loopBlendPositionXZ = false;
            settings.keepOriginalPositionXZ = true;
            AnimationUtility.SetAnimationClipSettings(reference, settings);

            HumanoidFrame[] expected = SampleOnBundledAvatar(reference);
            HumanoidFrame[] actual = SampleOnBundledAvatar(exported);
            Assert.That(actual, Has.Length.EqualTo(expected.Length), clipId);
            Vector3 firstBody = actual[0].bodyPosition;
            foreach (HumanoidFrame frame in actual)
            {
                Assert.That(frame.rootPosition.sqrMagnitude, Is.LessThan(0.000001f), clipId + " root position");
                Assert.That(Quaternion.Angle(Quaternion.identity, frame.rootRotation), Is.LessThan(0.01f), clipId + " root rotation");
                Vector2 horizontalOffset = new Vector2(
                    frame.bodyPosition.x - firstBody.x,
                    frame.bodyPosition.z - firstBody.z);
                Assert.That(
                    horizontalOffset.magnitude,
                    Is.LessThan(0.1f),
                    clipId + " must retain bounded body sway without source travel accumulating");
            }
            for (int index = 0; index < actual.Length; index++)
            {
                string context = clipId + " frame " + index;
                Assert.That(
                    actual[index].bodyPosition.y,
                    Is.EqualTo(expected[index].bodyPosition.y).Within(0.001f),
                    context + " source body height");
                Assert.That(
                    Quaternion.Angle(actual[index].bodyRotation, expected[index].bodyRotation),
                    Is.LessThan(0.1f),
                    context + " source body orientation");
            }
            Assert.That(
                actual.Max(frame => frame.bodyPosition.y) - actual.Min(frame => frame.bodyPosition.y),
                Is.GreaterThan(0.005f),
                clipId + " must preserve vertical pose motion; feet need not stay on the floor");
            if (minimumTurnAngle > 0f)
            {
                Assert.That(
                    actual.Max(frame => Quaternion.Angle(actual[0].bodyRotation, frame.bodyRotation)),
                    Is.GreaterThan(minimumTurnAngle),
                    clipId + " source turning must remain visible in the body pose");
            }
            if (exported.isLooping)
            {
                Assert.That(
                    Vector3.Distance(actual[0].bodyPosition, actual[actual.Length - 1].bodyPosition),
                    Is.LessThan(0.002f),
                    clipId + " body position after two cycles");
            }
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(reference);
        }
    }

    [TestCase("standard_walk")]
    [TestCase("walk_left_turn")]
    [TestCase("hip_hop_dance")]
    [TestCase("robot_street_dance")]
    public void SourceAvatarsHaveStraightKneesAtMaximumLegStretch(string clipId)
    {
        var model = AssetDatabase.LoadAssetAtPath<GameObject>(ActionFbxPath(clipId));
        Assert.That(model, Is.Not.Null, clipId);
        GameObject instance = UnityEngine.Object.Instantiate(model);
        try
        {
            Animator animator = instance.GetComponentInChildren<Animator>(true);
            Assert.That(animator, Is.Not.Null, clipId);
            Assert.That(animator.avatar.isValid && animator.avatar.isHuman, Is.True, clipId);
            animator.runtimeAnimatorController = null;
            animator.applyRootMotion = false;
            animator.Rebind();
            int leftStretch = Array.IndexOf(HumanTrait.MuscleName, "Left Lower Leg Stretch");
            int rightStretch = Array.IndexOf(HumanTrait.MuscleName, "Right Lower Leg Stretch");
            Assert.That(leftStretch, Is.GreaterThanOrEqualTo(0));
            Assert.That(rightStretch, Is.GreaterThanOrEqualTo(0));
            var pose = new HumanPose
            {
                bodyPosition = new Vector3(0f, 1f, 0f),
                bodyRotation = Quaternion.identity,
                muscles = new float[HumanTrait.MuscleCount],
            };
            pose.muscles[leftStretch] = 1f;
            pose.muscles[rightStretch] = 1f;
            using (var handler = new HumanPoseHandler(animator.avatar, animator.transform))
            {
                handler.SetHumanPose(ref pose);
                // Test the Avatar's reference mapping, not the clip's legitimate bent-leg frames.
                Assert.That(KneeBendDegrees(animator, true), Is.LessThanOrEqualTo(0.1f), clipId + " left reference knee");
                Assert.That(KneeBendDegrees(animator, false), Is.LessThanOrEqualTo(0.1f), clipId + " right reference knee");
            }
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    [Test]
    public void StandardWalkRetargetPreservesFootAxisPitchWithoutFootIk()
    {
        const string modelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        AnimationClip source = LoadFbxActionClip("standard_walk");
        var exported = AssetDatabase.LoadAssetAtPath<AnimationClip>(ActionClipPath("standard_walk"));
        var sourceModel = AssetDatabase.LoadAssetAtPath<GameObject>(ActionFbxPath("standard_walk"));
        var targetModel = AssetDatabase.LoadAssetAtPath<GameObject>(modelPath);
        Assert.That(exported, Is.Not.Null);
        Assert.That(sourceModel, Is.Not.Null);
        Assert.That(targetModel, Is.Not.Null);

        // Includes 1/6 s, 1/4 s and the opposite half-stride where the former
        // first-frame foot reference caused a roughly 26-degree left-foot bias.
        float[] times = Enumerable.Range(0, 14).Select(index => index / 12f).ToArray();
        Assert.That(times.Last(), Is.LessThan(source.length));
        // This specific Mixamo FBX is an animation-only skeleton. Its audited
        // static Foot +Z convention remains the source rotation reference.
        Vector2[] expected = SampleFootAxisPitches(sourceModel, source, times, animationOnlySource: true);
        Vector2[] actual = SampleFootAxisPitches(targetModel, exported, times);
        for (int index = 0; index < times.Length; index++)
        {
            string context = "standard_walk at " + times[index].ToString("F4") + " seconds";
            Assert.That(actual[index].x, Is.EqualTo(expected[index].x).Within(1f), context + " left bind-space foot forward pitch");
            Assert.That(actual[index].y, Is.EqualTo(expected[index].y).Within(1f), context + " right bind-space foot forward pitch");
        }
    }

    [Test]
    public void CurveFilteringKeepsHumanoidBodyGoalsAndFingersWhileRemovingUnsafeTracks()
    {
        AnimationClip source = LoadFbxActionClip("wave");
        AnimationClip clip = UnityEngine.Object.Instantiate(source);
        try
        {
            EditorCurveBinding[] forbidden =
            {
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "Jaw Close"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "Left Eye Down-Up"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "RootT.w"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "RootQ.x.extra"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "LeftFootT.w"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "LeftFootQ.value"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "RightHandT.x.extra"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "MotionT.x"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), "MotionQ.w"),
                EditorCurveBinding.FloatCurve("Rig", typeof(Animator), "RootT.y"),
                EditorCurveBinding.FloatCurve("Rig/Hand", typeof(Transform), "m_LocalRotation.x"),
                EditorCurveBinding.FloatCurve(string.Empty, typeof(Transform), "m_LocalPosition.y"),
            };
            foreach (EditorCurveBinding binding in forbidden)
            {
                AnimationUtility.SetEditorCurve(clip, binding, AnimationCurve.Linear(0f, 0f, 1f, 1f));
            }
            EditorCurveBinding objectBinding = EditorCurveBinding.PPtrCurve(
                "Face", typeof(SkinnedMeshRenderer), "m_Materials.Array.data[0]");
            AnimationUtility.SetObjectReferenceCurve(
                clip,
                objectBinding,
                new[] { new ObjectReferenceKeyframe { time = 0f, value = null } });
            Assert.That(AnimationUtility.GetObjectReferenceCurveBindings(clip), Does.Contain(objectBinding));

            ImporterMethod("RemoveUnsafeCurves").Invoke(null, new object[] { clip });

            EditorCurveBinding[] filtered = AnimationUtility.GetCurveBindings(clip);
            foreach (EditorCurveBinding binding in forbidden)
            {
                Assert.That(filtered.Contains(binding), Is.False, binding.path + "/" + binding.propertyName);
            }
            Assert.That(AnimationUtility.GetObjectReferenceCurveBindings(clip), Is.Empty);
            AssertFingerCurvesMatchSource(source, clip, "filtered wave");
            AssertBodyAndGoalCurvesMatchSource(source, clip, "filtered wave");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(clip);
        }
    }

    [Test]
    public void RebuildingExistingClipPreservesGuidLocalIdAndControllerReference()
    {
        string folderName = "TempHumanoidRebuild_" + Guid.NewGuid().ToString("N");
        string folder = "Assets/Tests/EditMode/" + folderName;
        AssetDatabase.CreateFolder("Assets/Tests/EditMode", folderName);
        try
        {
            string clipPath = folder + "/wave.anim";
            string controllerPath = folder + "/Reference.controller";
            MethodInfo export = ImporterMethod("CreateOrReplaceClipFromFbx");
            var first = (AnimationClip)export.Invoke(null, new object[] { ActionFbxPath("wave"), clipPath, "wave" });
            Assert.That(first, Is.Not.Null);
            Assert.That(AssetDatabase.TryGetGUIDAndLocalFileIdentifier(first, out string originalGuid, out long originalLocalId), Is.True);

            AnimatorController controller = AnimatorController.CreateAnimatorControllerAtPath(controllerPath);
            AnimatorState state = controller.layers[0].stateMachine.AddState("wave");
            state.motion = first;
            EditorUtility.SetDirty(controller);
            AssetDatabase.SaveAssets();

            AnimationClip source = LoadFbxActionClip("wave");
            EditorCurveBinding finger = FingerBindings(source).First();
            AnimationUtility.SetEditorCurve(first, finger, AnimationCurve.Constant(0f, 1f, -0.1234f));
            foreach (EditorCurveBinding binding in HumanoidBodyAndGoalBindings(source))
            {
                AnimationUtility.SetEditorCurve(first, binding, AnimationCurve.Constant(0f, 1f, -0.1234f));
            }
            first.name = "stale humanoid pose";
            EditorUtility.SetDirty(first);
            AssetDatabase.SaveAssets();

            var rebuilt = (AnimationClip)export.Invoke(null, new object[] { ActionFbxPath("wave"), clipPath, "wave" });
            AssetDatabase.SaveAssets();

            Assert.That(rebuilt, Is.Not.Null);
            Assert.That(AssetDatabase.TryGetGUIDAndLocalFileIdentifier(rebuilt, out string rebuiltGuid, out long rebuiltLocalId), Is.True);
            Assert.That(rebuiltGuid, Is.EqualTo(originalGuid), "Regeneration must not break serialized clip references.");
            Assert.That(rebuiltLocalId, Is.EqualTo(originalLocalId));
            Assert.That(state.motion, Is.SameAs(rebuilt), "Existing in-memory controller references must remain valid.");
            Assert.That(rebuilt.name, Is.EqualTo("wave"));
            AssertFingerCurvesMatchSource(source, rebuilt, "rebuilt wave");
            AssertBodyAndGoalCurvesMatchSource(source, rebuilt, "rebuilt wave");

            AssetDatabase.ImportAsset(controllerPath, ImportAssetOptions.ForceUpdate);
            var reloadedController = AssetDatabase.LoadAssetAtPath<AnimatorController>(controllerPath);
            AnimatorState reloadedState = reloadedController.layers[0].stateMachine.states
                .Single(child => child.state.name == "wave").state;
            Assert.That(reloadedState.motion, Is.Not.Null);
            Assert.That(AssetDatabase.GetAssetPath(reloadedState.motion), Is.EqualTo(clipPath));
            Assert.That(
                AssetDatabase.TryGetGUIDAndLocalFileIdentifier(reloadedState.motion, out string referencedGuid, out long referencedLocalId),
                Is.True);
            Assert.That(referencedGuid, Is.EqualTo(originalGuid));
            Assert.That(referencedLocalId, Is.EqualTo(originalLocalId));
        }
        finally
        {
            AssetDatabase.DeleteAsset(folder);
        }
    }

    [Test]
    public void LegacyActionAssetsAreRemoved()
    {
        foreach (string path in RetiredActionPaths)
        {
            Assert.That(File.Exists(path), Is.False, path);
            Assert.That(AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(path), Is.Null, path);
        }

        string[] actionFileNames = Directory.GetFiles(ActionDirectory)
            .Select(Path.GetFileName)
            .ToArray();
        foreach (string fileName in RetiredActionFileNames)
        {
            Assert.That(
                actionFileNames,
                Does.Not.Contain(fileName),
                fileName + " should be renamed with the lower_snake_case action id.");
        }
    }

    [Test]
    public void ImporterExposesFolderImportForFutureFbxActions()
    {
        Type importerType = Type.GetType("Maaso.Avatar.Editor.MaasoHumanoidActionImporter, Assembly-CSharp-Editor");

        Assert.That(importerType, Is.Not.Null);
        Assert.That(
            importerType.GetMethod("ImportDefaultActionFolder", BindingFlags.Public | BindingFlags.Static),
            Is.Not.Null);
        Assert.That(
            importerType.GetMethod("ImportActionFbxFolder", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(string) }, null),
            Is.Not.Null);
        Assert.That(
            importerType.GetField("DefaultExternalActionFolder", BindingFlags.Public | BindingFlags.Static),
            Is.Null,
            "Action imports must not contain a developer-machine fallback path.");
        Assert.That(
            importerType.GetField("ExternalActionFolderEnv", BindingFlags.Public | BindingFlags.Static)?.GetValue(null),
            Is.EqualTo("MAASO_ACTION_FBX_DIR"));
    }

    [Test]
    public void ActionPreviewWindowListsImportedActionClipsForUnityReview()
    {
        Type previewType = Type.GetType("Maaso.Avatar.Editor.MaasoActionPreviewWindow, Assembly-CSharp-Editor");
        Assert.That(previewType, Is.Not.Null);

        MethodInfo loadClips = previewType.GetMethod(
            "LoadActionClipsForTests",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(loadClips, Is.Not.Null);

        Array entries = (Array)loadClips.Invoke(null, Array.Empty<object>());
        string[] ids = entries.Cast<object>()
            .Select(entry => (string)entry.GetType().GetProperty("Id")?.GetValue(entry))
            .ToArray();
        string[] paths = entries.Cast<object>()
            .Select(entry => (string)entry.GetType().GetProperty("AssetPath")?.GetValue(entry))
            .ToArray();

        Assert.That(ids, Is.EqualTo(ExpectedPreviewClipIds));
        foreach (string path in paths)
        {
            Assert.That(path, Does.StartWith(ActionDirectory + "/"));
            Assert.That(path, Does.EndWith(".anim"));
        }
    }

    [Test]
    public void ActionPreviewWindowOpensRuntimeAvatarSceneWithoutChangingController()
    {
        Type previewType = Type.GetType("Maaso.Avatar.Editor.MaasoActionPreviewWindow, Assembly-CSharp-Editor");
        Assert.That(previewType, Is.Not.Null);

        MethodInfo openScene = previewType.GetMethod(
            "OpenRuntimeSceneAndFindAnimatorForTests",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(openScene, Is.Not.Null);

        var animator = openScene.Invoke(null, Array.Empty<object>()) as Animator;

        Assert.That(animator, Is.Not.Null);
        Assert.That(animator.runtimeAnimatorController, Is.Not.Null);
        Assert.That(AssetDatabase.GetAssetPath(animator.runtimeAnimatorController), Is.EqualTo(ControllerPath));
    }

    [Test]
    public void CompanionSceneUsesControllerAndLowercaseIdleState()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);

        Animator[] animators = UnityEngine.Object.FindObjectsByType<Animator>(FindObjectsInactive.Include);
        Assert.That(
            animators,
            Has.Some.Matches<Animator>(animator =>
                animator.runtimeAnimatorController != null &&
                AssetDatabase.GetAssetPath(animator.runtimeAnimatorController) == ControllerPath));

        Component receiver = Array.Find(
            UnityEngine.Object.FindObjectsByType<Component>(FindObjectsInactive.Include),
            component => component != null &&
                component.GetType().FullName == "Maaso.Avatar.UnityAvatarCommandReceiver");

        Assert.That(receiver, Is.Not.Null);
        var serialized = new SerializedObject(receiver);
        Assert.That(serialized.FindProperty("designedIdleStateName").stringValue, Is.EqualTo(DefaultIdleClipId));

        SerializedProperty variants = serialized.FindProperty("idleVariantStateNames");
        string[] variantStateNames = Enumerable.Range(0, variants.arraySize)
            .Select(index => variants.GetArrayElementAtIndex(index).stringValue)
            .ToArray();
        Assert.That(variantStateNames, Is.EqualTo(ExpectedIdleVariantStateIds));
    }

    private static string ActionFbxPath(string clipId)
    {
        return ActionDirectory + "/" + clipId + ".fbx";
    }

    private static readonly string[] HumanoidBodyAndGoalPropertyNames =
    {
        "RootT.x", "RootT.y", "RootT.z",
        "RootQ.x", "RootQ.y", "RootQ.z", "RootQ.w",
        "LeftFootT.x", "LeftFootT.y", "LeftFootT.z",
        "LeftFootQ.x", "LeftFootQ.y", "LeftFootQ.z", "LeftFootQ.w",
        "RightFootT.x", "RightFootT.y", "RightFootT.z",
        "RightFootQ.x", "RightFootQ.y", "RightFootQ.z", "RightFootQ.w",
        "LeftHandT.x", "LeftHandT.y", "LeftHandT.z",
        "LeftHandQ.x", "LeftHandQ.y", "LeftHandQ.z", "LeftHandQ.w",
        "RightHandT.x", "RightHandT.y", "RightHandT.z",
        "RightHandQ.x", "RightHandQ.y", "RightHandQ.z", "RightHandQ.w",
    };

    private struct HumanoidFrame
    {
        public Vector3 rootPosition;
        public Quaternion rootRotation;
        public Vector3 bodyPosition;
        public Quaternion bodyRotation;
    }

    private static float KneeBendDegrees(Animator animator, bool left)
    {
        Transform upperLeg = animator.GetBoneTransform(left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg);
        Transform lowerLeg = animator.GetBoneTransform(left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg);
        Transform foot = animator.GetBoneTransform(left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
        Assert.That(upperLeg, Is.Not.Null);
        Assert.That(lowerLeg, Is.Not.Null);
        Assert.That(foot, Is.Not.Null);
        return 180f - Vector3.Angle(upperLeg.position - lowerLeg.position, foot.position - lowerLeg.position);
    }

    private static Vector2[] SampleFootAxisPitches(
        GameObject model,
        AnimationClip clip,
        float[] times,
        bool animationOnlySource = false)
    {
        GameObject instance = UnityEngine.Object.Instantiate(model);
        PlayableGraph graph = default;
        try
        {
            instance.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator animator = instance.GetComponentInChildren<Animator>(true);
            Assert.That(animator, Is.Not.Null);
            Assert.That(animator.avatar.isValid && animator.avatar.isHuman, Is.True);
            Vrm10Instance vrm = instance.GetComponentInChildren<Vrm10Instance>(true);
            if (vrm != null)
            {
                // UniVRM initializes one runtime material per active renderer
                // slot. Expect only those exact EditMode messages; any extra
                // error or a missing expected initialization still fails.
                int materialAccessCount = vrm.GetComponentsInChildren<Renderer>()
                    .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                    .Sum(renderer => renderer.sharedMaterials.Length);
                for (int index = 0; index < materialAccessCount; index++)
                    LogAssert.Expect(LogType.Error,
                        "Instantiating material due to calling renderer.material during edit mode. " +
                        "This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
            }
            Vrm10Runtime vrmRuntime = vrm != null ? vrm.Runtime : null;
            animator.runtimeAnimatorController = null;
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.Rebind();

            // A Rigify foot's local +Z is not the same anatomical direction as
            // the source rig's +Z. Derive each forward axis from immutable mesh
            // bindposes, not Rebind/current pose, so an incorrect Avatar foot
            // reference cannot be calibrated away by this test.
            if (animationOnlySource)
            {
                Assert.That(AssetDatabase.GetAssetPath(model), Is.EqualTo(ActionFbxPath("standard_walk")),
                    "Only the audited animation-only source uses the explicit Foot +Z convention.");
                Assert.That(instance.GetComponentsInChildren<SkinnedMeshRenderer>(true), Is.Empty,
                    "A source with real skin must derive its reference from bindposes.");
                Assert.That(vrm, Is.Null);
                Assert.That(animator.GetBoneTransform(HumanBodyBones.LeftFoot).name, Is.EqualTo("LeftFoot"));
                Assert.That(animator.GetBoneTransform(HumanBodyBones.RightFoot).name, Is.EqualTo("RightFoot"));
            }
            Vector3 leftBindForward = animationOnlySource ? Vector3.forward : FootForwardInBindSpace(animator, vrm, true);
            Vector3 rightBindForward = animationOnlySource ? Vector3.forward : FootForwardInBindSpace(animator, vrm, false);

            graph = PlayableGraph.Create("Humanoid foot reference retarget test");
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            AnimationClipPlayable playable = AnimationClipPlayable.Create(graph, clip);
            playable.SetApplyFootIK(false);
            playable.SetApplyPlayableIK(false);
            AnimationPlayableOutput output = AnimationPlayableOutput.Create(graph, "Pose", animator);
            output.SetSourcePlayable(playable);
            graph.Play();

            var pitches = new Vector2[times.Length];
            for (int index = 0; index < times.Length; index++)
            {
                playable.SetTime(times[index]);
                graph.Evaluate(0f);
                playable.SetTime(times[index]);
                graph.Evaluate(0f);
                // The Playable drives normalized control bones where present;
                // copy through UniVRM before reading the real skinned bones.
                vrmRuntime?.Process();
                pitches[index] = new Vector2(
                    FootForwardPitchDegrees(animator, vrm, true, leftBindForward),
                    FootForwardPitchDegrees(animator, vrm, false, rightBindForward));
            }
            return pitches;
        }
        finally
        {
            if (graph.IsValid())
            {
                graph.Destroy();
            }
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    private static Transform RealSkinnedBone(Animator animator, Vrm10Instance vrm, HumanBodyBones bone)
    {
        // TryGetBoneTransform delegates to Vrm10Instance.Humanoid: the original
        // VRM skin binding, explicitly distinct from Runtime Control Rig bones.
        if (vrm != null)
        {
            Assert.That(vrm.TryGetBoneTransform(bone, out Transform raw), Is.True,
                "VRM must expose its original humanoid binding: " + bone);
            return raw;
        }
        return animator.GetBoneTransform(bone);
    }

    private static Vector3 FootForwardInBindSpace(Animator animator, Vrm10Instance vrm, bool left)
    {
        Transform foot = RealSkinnedBone(animator, vrm, left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
        Transform toes = RealSkinnedBone(animator, vrm, left ? HumanBodyBones.LeftToes : HumanBodyBones.RightToes);
        Assert.That(foot, Is.Not.Null);
        Assert.That(toes, Is.Not.Null, "The walk reference fixture requires mapped toes to identify anatomical forward.");
        foreach (SkinnedMeshRenderer skin in animator.GetComponentsInChildren<SkinnedMeshRenderer>(true))
        {
            if (skin.sharedMesh == null) continue;
            Transform[] bones = skin.bones;
            int footIndex = Array.IndexOf(bones, foot);
            int toesIndex = Array.IndexOf(bones, toes);
            Matrix4x4[] bindposes = skin.sharedMesh.bindposes;
            if (footIndex < 0 || toesIndex < 0 || footIndex >= bindposes.Length || toesIndex >= bindposes.Length) continue;
            Matrix4x4 footBindToWorld = skin.transform.localToWorldMatrix * bindposes[footIndex].inverse;
            Matrix4x4 toesBindToWorld = skin.transform.localToWorldMatrix * bindposes[toesIndex].inverse;
            Vector3 anatomicalForward = Vector3.ProjectOnPlane(
                toesBindToWorld.MultiplyPoint3x4(Vector3.zero) - footBindToWorld.MultiplyPoint3x4(Vector3.zero),
                animator.transform.up);
            Assert.That(anatomicalForward.sqrMagnitude, Is.GreaterThan(0.000001f),
                "Bind-space ankle/toes must establish a nonzero horizontal foot direction.");
            // Project before conversion: different ankle-to-toe heights are not
            // a pitch reference, and opposite authoring axes remain equivalent.
            return footBindToWorld.inverse.MultiplyVector(anatomicalForward.normalized).normalized;
        }
        Assert.Fail("No real skinned mesh contains both mapped foot/toe bindposes: " + foot.name);
        return Vector3.zero;
    }

    private static float FootForwardPitchDegrees(Animator animator, Vrm10Instance vrm, bool left, Vector3 bindForward)
    {
        Transform foot = RealSkinnedBone(animator, vrm, left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
        Assert.That(foot, Is.Not.Null);
        Vector3 forward = foot.TransformDirection(bindForward);
        return Mathf.Atan2(forward.y, new Vector2(forward.x, forward.z).magnitude) * Mathf.Rad2Deg;
    }

    private static HumanoidFrame[] SampleOnBundledAvatar(AnimationClip clip)
    {
        const string modelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        var model = AssetDatabase.LoadAssetAtPath<GameObject>(modelPath);
        Assert.That(model, Is.Not.Null);
        GameObject instance = UnityEngine.Object.Instantiate(model);
        PlayableGraph graph = default;
        try
        {
            instance.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            instance.transform.localScale = Vector3.one;
            Animator animator = instance.GetComponentInChildren<Animator>(true);
            Assert.That(animator, Is.Not.Null);
            Assert.That(animator.avatar.isValid && animator.avatar.isHuman, Is.True);
            animator.runtimeAnimatorController = null;
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.Rebind();

            graph = PlayableGraph.Create("Humanoid asset root policy test");
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            AnimationClipPlayable playable = AnimationClipPlayable.Create(graph, clip);
            // Isolate imported pose and root settings from the separate runtime IK policy.
            playable.SetApplyFootIK(false);
            playable.SetApplyPlayableIK(false);
            AnimationPlayableOutput output = AnimationPlayableOutput.Create(graph, "Pose", animator);
            output.SetSourcePlayable(playable);
            graph.Play();

            const int samplesPerCycle = 32;
            var frames = new HumanoidFrame[2 * samplesPerCycle + 1];
            using (var handler = new HumanPoseHandler(animator.avatar, animator.transform))
            {
                playable.SetTime(0);
                graph.Evaluate(0);
                for (int index = 0; index < frames.Length; index++)
                {
                    if (index > 0)
                    {
                        graph.Evaluate(clip.length / samplesPerCycle);
                    }
                    var pose = new HumanPose();
                    handler.GetHumanPose(ref pose);
                    frames[index] = new HumanoidFrame
                    {
                        rootPosition = animator.transform.position,
                        rootRotation = animator.transform.rotation,
                        bodyPosition = pose.bodyPosition,
                        bodyRotation = pose.bodyRotation,
                    };
                }
            }
            return frames;
        }
        finally
        {
            if (graph.IsValid())
            {
                graph.Destroy();
            }
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    private static EditorCurveBinding[] HumanoidBodyAndGoalBindings(AnimationClip clip)
    {
        return AnimationUtility.GetCurveBindings(clip)
            .Where(binding => binding.type == typeof(Animator) &&
                string.IsNullOrEmpty(binding.path) &&
                HumanoidBodyAndGoalPropertyNames.Contains(binding.propertyName))
            .ToArray();
    }

    private static void AssertBodyAndGoalCurvesMatchSource(
        AnimationClip source,
        AnimationClip exported,
        string context)
    {
        EditorCurveBinding[] expectedBindings = HumanoidBodyAndGoalBindings(source);
        Assert.That(
            expectedBindings.Select(binding => binding.propertyName),
            Is.EquivalentTo(HumanoidBodyAndGoalPropertyNames),
            context + " must exercise real Body and all four source IK goals.");
        Assert.That(
            HumanoidBodyAndGoalBindings(exported),
            Is.EquivalentTo(expectedBindings),
            context + " Body and IK goal bindings");
        foreach (EditorCurveBinding binding in expectedBindings)
        {
            AnimationCurve expected = AnimationUtility.GetEditorCurve(source, binding);
            AnimationCurve actual = AnimationUtility.GetEditorCurve(exported, binding);
            string curveContext = context + ": " + binding.propertyName;
            Assert.That(actual, Is.Not.Null, curveContext);
            Assert.That(actual.length, Is.EqualTo(expected.length), curveContext + " key count");
            Assert.That(actual.preWrapMode, Is.EqualTo(expected.preWrapMode), curveContext + " pre-wrap");
            Assert.That(actual.postWrapMode, Is.EqualTo(expected.postWrapMode), curveContext + " post-wrap");
            Keyframe[] expectedKeys = expected.keys;
            Keyframe[] actualKeys = actual.keys;
            for (int index = 0; index < expectedKeys.Length; index++)
            {
                Keyframe expectedKey = expectedKeys[index];
                Keyframe actualKey = actualKeys[index];
                string keyContext = curveContext + " key " + index;
                Assert.That(actualKey.time, Is.EqualTo(expectedKey.time).Within(0.000001f), keyContext + " time");
                Assert.That(actualKey.value, Is.EqualTo(expectedKey.value).Within(0.000001f), keyContext + " value");
                Assert.That(actualKey.inTangent, Is.EqualTo(expectedKey.inTangent).Within(0.000001f), keyContext + " in tangent");
                Assert.That(actualKey.outTangent, Is.EqualTo(expectedKey.outTangent).Within(0.000001f), keyContext + " out tangent");
                Assert.That(actualKey.inWeight, Is.EqualTo(expectedKey.inWeight).Within(0.000001f), keyContext + " in weight");
                Assert.That(actualKey.outWeight, Is.EqualTo(expectedKey.outWeight).Within(0.000001f), keyContext + " out weight");
                Assert.That(actualKey.weightedMode, Is.EqualTo(expectedKey.weightedMode), keyContext + " weighted mode");
            }
        }
    }

    private static string ActionClipPath(string clipId)
    {
        return ActionDirectory + "/" + clipId + ".anim";
    }

    private static AnimationClip LoadFbxActionClip(string clipId)
    {
        AnimationClip[] clips = AssetDatabase.LoadAllAssetsAtPath(ActionFbxPath(clipId))
            .OfType<AnimationClip>()
            .Where(clip => !clip.name.StartsWith("__preview__", StringComparison.Ordinal))
            .ToArray();
        Assert.That(clips, Has.Length.EqualTo(1), clipId + " should identify one real source clip.");
        return clips[0];
    }

    private static EditorCurveBinding[] FingerBindings(AnimationClip clip)
    {
        string[] fingers = { "Thumb", "Index", "Middle", "Ring", "Little" };
        return AnimationUtility.GetCurveBindings(clip)
            .Where(binding => binding.type == typeof(Animator) &&
                string.IsNullOrEmpty(binding.path) &&
                fingers.Any(finger => binding.propertyName.Contains(finger, StringComparison.OrdinalIgnoreCase)))
            .ToArray();
    }

    private static void AssertFingerCurvesMatchSource(AnimationClip source, AnimationClip exported, string context)
    {
        EditorCurveBinding[] sourceFingers = FingerBindings(source);
        EditorCurveBinding[] exportedFingers = FingerBindings(exported);
        Assert.That(sourceFingers, Is.Not.Empty, context + " source fingers");
        Assert.That(exportedFingers, Is.EquivalentTo(sourceFingers), context + " finger bindings");
        foreach (EditorCurveBinding binding in sourceFingers)
        {
            AnimationCurve expected = AnimationUtility.GetEditorCurve(source, binding);
            AnimationCurve actual = AnimationUtility.GetEditorCurve(exported, binding);
            string curveContext = context + ": " + binding.propertyName;
            Assert.That(actual, Is.Not.Null, curveContext);
            Assert.That(actual.length, Is.EqualTo(expected.length), curveContext + " key count");
            Assert.That(actual.keys.Select(key => key.time), Is.EqualTo(expected.keys.Select(key => key.time)).Within(0.000001f), curveContext + " key times");
            Assert.That(actual.keys.Select(key => key.value), Is.EqualTo(expected.keys.Select(key => key.value)).Within(0.000001f), curveContext + " key values");
        }
    }

    private static MethodInfo ImporterMethod(string name)
    {
        Type importerType = Type.GetType("Maaso.Avatar.Editor.MaasoHumanoidActionImporter, Assembly-CSharp-Editor");
        Assert.That(importerType, Is.Not.Null);
        MethodInfo method = importerType.GetMethod(name, BindingFlags.Static | BindingFlags.NonPublic);
        Assert.That(method, Is.Not.Null, name);
        return method;
    }
}
