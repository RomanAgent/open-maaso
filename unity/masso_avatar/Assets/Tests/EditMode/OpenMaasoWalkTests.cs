using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class OpenMaasoWalkTests
{
    private const string ModelPath = "Assets/MaasoAvatar/Models/Default/OpenMaaso.vrm";
    private const string WalkPath = "Assets/MaasoAvatar/Animations/Humanoid/Actions/standard_walk.anim";
    private GameObject model, host;
    private Animator animator;
    private Vrm10Instance vrm;
    private Component receiver;
    private AnimatorController controller;

    [SetUp]
    public void SetUp()
    {
        model = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath));
        animator = model.GetComponentInChildren<Animator>();
        animator.applyRootMotion = false;
        animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
        vrm = model.GetComponentInChildren<Vrm10Instance>();
        Type builder = Type.GetType("Maaso.Avatar.Editor.MaasoDefaultAvatarSceneBuilder, Assembly-CSharp-Editor", true);
        controller = (AnimatorController)builder.GetMethod("EnsureOfflineController", BindingFlags.Static | BindingFlags.NonPublic)
            .Invoke(null, new object[] { animator });
        animator.runtimeAnimatorController = controller;
        animator.Rebind(); animator.Update(0f);
        int slots = vrm.GetComponentsInChildren<Renderer>()
            .Where(r => r is SkinnedMeshRenderer || r is MeshRenderer).Sum(r => r.sharedMaterials.Length);
        for (int index = 0; index < slots; index++)
            LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
        vrm.Runtime.Process();
        host = new GameObject("WalkTestReceiver");
        receiver = host.AddComponent(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true));
        var serialized = new SerializedObject(receiver);
        serialized.FindProperty("avatarRoot").objectReferenceValue = model.transform;
        serialized.FindProperty("animator").objectReferenceValue = animator;
        serialized.FindProperty("bundledVrmInstance").objectReferenceValue = vrm;
        serialized.FindProperty("designedIdleStateName").stringValue = "Idle";
        serialized.ApplyModifiedPropertiesWithoutUndo();
    }

    [TearDown]
    public void TearDown()
    {
        Object.DestroyImmediate(host);
        Object.DestroyImmediate(model);
    }

    [Test]
    public void EditorWalkAuthoringLeavesTheSourceAvatarTransformsAndBoundsBitExact()
    {
        GameObject fresh = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath));
        try
        {
            var target = fresh.GetComponentInChildren<Animator>();
            Transform[] bones = target.GetComponentsInChildren<Transform>(true);
            var before = bones.Select(b => (b.localPosition, b.localRotation, b.localScale)).ToArray();
            Renderer[] renderers = target.GetComponentsInChildren<Renderer>(true);
            Bounds[] bounds = renderers.Select(r => r.localBounds).ToArray();
            Type builder = Type.GetType("Maaso.Avatar.Editor.MaasoDefaultAvatarSceneBuilder, Assembly-CSharp-Editor", true);
            builder.GetMethod("EnsureOfflineController", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { target });
            for (int index = 0; index < bones.Length; index++)
            {
                Assert.That(bones[index].localPosition, Is.EqualTo(before[index].localPosition));
                Assert.That(bones[index].localRotation, Is.EqualTo(before[index].localRotation));
                Assert.That(bones[index].localScale, Is.EqualTo(before[index].localScale));
            }
            for (int index = 0; index < renderers.Length; index++) Assert.That(renderers[index].localBounds, Is.EqualTo(bounds[index]));
        }
        finally { Object.DestroyImmediate(fresh); }
    }

    [Test]
    public void BundledControllerProvidesTheExactWalkStateRequiredByBothNativeOwners()
    {
        AnimationClip walk = AssetDatabase.LoadAssetAtPath<AnimationClip>(WalkPath);
        Assert.That(walk, Is.Not.Null);
        Assert.That(walk.name, Is.EqualTo("standard_walk"));
        Assert.That(AnimationUtility.GetAnimationClipSettings(walk).loopTime, Is.True);
        Assert.That(walk.length, Is.EqualTo(.8f).Within(.001f));
        Assert.That(controller.layers[0].stateMachine.defaultState.name, Is.EqualTo("Idle"));
        var states = controller.layers[0].stateMachine.states.Where(s => s.state.name == "standard_walk").ToArray();
        Assert.That(states, Has.Length.EqualTo(1));
        Assert.That(states[0].state.motion, Is.TypeOf<BlendTree>());
        Assert.That(((BlendTree)states[0].state.motion).children.Any(c => c.motion == walk), Is.True);
        Assert.That(((BlendTree)states[0].state.motion).blendParameter, Is.EqualTo("WorldWalkStride"));
        Assert.That(states[0].state.speedParameterActive, Is.True);
        Assert.That(states[0].state.speedParameter, Is.EqualTo("WorldWalkSpeed"));
        Assert.That(animator.HasState(0, Animator.StringToHash("standard_walk")), Is.True);
        Assert.That((bool)receiver.GetType().GetMethod("TryStartPresenceWalk", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(receiver, null), Is.True, "Home presence must not return walk_unavailable.");
    }

    [Test]
    public void WalkAuthorsAllVerifiedBodyChannelsAndDoesNotAcquireEyesOrSpeech()
    {
        var idle = AssetDatabase.LoadAssetAtPath<AnimationClip>("Assets/MaasoAvatar/Animations/Humanoid/OfflineIdle.anim");
        var walk = AssetDatabase.LoadAssetAtPath<AnimationClip>(WalkPath);
        foreach (var binding in AnimationUtility.GetCurveBindings(idle))
        {
            var curve = AnimationUtility.GetEditorCurve(walk, binding);
            Assert.That(curve, Is.Not.Null, binding.propertyName);
            if (binding.propertyName != "RootT.z")
                Assert.That(curve.Evaluate(0f), Is.EqualTo(curve.Evaluate(walk.length)).Within(.0001f), "Loop seam: " + binding.propertyName);
        }
        for (int index = 0; index < HumanTrait.MuscleCount; index++)
        {
            int bone = HumanTrait.BoneFromMuscle(index);
            if (bone != (int)HumanBodyBones.LeftEye && bone != (int)HumanBodyBones.RightEye && bone != (int)HumanBodyBones.Jaw) continue;
            Assert.That(AnimationUtility.GetEditorCurve(walk, EditorCurveBinding.FloatCurve("", typeof(Animator), HumanTrait.MuscleName[index])), Is.Null);
        }
    }

    [Test]
    public void RealVrmAlternatesFeetAndKneesWithoutApplyingWorldRootMotion()
    {
        Vector3 root = model.transform.position;
        Quaternion rotation = model.transform.rotation;
        var samples = new List<WalkSample>();
        for (int index = 0; index <= 16; index++)
        {
            float phase = index / 16f;
            animator.Play("standard_walk", 0, phase); animator.Update(0f); vrm.Runtime.Process();
            samples.Add(Inspect(phase));
            Assert.That(Vector3.Distance(model.transform.position, root), Is.LessThan(.0001f), "Only native room movement may translate the owner.");
            Assert.That(Quaternion.Angle(model.transform.rotation, rotation), Is.LessThan(.001f));
        }
        Assert.That(samples.Max(s => s.leftFoot.z) - samples.Min(s => s.leftFoot.z), Is.GreaterThan(.20f));
        Assert.That(samples.Max(s => s.rightFoot.z) - samples.Min(s => s.rightFoot.z), Is.GreaterThan(.20f));
        Assert.That(samples[0].leftFoot.z - samples[0].rightFoot.z,
            Is.EqualTo(-(samples[8].leftFoot.z - samples[8].rightFoot.z)).Within(.06f), "Footfalls alternate after half a cycle.");
        Assert.That(samples.Max(s => s.leftKnee) - samples.Min(s => s.leftKnee), Is.GreaterThan(20f));
        Assert.That(samples.Max(s => s.rightKnee) - samples.Min(s => s.rightKnee), Is.GreaterThan(20f));
        Assert.That(samples.Min(s => s.leftKnee), Is.GreaterThan(90f));
        Assert.That(samples.Min(s => s.rightKnee), Is.GreaterThan(90f));
        Assert.That(samples.Max(s => s.hips.z) - samples.Min(s => s.hips.z), Is.LessThan(.08f), "Trajectory metadata must not slide the pelvis within the unmoved root.");
        Assert.That(Vector3.Distance(samples[0].hips, samples[^1].hips), Is.LessThan(.005f), "Body pose must close at the loop seam.");
        animator.Play("standard_walk", 0, 12.25f); animator.Update(0f); vrm.Runtime.Process();
        Assert.That(Vector3.Distance(Inspect(12.25f).hips, samples[4].hips), Is.LessThan(.005f), "Pelvis trajectory must not accumulate over loops.");
        WriteEvidence(samples);
    }

    [Test]
    public void NativeLocomotionStartHeldTargetAndStopUseWalkThenTheVerifiedIdle()
    {
        var method = receiver.GetType().GetMethod("SetWorldLocomotion");
        method.Invoke(receiver, new object[] { true });
        animator.Update(.15f); vrm.Runtime.Process();
        Assert.That(animator.GetCurrentAnimatorStateInfo(0).IsName("standard_walk") || animator.GetNextAnimatorStateInfo(0).IsName("standard_walk"), Is.True);
        float before = animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
        method.Invoke(receiver, new object[] { true });
        animator.Update(.10f); vrm.Runtime.Process();
        Assert.That(animator.GetCurrentAnimatorStateInfo(0).normalizedTime, Is.GreaterThan(before), "Held targets must not restart the stride every frame.");
        method.Invoke(receiver, new object[] { false });
        animator.Update(.35f); vrm.Runtime.Process();
        Assert.That(animator.GetCurrentAnimatorStateInfo(0).IsName("Idle"), Is.True);
        Assert.That(animator.applyRootMotion, Is.False);
        Vector3 left = animator.GetBoneTransform(HumanBodyBones.LeftHand).position;
        Vector3 right = animator.GetBoneTransform(HumanBodyBones.RightHand).position;
        Assert.That(Vector3.Distance(left, right), Is.GreaterThan(.35f), "Idle must retain the corrected separated-hand pose.");
    }

    [Test]
    public void NativeSpeedCalibrationUsesAuthoredDistanceAndShortStridesKeepTheirClock()
    {
        var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(WalkPath);
        Assert.That(clip.averageSpeed.magnitude * animator.humanScale, Is.EqualTo(1.6f).Within(.02f));
        receiver.GetType().GetMethod("SetWorldLocomotion").Invoke(receiver, new object[] { true });
        animator.Update(.15f); vrm.Runtime.Process();
        Assert.That(animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1.15f).Within(.02f));
        float duration = animator.GetCurrentAnimatorStateInfo(0).length;
        animator.SetFloat("WorldWalkStride", .15f);
        animator.Update(.10f); vrm.Runtime.Process();
        Assert.That(animator.GetCurrentAnimatorStateInfo(0).length, Is.EqualTo(duration).Within(.005f), "Scaling pose amplitude must not stretch the native step clock.");
    }

    [Serializable] private sealed class WalkSample { public float phase, leftKnee, rightKnee; public Vector3 leftFoot, rightFoot, hips; }
    [Serializable] private sealed class WalkReceipt { public float clipSeconds, averageSpeed; public WalkSample[] samples; }
    private WalkSample Inspect(float phase)
    {
        Vector3 Bone(HumanBodyBones bone) => model.transform.InverseTransformPoint(animator.GetBoneTransform(bone).position);
        float Knee(bool left)
        {
            Vector3 upper = Bone(left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg);
            Vector3 knee = Bone(left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg);
            Vector3 foot = Bone(left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
            return Vector3.Angle(upper - knee, foot - knee);
        }
        return new WalkSample { phase = phase, leftKnee = Knee(true), rightKnee = Knee(false), leftFoot = Bone(HumanBodyBones.LeftFoot), rightFoot = Bone(HumanBodyBones.RightFoot), hips = Bone(HumanBodyBones.Hips) };
    }
    private static void WriteEvidence(List<WalkSample> samples)
    {
        string path = Environment.GetEnvironmentVariable("OPEN_MAASO_WALK_TEST_EVIDENCE");
        if (string.IsNullOrWhiteSpace(path)) return;
        var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(WalkPath);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
        File.WriteAllText(path, JsonUtility.ToJson(new WalkReceipt { clipSeconds = clip.length, averageSpeed = clip.averageSpeed.magnitude, samples = samples.ToArray() }, true));
    }
}
