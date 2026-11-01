using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class OpenAnnieMotionLibraryTests
{
    private const string Source = "Assets/MaasoAvatar/Editor/OpenAnnieSource";
    private const string Folder = "Assets/MaasoAvatar/Animations/Humanoid/OpenAnnie";
    private const string Controller = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
    private const string Library = "Assets/MaasoAvatar/Resources/OpenAnnieMotionLibrary.asset";
    private static Type RuntimeType => Type.GetType("Maaso.Avatar.OpenAnnieMotionLibrary, Assembly-CSharp", true);
    private static Type ImporterType => Type.GetType("Maaso.Avatar.Editor.MaasoOpenAnnieMotionImporter, Assembly-CSharp-Editor", true);

    [Test]
    public void ExactPlateauReductionKeepsEveryNonFlatKeyAndBothClipEndpoints()
    {
        float[] values = { .25f, .25f, .25f, .25f, .8f, .4f, .4f, .4f, .4f, .9f, .90000004f, .9f, .9f, .9f };
        Keyframe[] dense = values.Select((value, frame) => new Keyframe(frame / 30f, value)).ToArray();
        Keyframe[] reduced = Reduce(dense);
        Assert.That(reduced.Select(key => key.time), Is.EqualTo(new[] { 0, 3, 4, 5, 8, 9, 10, 11, 13 }.Select(frame => frame / 30f)));
        Assert.That(reduced[0].time, Is.EqualTo(dense[0].time));
        Assert.That(reduced.Last().time, Is.EqualTo(dense.Last().time));
        Assert.That(reduced.Any(key => key.value == .90000004f), Is.True, "Near equality must not be treated as a plateau.");
        AssertCurvesEquivalent(dense, reduced);
    }

    [Test]
    public void ConstantCurveRetainsItsBindingDurationAndExactValue()
    {
        Keyframe[] dense = Enumerable.Range(0, 181).Select(frame => new Keyframe(frame / 30f, -.12345678f)).ToArray();
        Keyframe[] reduced = Reduce(dense);
        Assert.That(reduced, Has.Length.EqualTo(2));
        Assert.That(reduced[0].time, Is.Zero);
        Assert.That(reduced[1].time, Is.EqualTo(6f));
        Assert.That(reduced.All(key => key.value == -.12345678f), Is.True);
        AssertCurvesEquivalent(dense, reduced);
        Assert.That(Reduce(dense.Take(1).ToArray()), Has.Length.EqualTo(1));
        Assert.That(Reduce(dense.Take(2).ToArray()), Has.Length.EqualTo(2));
    }

    [Test]
    public void NonFlatAnimationIsNeverDecimatedAndLoopSeamIsPreserved()
    {
        Keyframe[] dense = Enumerable.Range(0, 181).Select(frame =>
            new Keyframe(frame / 30f, frame == 180 ? 0f : Mathf.Sin(frame * .15f))).ToArray();
        Keyframe[] reduced = Reduce(dense);
        Assert.That(reduced.Select(key => (key.time, key.value)), Is.EqualTo(dense.Select(key => (key.time, key.value))));
        Assert.That(reduced.Last().value, Is.EqualTo(dense[0].value));
        AssertCurvesEquivalent(dense, reduced);
    }

    private static Keyframe[] Reduce(Keyframe[] dense) => (Keyframe[])ImporterType.GetMethod("ReduceExactPlateaus")
        .Invoke(null, new object[] { dense });

    private static AnimationCurve Linear(Keyframe[] keys)
    {
        var curve = new AnimationCurve(keys);
        for (int index = 0; index < curve.length; index++)
        {
            AnimationUtility.SetKeyLeftTangentMode(curve, index, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(curve, index, AnimationUtility.TangentMode.Linear);
        }
        return curve;
    }

    private static void AssertCurvesEquivalent(Keyframe[] dense, Keyframe[] reduced)
    {
        AnimationCurve before = Linear(dense);
        AnimationCurve after = Linear(reduced);
        float duration = dense.Last().time;
        var times = Enumerable.Range(0, Mathf.RoundToInt(duration * 60f) + 1).Select(sample => sample / 60f)
            .Concat(dense.SelectMany(key => new[] { key.time - .00001f, key.time, key.time + .00001f }))
            .Where(time => time >= 0f && time <= duration);
        foreach (float time in times)
            Assert.That(after.Evaluate(time), Is.EqualTo(before.Evaluate(time)).Within(.00000012f), "Curve changed at " + time);
        Assert.That(after.keys[0].time, Is.EqualTo(before.keys[0].time));
        Assert.That(after.keys.Last().time, Is.EqualTo(before.keys.Last().time));
    }

    [Test]
    public void ReviewedSourcePackIsInstalledAsSixtyThreeNativeHumanoidClips()
    {
        Object library = AssetDatabase.LoadAssetAtPath(Library, RuntimeType);
        Assert.That(library, Is.Not.Null);
        object[] entries = Entries(library);
        Assert.That(entries, Has.Length.EqualTo(63));
        Assert.That(entries.Count(e => Value<bool>(e, "UpperBody")), Is.EqualTo(40));
        Assert.That(entries.Count(e => Value<bool>(e, "Loop")), Is.EqualTo(13));
        Assert.That(Value<string>(library, "License"), Is.EqualTo("CC0-1.0"));
        Assert.That(Value<string>(library, "SourceCommit"), Is.EqualTo("1a3aebfe32343b119263c8b7eba3b7cb1d4e4507"));
        Assert.That(entries.Select(e => Value<string>(e, "Id")).Distinct().Count(), Is.EqualTo(63));
        var pack = JObject.Parse(File.ReadAllText(Source + "/pack.json"));
        foreach (object entry in entries)
        {
            string id = Value<string>(entry, "Id");
            var clip = Value<AnimationClip>(entry, "Clip");
            Assert.That(clip, Is.Not.Null, id);
            Assert.That(clip.humanMotion, Is.True, id);
            Assert.That(clip.legacy, Is.False, id);
            Assert.That(clip.frameRate, Is.EqualTo(30), id);
            Assert.That(clip.length, Is.EqualTo(Value<float>(entry, "Duration")).Within(.001f), id);
            Assert.That(clip.isLooping, Is.EqualTo(Value<bool>(entry, "Loop")), id);
            Assert.That(AssetDatabase.GetAssetPath(clip), Is.EqualTo(Folder + "/" + id + ".anim"));
            Assert.That(Value<string>(entry, "SourceSha256"), Is.EqualTo((string)pack["clips"][id.Substring(6)]["sha256"]));
            EditorCurveBinding[] curves = AnimationUtility.GetCurveBindings(clip);
            Assert.That(curves.Length, Is.GreaterThan(40), id);
            Assert.That(curves.All(binding => binding.type == typeof(Animator) && binding.path == string.Empty), Is.True, id);
            Assert.That(curves.Any(binding => binding.propertyName.Contains("Eye") || binding.propertyName.Contains("Jaw")), Is.False, id);
            Assert.That(curves.Any(binding => binding.propertyName.StartsWith("LeftHand.Thumb.", StringComparison.Ordinal)), Is.True, id);
            Assert.That(AnimationUtility.GetObjectReferenceCurveBindings(clip), Is.Empty, id);
        }
    }

    [Test]
    public void UpperBodyLayerIsDisabledUntilOwnedAndCannotAnimateRootOrLegs()
    {
        var controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(Controller);
        AnimatorControllerLayer layer = controller.layers.Single(l => l.name == "Annie Upper Body");
        Assert.That(layer.defaultWeight, Is.Zero);
        Assert.That(layer.blendingMode, Is.EqualTo(AnimatorLayerBlendingMode.Override));
        Assert.That(layer.stateMachine.defaultState.name, Is.EqualTo("annie_upper_body_empty"));
        Assert.That(layer.stateMachine.defaultState.motion, Is.Null);
        Assert.That(layer.avatarMask.GetHumanoidBodyPartActive(AvatarMaskBodyPart.Root), Is.False);
        Assert.That(layer.avatarMask.GetHumanoidBodyPartActive(AvatarMaskBodyPart.LeftLeg), Is.False);
        Assert.That(layer.avatarMask.GetHumanoidBodyPartActive(AvatarMaskBodyPart.RightLeg), Is.False);
        Assert.That(layer.avatarMask.GetHumanoidBodyPartActive(AvatarMaskBodyPart.LeftFingers), Is.True);
        foreach (object entry in Entries(AssetDatabase.LoadAssetAtPath(Library, RuntimeType)))
        {
            string id = Value<string>(entry, "Id");
            bool upper = Value<bool>(entry, "UpperBody");
            var states = upper ? layer.stateMachine.states : controller.layers[0].stateMachine.states;
            AnimatorState state = states.Single(s => s.state.name == id).state;
            Assert.That(state.motion, Is.SameAs(Value<AnimationClip>(entry, "Clip")), id);
            Assert.That(state.iKOnFeet, Is.False, id + " has authored FK legs and no synthesized foot IK goals");
            if (!upper) continue;
            Assert.That(state.writeDefaultValues, Is.False, id);
            Assert.That(AnimationUtility.GetCurveBindings(Value<AnimationClip>(entry, "Clip")).Any(binding =>
                binding.propertyName.StartsWith("Root", StringComparison.Ordinal) ||
                binding.propertyName.Contains("Leg") || binding.propertyName.Contains("Foot") || binding.propertyName.Contains("Toes")),
                Is.False, id);
        }
    }

    [Test]
    public void VrmOneConversionUsesPinnedSdkXReflectionAndThumbSemantics()
    {
        Quaternion value = Quaternion.AngleAxis(37f, new Vector3(.3f, .4f, .5f).normalized);
        Quaternion converted = (Quaternion)ImporterType.GetMethod("SourceQuaternion").Invoke(null,
            new object[] { new[] { value.x, value.y, value.z, value.w }, 0 });
        Assert.That(Quaternion.Angle(converted, new Quaternion(value.x, -value.y, -value.z, value.w)), Is.LessThan(.001f));
        Vector3 position = (Vector3)ImporterType.GetMethod("SourcePosition").Invoke(null, new object[] { new Vector3(1, 2, 3) });
        Assert.That(position, Is.EqualTo(new Vector3(-1, 2, 3)));
        AssertBone("leftThumbMetacarpal", HumanBodyBones.LeftThumbProximal);
        AssertBone("leftThumbProximal", HumanBodyBones.LeftThumbIntermediate);
        AssertBone("rightThumbDistal", HumanBodyBones.RightThumbDistal);
        object[] unsafeBone = { "jaw", default(HumanBodyBones) };
        Assert.That((bool)ImporterType.GetMethod("TryMapBone").Invoke(null, unsafeBone), Is.False);
    }

    [TestCase("Assets/MaasoAvatar/Models/Default/Joy.vrm")]
    public void NativeControllerWavePreservesSourceStandingLegExtensionAfterVrmProcessing(string model)
    {
        GameObject instance = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(model));
        Vrm10Instance vrm = instance.GetComponent<Vrm10Instance>();
        Vrm10Runtime runtime = null;
        var originalMaterials = instance.GetComponentsInChildren<Renderer>()
            .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
            .ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        try
        {
            // Match model binding order: VRM first creates its normalized rig;
            // then the same shared native controller is bound and rebound.
            if (vrm != null)
            {
                vrm.enabled = false;
                // Pinned UniVRM 0.131.2 MaterialValueBindingMerger clones
                // renderer.materials when an editor-imported prefab initializes
                // its real runtime. Unity emits its diagnostic PER MATERIAL
                // cloned by GetMaterialArray, not per renderer call. The reviewed
                // Joy GLB has 6 mesh nodes with 1+9+2+3+1+1 = 17 non-null slots.
                // Match exactly those known clones; other errors still fail.
                int clonedSlots = originalMaterials.Values.Sum(materials => materials.Count(material => material != null));
                Assert.That(clonedSlots, Is.EqualTo(17), "Reviewed Joy material-slot inventory changed.");
                TestContext.WriteLine("Joy runtime initialization: mesh-renderers=" + originalMaterials.Count + "; material-clone-slots=" + clonedSlots);
                for (int slot = 0; slot < clonedSlots; slot++)
                    LogAssert.Expect(LogType.Error,
                        "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
                runtime = vrm.Runtime;
            }
            Animator animator = instance.GetComponentInChildren<Animator>(true);
            animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(Controller);
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.Rebind();
            animator.Update(0);
            Vector3 initialPosition = instance.transform.position;
            Quaternion initialRotation = instance.transform.rotation;
            var source = JObject.Parse(File.ReadAllText(Source + "/wave.json"));
            int frames = (int)source["frames"];
            foreach (float fraction in new[] { 0f, .23f, .51f, .77f, .99f })
            {
                animator.Play("Base Layer.annie_wave", 0, fraction);
                animator.Update(0);
                runtime?.Process();
                Assert.That(Vector3.Distance(instance.transform.position, initialPosition), Is.LessThan(.0001f));
                Assert.That(Quaternion.Angle(instance.transform.rotation, initialRotation), Is.LessThan(.01f));
                foreach (bool left in new[] { true, false })
                {
                    Transform hip = ActualBone(left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg);
                    Transform knee = ActualBone(left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg);
                    Transform ankle = ActualBone(left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
                    float thigh = Vector3.Distance(hip.position, knee.position);
                    float shin = Vector3.Distance(knee.position, ankle.position);
                    Assert.That(thigh, Is.GreaterThan(.1f));
                    Assert.That(shin, Is.GreaterThan(.1f));
                    float ratio = Vector3.Distance(hip.position, ankle.position) / (thigh + shin);
                    float[] rotations = source["bones"][left ? "leftLowerLeg" : "rightLowerLeg"].ToObject<float[]>();
                    int frame = Mathf.RoundToInt(fraction * (frames - 1));
                    Quaternion authored = (Quaternion)ImporterType.GetMethod("SourceQuaternion").Invoke(null, new object[] { rotations, frame * 4 });
                    // In normalized T-pose both leg segments point downward.
                    // Source lower-leg rotation gives its authored bend. The
                    // target model's real segment lengths account for different
                    // proportions; no fixed idle/straight-leg pose is imposed.
                    float authoredBend = Vector3.Angle(Vector3.down, authored * Vector3.down);
                    float expected = Mathf.Sqrt(thigh * thigh + shin * shin +
                        2f * thigh * shin * Mathf.Cos(authoredBend * Mathf.Deg2Rad)) / (thigh + shin);
                    TestContext.WriteLine(model + " native-wave t=" + fraction + " side=" + (left ? "left" : "right") +
                        " source-bend=" + authoredBend + " actual-extension=" + ratio + " expected-extension=" + expected);
                    Assert.That(ratio, Is.EqualTo(expected).Within(.02f), model + " wave must not fold authored standing legs into kneeling");
                }
            }

            Transform ActualBone(HumanBodyBones bone)
            {
                if (vrm != null && vrm.TryGetBoneTransform(bone, out Transform raw)) return raw;
                return animator.GetBoneTransform(bone);
            }
        }
        finally
        {
            // Destroy only materials created by this fixture's runtime before
            // UniVRM's play-mode Dispose tries to schedule their destruction.
            var borrowedMaterials = new HashSet<Material>(originalMaterials.Values.SelectMany(materials => materials));
            var clones = originalMaterials.Keys.Where(renderer => renderer != null)
                .SelectMany(renderer => renderer.sharedMaterials)
                .Where(material => material != null && !borrowedMaterials.Contains(material) && !AssetDatabase.Contains(material))
                .Distinct().ToArray();
            foreach (var pair in originalMaterials)
                if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (Material clone in clones) Object.DestroyImmediate(clone);
            // UniVRM normally destroys generated rig objects on a play-mode
            // frame. Dispose this temporary EditMode owner immediately first.
            if (runtime?.ControlRig != null)
            {
                Object.DestroyImmediate(runtime.ControlRig.ControlRigAnimator.avatar);
                Transform controls = instance.transform.Find("Runtime Control Rig");
                if (controls != null) Object.DestroyImmediate(controls.gameObject);
            }
            Object.DestroyImmediate(instance);
        }
    }

    [TestCase("Assets/MaasoAvatar/Models/Default/Joy.vrm")]
    public void EveryClipActuallyRetargetsOnJoyWithFiniteMovingHands(string model)
    {
        GameObject instance = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(model));
        Avatar generated = null;
        PlayableGraph graph = default;
        try
        {
            Vector3 initialPosition = instance.transform.position;
            Quaternion initialRotation = instance.transform.rotation;
            Animator animator = instance.GetComponentInChildren<Animator>(true);
            animator.runtimeAnimatorController = null;
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            var vrm = instance.GetComponent<Vrm10Instance>();
            if (vrm != null)
            {
                vrm.enabled = false;
                var rig = new Vrm10RuntimeControlRig(vrm.Humanoid, instance.transform);
                generated = rig.ControlRigAnimator.avatar;
            }
            animator.Rebind();
            Assert.That(animator.avatar.isHuman && animator.avatar.isValid, Is.True, model);
            float largestHandMotion = 0f;
            float lowestHeight = float.PositiveInfinity, highestHeight = float.NegativeInfinity;
            float maximumRootTravel = 0f, maximumUpperLegDifference = 0f;
            float maximumCenterOfMassDifference = 0f, maximumLowerPositionDifference = 0f, maximumLowerAngleDifference = 0f;
            HumanBodyBones[] lowerBodyIds = {
                HumanBodyBones.Hips, HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg,
                HumanBodyBones.LeftFoot, HumanBodyBones.LeftToes, HumanBodyBones.RightUpperLeg,
                HumanBodyBones.RightLowerLeg, HumanBodyBones.RightFoot, HumanBodyBones.RightToes,
            };
            Transform[] lowerBody = lowerBodyIds.Select(animator.GetBoneTransform).ToArray();
            Assert.That(lowerBody.All(bone => bone != null), Is.True, model + " lower-body mapping");
            var idle = AssetDatabase.LoadAssetAtPath<AnimationClip>(
                "Assets/MaasoAvatar/Animations/Humanoid/Actions/idle_shrug.anim");
            var mask = AssetDatabase.LoadAssetAtPath<AvatarMask>(Folder + "/OpenAnnieUpperBody.mask");
            Assert.That(idle, Is.Not.Null);
            Assert.That(mask, Is.Not.Null);
            using (var poseHandler = new HumanPoseHandler(animator.avatar, animator.transform))
            {
                foreach (object entry in Entries(AssetDatabase.LoadAssetAtPath(Library, RuntimeType)))
                {
                    // Retarget each clip independently; authored root offsets
                    // are model placement, not motion produced by the clip.
                    if (graph.IsValid()) graph.Destroy();
                    animator.Rebind();
                    instance.transform.SetPositionAndRotation(initialPosition, initialRotation);
                    graph = PlayableGraph.Create("Open Annie real model retarget test");
                    graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
                    var output = AnimationPlayableOutput.Create(graph, "Retarget", animator);
                    string id = Value<string>(entry, "Id");
                    var clip = Value<AnimationClip>(entry, "Clip");
                    var playable = AnimationClipPlayable.Create(graph, clip);
                    playable.SetApplyFootIK(false);
                    playable.SetApplyPlayableIK(false);
                    bool upperBody = Value<bool>(entry, "UpperBody");
                    AnimationLayerMixerPlayable layers = default;
                    AnimationClipPlayable baseIdle = default;
                    if (upperBody)
                    {
                        // Runtime upper-body states are never a standalone
                        // pose: their absent root/leg curves inherit the base.
                        baseIdle = AnimationClipPlayable.Create(graph, idle);
                        baseIdle.SetApplyFootIK(false);
                        baseIdle.SetApplyPlayableIK(false);
                        layers = AnimationLayerMixerPlayable.Create(graph, 2);
                        graph.Connect(baseIdle, 0, layers, 0);
                        graph.Connect(playable, 0, layers, 1);
                        layers.SetInputWeight(0, 1f);
                        layers.SetInputWeight(1, 1f);
                        layers.SetLayerMaskFromAvatarMask(1, mask);
                        layers.SetLayerAdditive(1, false);
                        output.SetSourcePlayable(layers);
                    }
                    else output.SetSourcePlayable(playable);
                    graph.Play();
                    Vector3 firstHand = Vector3.zero;
                    foreach (float fraction in new[] { 0f, .23f, .51f, .77f, .99f })
                    {
                        HumanPose basePose = new HumanPose();
                        Vector3[] baseLowerPositions = null;
                        Quaternion[] baseLowerRotations = null;
                        if (upperBody)
                        {
                            baseIdle.SetTime(idle.length * fraction);
                            layers.SetInputWeight(1, 0f);
                            graph.Evaluate(0);
                            poseHandler.GetHumanPose(ref basePose);
                            baseLowerPositions = lowerBody.Select(bone => bone.position).ToArray();
                            baseLowerRotations = lowerBody.Select(bone => bone.rotation).ToArray();
                            layers.SetInputWeight(1, 1f);
                        }
                        playable.SetTime(clip.length * fraction);
                        graph.Evaluate(0);
                        var pose = new HumanPose();
                        poseHandler.GetHumanPose(ref pose);
                        Assert.That(pose.muscles.All(Finite), Is.True, model + " " + id);
                        Assert.That(Finite(pose.bodyPosition.y) && pose.bodyPosition.y > .2f && pose.bodyPosition.y < 2f,
                            Is.True, model + " " + id + " body height=" + pose.bodyPosition.y + " at=" + fraction);
                        lowestHeight = Mathf.Min(lowestHeight, pose.bodyPosition.y);
                        highestHeight = Mathf.Max(highestHeight, pose.bodyPosition.y);
                        if (upperBody)
                        {
                            // HumanPose.bodyPosition is an estimated whole-body
                            // center of mass, not the actor/hips transform:
                            // https://docs.unity3d.com/ScriptReference/HumanPose-bodyPosition.html
                            // Moving arms legitimately changes it. Verify the
                            // actual root and lower skeleton instead, and retain
                            // COM/muscle differences as diagnostics.
                            maximumCenterOfMassDifference = Mathf.Max(maximumCenterOfMassDifference,
                                Vector3.Distance(pose.bodyPosition, basePose.bodyPosition));
                            for (int boneIndex = 0; boneIndex < lowerBody.Length; boneIndex++)
                            {
                                float positionDifference = Vector3.Distance(lowerBody[boneIndex].position, baseLowerPositions[boneIndex]);
                                float angleDifference = Quaternion.Angle(lowerBody[boneIndex].rotation, baseLowerRotations[boneIndex]);
                                maximumLowerPositionDifference = Mathf.Max(maximumLowerPositionDifference, positionDifference);
                                maximumLowerAngleDifference = Mathf.Max(maximumLowerAngleDifference, angleDifference);
                                Assert.That(positionDifference, Is.LessThan(.0001f), model + " " + id + " modified base " + lowerBodyIds[boneIndex] + " position");
                                Assert.That(angleDifference, Is.LessThan(.05f), model + " " + id + " modified base " + lowerBodyIds[boneIndex] + " rotation");
                            }
                            for (int muscle = 0; muscle < HumanTrait.MuscleCount; muscle++)
                            {
                                string name = HumanTrait.MuscleName[muscle];
                                if (!name.Contains("Leg") && !name.Contains("Foot") && !name.Contains("Toes")) continue;
                                float difference = Mathf.Abs(pose.muscles[muscle] - basePose.muscles[muscle]);
                                maximumUpperLegDifference = Mathf.Max(maximumUpperLegDifference, difference);
                            }
                        }
                        Vector3 hand = animator.GetBoneTransform(HumanBodyBones.RightHand).position;
                        Assert.That(Finite(hand.x) && Finite(hand.y) && Finite(hand.z), Is.True, id);
                        if (fraction == 0f) firstHand = hand;
                        else largestHandMotion = Mathf.Max(largestHandMotion, Vector3.Distance(firstHand, hand));
                        float rootTravel = Vector3.Distance(instance.transform.position, initialPosition);
                        maximumRootTravel = Mathf.Max(maximumRootTravel, rootTravel);
                        Assert.That(rootTravel * rootTravel, Is.LessThan(.00001f), id + " root must not travel from " + initialPosition);
                        Assert.That(Quaternion.Angle(instance.transform.rotation, initialRotation), Is.LessThan(.01f),
                            id + " actor root orientation must stay in place");
                    }
                }
            }
            TestContext.WriteLine("OpenAnnie actual-model=" + model + "; initial-root=" + initialPosition.ToString("F8") +
                "; body-height-range=" + lowestHeight + ".." + highestHeight + "; max-root-travel=" + maximumRootTravel +
                "; max-upper-leg-muscle-delta=" + maximumUpperLegDifference + "; max-center-of-mass-delta=" + maximumCenterOfMassDifference +
                "; max-lower-bone-position-delta=" + maximumLowerPositionDifference + "; max-lower-bone-angle-delta=" + maximumLowerAngleDifference +
                "; max-hand-motion=" + largestHandMotion);
            Assert.That(largestHandMotion, Is.GreaterThan(.1f), model + " motions must reach the actual Humanoid bones");
        }
        finally
        {
            if (graph.IsValid()) graph.Destroy();
            Object.DestroyImmediate(instance);
            if (generated != null) Object.DestroyImmediate(generated);
        }
    }

    [Test]
    public void ExistingFbxReimportKeepsNamespacedPackStatesAndWalkTree()
    {
        Type importer = Type.GetType("Maaso.Avatar.Editor.MaasoHumanoidActionImporter, Assembly-CSharp-Editor", true);
        Type item = importer.GetNestedType("ActionClip", BindingFlags.NonPublic);
        var list = (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(item));
        var controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(Controller);
        var originalAnnie = controller.layers[0].stateMachine.states.Where(s => s.state.name.StartsWith("annie_", StringComparison.Ordinal))
            .ToDictionary(s => s.state.name, s => s.state);
        var walk = controller.layers[0].stateMachine.states.Single(s => s.state.name == "standard_walk").state.motion;
        foreach (ChildAnimatorState state in controller.layers[0].stateMachine.states)
        {
            if (state.state.name.StartsWith("annie_", StringComparison.Ordinal)) continue;
            string id = state.state.name;
            var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>("Assets/MaasoAvatar/Animations/Humanoid/Actions/" + id + ".anim");
            list.Add(Activator.CreateInstance(item, new object[] { id, clip, AssetDatabase.GetAssetPath(clip) }));
        }
        importer.GetMethod("CreateOrUpdateController", BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, new object[] { list });
        foreach (var pair in originalAnnie)
            Assert.That(controller.layers[0].stateMachine.states.Single(s => s.state.name == pair.Key).state, Is.SameAs(pair.Value));
        Assert.That(controller.layers[0].stateMachine.states.Single(s => s.state.name == "standard_walk").state.motion, Is.SameAs(walk));
        Assert.That(controller.layers.Single(l => l.name == "Annie Upper Body").defaultWeight, Is.Zero);
    }

    [Test]
    public void ReimportPreservesAllClipGuidsAndSharedControllerReferences()
    {
        var before = Entries(AssetDatabase.LoadAssetAtPath(Library, RuntimeType)).ToDictionary(
            e => Value<string>(e, "Id"), e => AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(Value<AnimationClip>(e, "Clip"))));
        string controllerGuid = AssetDatabase.AssetPathToGUID(Controller);
        ImporterType.GetMethod("RunFromCommandLine").Invoke(null, null);
        foreach (object entry in Entries(AssetDatabase.LoadAssetAtPath(Library, RuntimeType)))
            Assert.That(AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(Value<AnimationClip>(entry, "Clip"))),
                Is.EqualTo(before[Value<string>(entry, "Id")]));
        Assert.That(AssetDatabase.AssetPathToGUID(Controller), Is.EqualTo(controllerGuid));
    }

    private static void AssertBone(string name, HumanBodyBones expected)
    {
        object[] args = { name, default(HumanBodyBones) };
        Assert.That((bool)ImporterType.GetMethod("TryMapBone").Invoke(null, args), Is.True);
        Assert.That(args[1], Is.EqualTo(expected));
    }
    private static object[] Entries(Object library) => ((IEnumerable)RuntimeType.GetField("Entries").GetValue(library)).Cast<object>().ToArray();
    private static T Value<T>(object target, string field) => (T)target.GetType().GetField(field).GetValue(target);
    private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
}
